#include "zscore_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <algorithm>
#include <deque>
#include <memory>
#include <optional>
#include <string>

namespace duckdb {

namespace {

// Bind-time state: which file, the ParCore metadata (row groups + chunk layout), and the resolved
// column index the z-score runs on.
struct ZScoreBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	size_t column_id = 0;
};

// Shared across workers. The only mutable shared state is the row-group cursor (claimed atomically),
// mirroring read_oasis. Capped to one worker for now -- this is the first hardware bring-up of the
// z-score path, so we keep it single-threaded and deterministic.
struct ZScoreGlobalState : public GlobalTableFunctionState {
	oasis::OasisContext *ctx = nullptr;
	size_t total_groups = 0;
	std::atomic<size_t> next_group {0};

	idx_t MaxThreads() const override {
		return 1;
	}
};

// One row group submitted to the FPGA and awaiting its flags. The scheduler owns the 2-pass flow (and
// so keeps the input buffer mapped through BOTH passes) until it completes; we hold the handle to
// collect the flag buffer and num_values to know how many flags it carries.
struct InFlightZGroup {
	oasis::SplinterResultHandle handle;
	size_t num_values = 0;
};

// Per-worker state: this worker's file handle plus the flag buffer of the row group it is currently
// slicing into STANDARD_VECTOR_SIZE-sized vectors.
struct ZScoreLocalState : public LocalTableFunctionState {
	unique_ptr<FileHandle> file_handle;

	// Sliding window of row groups submitted ahead of consumption, so the decoder stays fed while the
	// host is still emitting the current group's flags. Collected FIFO -> flags come back in row-group
	// order, exactly like the old one-at-a-time path.
	std::deque<InFlightZGroup> in_flight;

	std::shared_ptr<libstf::Buffer> current_flags;
	size_t current_offset = 0;    // values already emitted from current_flags
	size_t current_remaining = 0; // values still to emit from current_flags
};

unique_ptr<FunctionData> ZScoreBind(ClientContext &context, TableFunctionBindInput &input,
                                    vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);
	auto column_name = StringValue::Get(input.inputs[1]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto meta = BuildParcoreMetadata(parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file '%s' contains no row groups", parquet_file);
	}

	// Resolve the column by name.
	size_t col_id = meta.column_names.size();
	for (size_t i = 0; i < meta.column_names.size(); i++) {
		if (meta.column_names[i] == column_name) {
			col_id = i;
			break;
		}
	}
	if (col_id == meta.column_names.size()) {
		throw BinderException("Column '%s' not found in '%s'", column_name, parquet_file);
	}

	// The hardware z-score operates on INT32 values; reject anything else with a clear message.
	if (meta.groups[0].chunks[col_id].type != parcore::metadata::Type::INT32_T) {
		throw BinderException("zscore() currently supports INT32 columns only; column '%s' is a different type",
		                      column_name);
	}

	auto bind_data = make_uniq<ZScoreBindData>();
	bind_data->filename = parquet_file;
	bind_data->metadata = std::move(meta);
	bind_data->column_id = col_id;

	names.emplace_back("is_outlier");
	return_types.emplace_back(LogicalType::BOOLEAN);
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> ZScoreInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind = input.bind_data->Cast<ZScoreBindData>();
	auto gstate = make_uniq<ZScoreGlobalState>();
	gstate->ctx = &GetOrCreateOasisContext(context);
	gstate->total_groups = bind.metadata.groups.size();
	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> ZScoreInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                    GlobalTableFunctionState *) {
	auto &bind = input.bind_data->Cast<ZScoreBindData>();
	auto lstate = make_uniq<ZScoreLocalState>();
	// Each worker owns its file handle: DuckDB FileHandles are not safe to share across threads.
	auto &fs = FileSystem::GetFileSystem(context.client);
	lstate->file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);
	return std::move(lstate);
}

// Submits one row group's 2-pass z-score flow to the scheduler WITHOUT blocking, returning the handle
// to collect its flags later. Claims the next group atomically, skips empty ones, and returns nullopt
// once the row groups are exhausted (nothing submitted).
std::optional<InFlightZGroup> SubmitGroup(oasis::OasisContext &ctx, ZScoreGlobalState &gstate,
                                          ZScoreLocalState &lstate, const ZScoreBindData &bind) {
	while (true) {
		size_t group = gstate.next_group.fetch_add(1);
		if (group >= gstate.total_groups) {
			return std::nullopt;
		}
		const auto &cc = bind.metadata.groups[group].chunks[bind.column_id];
		if (cc.num_values == 0) {
			continue; // Skip empty row groups.
		}

		// The flag output (one int32 per value) must fit in a single FPGA output buffer.
		const size_t flag_size = cc.num_values * sizeof(int32_t);
		if (flag_size > libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE) {
			throw NotImplementedException(
			    "Row group %llu produces %llu flag bytes, exceeding the %llu byte maximum output buffer size",
			    (unsigned long long)group, (unsigned long long)flag_size,
			    (unsigned long long)libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
		}

		// Read the compressed column-chunk bytes into one FPGA-mappable input buffer. Both z-score
		// passes read from this same buffer (the host re-feeds the column; no second allocation).
		void *ptr;
		auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
		if (!status.ok()) {
			throw IOException("Could not allocate z-score input buffer: " + status.message());
		}
		lstate.file_handle->Read(ptr, cc.total_compressed_size, cc.offset);
		auto input_buf =
		    libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);

		const auto type = parcore::metadata::to_libstf_type(cc.type);

		// Two source+decode pairs = the z-score's 2-pass contract: pass 1 accumulates mean/variance,
		// pass 2 classifies. The single sink receives the per-value outlier flags.
		oasis::OperatorFlow flow;
		flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		auto flag_buf = ctx.allocate_output_buffer(flag_size);
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(std::move(flag_buf), 0));

		oasis::QuerySplinter splinter;
		splinter.streams.push_back(std::move(flow));

		return InFlightZGroup{ctx.scheduler().submit(std::move(splinter)), cc.num_values};
	}
}

// Tops the in-flight window back up to WINDOW submitted groups (or until the groups run out). Keeping
// several 2-pass flows queued is what stops the decoder idling between groups.
void FillWindow(oasis::OasisContext &ctx, ZScoreGlobalState &gstate, ZScoreLocalState &lstate,
                const ZScoreBindData &bind) {
	constexpr size_t WINDOW = 8;
	while (lstate.in_flight.size() < WINDOW) {
		auto g = SubmitGroup(ctx, gstate, lstate, bind);
		if (!g) {
			break; // row groups exhausted
		}
		lstate.in_flight.push_back(std::move(*g));
	}
}

// Makes the next row group's flags current: tops up the pipeline, then collects the oldest in-flight
// group (FIFO -> row-group order preserved). Returns false once all groups are consumed.
bool LoadNextGroup(oasis::OasisContext &ctx, ZScoreGlobalState &gstate, ZScoreLocalState &lstate,
                   const ZScoreBindData &bind) {
	FillWindow(ctx, gstate, lstate, bind); // prime on the first call, top up thereafter
	if (lstate.in_flight.empty()) {
		return false; // all row groups done
	}

	auto group = std::move(lstate.in_flight.front());
	lstate.in_flight.pop_front();

	auto batch = group.handle.get_next_batch(); // usually already complete: it was submitted groups ago
	if (!batch) {
		throw InternalException("z-score flow closed with no output");
	}

	lstate.current_flags = std::move(batch->buffer);
	lstate.current_offset = 0;
	lstate.current_remaining = group.num_values;
	return true;
}

void ZScoreFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<ZScoreGlobalState>();
	auto &lstate = data_p.local_state->Cast<ZScoreLocalState>();
	auto &bind = data_p.bind_data->Cast<ZScoreBindData>();
	auto &ctx = *gstate.ctx;

	if (lstate.current_remaining == 0) {
		if (!LoadNextGroup(ctx, gstate, lstate, bind)) {
			output.SetCardinality(0);
			return;
		}
	}

	const size_t emit = std::min<size_t>(lstate.current_remaining, STANDARD_VECTOR_SIZE);

	auto &vec = output.data[0];
	vec.SetVectorType(VectorType::FLAT_VECTOR);
	// This DuckDB fork makes FlatVector::GetData const; GetDataMutable is the writable accessor.
	auto *out = FlatVector::GetDataMutable<bool>(vec);
	const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
	for (size_t i = 0; i < emit; i++) {
		out[i] = flags[lstate.current_offset + i] != 0;
	}
	output.SetCardinality(emit);

	lstate.current_offset += emit;
	lstate.current_remaining -= emit;
	if (lstate.current_remaining == 0) {
		lstate.current_flags = nullptr; // Release the flag buffer; next call loads the next group.
	}
}

} // namespace

void RegisterZScoreFunction(ExtensionLoader &loader) {
	TableFunction zscore("zscore",                                          // Function name
	                     {LogicalType::VARCHAR, LogicalType::VARCHAR},       // Args: parquet path, column name
	                     ZScoreFunction,                                     // Table function
	                     ZScoreBind,                                         // Bind
	                     ZScoreInitGlobal,                                   // Init global
	                     ZScoreInitLocal);                                   // Init local
	loader.RegisterFunction(zscore);
}

} // namespace duckdb

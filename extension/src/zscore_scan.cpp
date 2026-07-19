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

#include <libstf/profiling.hpp>

#include <algorithm>
#include <cstdlib>
#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace duckdb {

namespace {

using libstf::Profiler;

// Caliper region names (mirrors parcore's "ns::Class::" convention). Built ONCE at file scope:
// open_regions/close_regions take a const&, so passing these costs nothing per call. Building them
// inline (`{prefix + "emit"}`) concatenates a string, heap-allocates and frees a vector on EVERY
// call -- at ~49k calls per 100M-row scan that overhead dwarfed the regions themselves.
const std::vector<std::string> kFunction   = {"duckdb::zscore_scan::function"};
const std::vector<std::string> kLoadGroup  = {"duckdb::zscore_scan::load_group"};
const std::vector<std::string> kFillWindow = {"duckdb::zscore_scan::fill_window"};
const std::vector<std::string> kAllocate   = {"duckdb::zscore_scan::allocate"};
const std::vector<std::string> kRead       = {"duckdb::zscore_scan::read"};
const std::vector<std::string> kBuildFlow  = {"duckdb::zscore_scan::build_flow"};
const std::vector<std::string> kCollect    = {"duckdb::zscore_scan::collect"};
const std::vector<std::string> kEmit       = {"duckdb::zscore_scan::emit"};

// Bind-time state: which file, the ParCore metadata (row groups + chunk layout), and the resolved
// column index the z-score runs on.
struct ZScoreBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	size_t column_id = 0;
	// outliers_only: emit one BIGINT row id per outlier instead of one BOOLEAN per value. The scan then
	// hands DuckDB ~20k rows instead of 100M, so neither the emit loop nor a downstream filter has to
	// materialise and re-scan a bool per value.
	bool outliers_only = false;
	// First global row index of each row group, so outliers_only can report absolute row ids.
	std::vector<int64_t> group_first_row;
};

// Shared across workers. The only mutable shared state is the row-group cursor (claimed atomically),
// mirroring read_oasis. Capped to one worker for now -- this is the first hardware bring-up of the
// z-score path, so we keep it single-threaded and deterministic.
struct ZScoreGlobalState : public GlobalTableFunctionState {
	oasis::OasisContext *ctx = nullptr;
	size_t total_groups = 0;
	std::atomic<size_t> next_group {0};

	// Workers already claim row groups atomically off next_group and each owns its own file handle and
	// in-flight window, so the scan parallelises without further locking. Kept env-tunable because each
	// worker holds up to WINDOW row-group buffers in flight -- threads x WINDOW hugepage buffers must
	// still fit the pool, so sweep this rather than jumping straight to core count.
	// OASIS_ZSCORE_THREADS=1 restores the old serial behaviour exactly.
	idx_t MaxThreads() const override {
		const char *env = std::getenv("OASIS_ZSCORE_THREADS");
		if (env) {
			const int n = std::atoi(env);
			if (n > 0) {
				return (idx_t)n;
			}
		}
		return 4;
	}
};

// One row group submitted to the FPGA and awaiting its flags. The scheduler owns the 2-pass flow (and
// so keeps the input buffer mapped through BOTH passes) until it completes; we hold the handle to
// collect the flag buffer and num_values to know how many flags it carries.
struct InFlightZGroup {
	oasis::SplinterResultHandle handle;
	size_t num_values = 0;
	int64_t first_row = 0; // global row index of this group's first value
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
	int64_t current_first_row = 0; // global row index of current_flags[0]
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

	auto opt = input.named_parameters.find("outliers_only");
	if (opt != input.named_parameters.end()) {
		bind_data->outliers_only = BooleanValue::Get(opt->second);
	}

	// Prefix sum of per-group value counts: group g's first value is global row group_first_row[g].
	bind_data->group_first_row.resize(bind_data->metadata.groups.size());
	int64_t running = 0;
	for (size_t g = 0; g < bind_data->metadata.groups.size(); g++) {
		bind_data->group_first_row[g] = running;
		running += (int64_t)bind_data->metadata.groups[g].chunks[col_id].num_values;
	}

	if (bind_data->outliers_only) {
		names.emplace_back("row_id");
		return_types.emplace_back(LogicalType::BIGINT);
	} else {
		names.emplace_back("is_outlier");
		return_types.emplace_back(LogicalType::BOOLEAN);
	}
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
		Profiler::open_regions(kAllocate);
		auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
		Profiler::close_regions(kAllocate);
		if (!status.ok()) {
			throw IOException("Could not allocate z-score input buffer: " + status.message());
		}
		Profiler::open_regions(kRead);
		lstate.file_handle->Read(ptr, cc.total_compressed_size, cc.offset);
		Profiler::close_regions(kRead);
		auto input_buf =
		    libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);

		const auto type = parcore::metadata::to_libstf_type(cc.type);

		// Two source+decode pairs = the z-score's 2-pass contract: pass 1 accumulates mean/variance,
		// pass 2 classifies. The single sink receives the per-value outlier flags.
		Profiler::open_regions(kBuildFlow);
		oasis::OperatorFlow flow;
		flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		auto flag_buf = ctx.allocate_output_buffer(flag_size);
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(std::move(flag_buf), 0));

		oasis::QuerySplinter splinter;
		splinter.streams.push_back(std::move(flow));
		Profiler::close_regions(kBuildFlow);

		return InFlightZGroup{ctx.scheduler().submit(std::move(splinter)), cc.num_values,
		                      bind.group_first_row[group]};
	}
}

// Tops the in-flight window back up to WINDOW submitted groups (or until the groups run out). Keeping
// several 2-pass flows queued is what stops the decoder idling between groups.
void FillWindow(oasis::OasisContext &ctx, ZScoreGlobalState &gstate, ZScoreLocalState &lstate,
                const ZScoreBindData &bind) {
	constexpr size_t WINDOW = 8;
	Profiler::open_regions(kFillWindow);
	while (lstate.in_flight.size() < WINDOW) {
		auto g = SubmitGroup(ctx, gstate, lstate, bind);
		if (!g) {
			break; // row groups exhausted
		}
		lstate.in_flight.push_back(std::move(*g));
	}
	Profiler::close_regions(kFillWindow);
}

// Makes the next row group's flags current: tops up the pipeline, then collects the oldest in-flight
// group (FIFO -> row-group order preserved). Returns false once all groups are consumed.
bool LoadNextGroup(oasis::OasisContext &ctx, ZScoreGlobalState &gstate, ZScoreLocalState &lstate,
                   const ZScoreBindData &bind) {
	Profiler::open_regions(kLoadGroup);
	FillWindow(ctx, gstate, lstate, bind); // prime on the first call, top up thereafter
	if (lstate.in_flight.empty()) {
		Profiler::close_regions(kLoadGroup);
		return false; // all row groups done
	}

	auto group = std::move(lstate.in_flight.front());
	lstate.in_flight.pop_front();

	Profiler::open_regions(kCollect);
	auto batch = group.handle.get_next_batch(); // usually already complete: it was submitted groups ago
	Profiler::close_regions(kCollect);
	if (!batch) {
		Profiler::close_regions(kLoadGroup);
		throw InternalException("z-score flow closed with no output");
	}

	lstate.current_flags = std::move(batch->buffer);
	lstate.current_offset = 0;
	lstate.current_remaining = group.num_values;
	lstate.current_first_row = group.first_row;
	Profiler::close_regions(kLoadGroup);
	return true;
}

void ZScoreFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<ZScoreGlobalState>();
	auto &lstate = data_p.local_state->Cast<ZScoreLocalState>();
	auto &bind = data_p.bind_data->Cast<ZScoreBindData>();
	auto &ctx = *gstate.ctx;

	// Outermost region: every call into the table function. load_group/emit nest under it, so the
	// report reads as a tree and `function` (I) accounts for the whole scan's host time.
	Profiler::open_regions(kFunction);

	if (bind.outliers_only) {
		// Scan flags and emit only the outliers' row ids. A chunk may span several row groups (outliers
		// are rare), so keep loading groups until the output vector fills or the groups run out --
		// returning cardinality 0 is how DuckDB is told the scan is finished, so we must not do it early.
		auto &vec = output.data[0];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		auto *out = FlatVector::GetDataMutable<int64_t>(vec);
		idx_t n = 0;

		while (n < STANDARD_VECTOR_SIZE) {
			if (lstate.current_remaining == 0) {
				if (!LoadNextGroup(ctx, gstate, lstate, bind)) {
					break; // all row groups consumed
				}
			}
			const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
			Profiler::open_regions(kEmit);
			while (lstate.current_remaining > 0 && n < STANDARD_VECTOR_SIZE) {
				if (flags[lstate.current_offset] != 0) {
					out[n++] = lstate.current_first_row + (int64_t)lstate.current_offset;
				}
				lstate.current_offset++;
				lstate.current_remaining--;
			}
			Profiler::close_regions(kEmit);
			if (lstate.current_remaining == 0) {
				lstate.current_flags = nullptr; // release; next iteration loads the next group
			}
		}

		output.SetCardinality(n);
		Profiler::close_regions(kFunction);
		return;
	}

	if (lstate.current_remaining == 0) {
		if (!LoadNextGroup(ctx, gstate, lstate, bind)) {
			output.SetCardinality(0);
			Profiler::close_regions(kFunction);
			return;
		}
	}

	const size_t emit = std::min<size_t>(lstate.current_remaining, STANDARD_VECTOR_SIZE);

	auto &vec = output.data[0];
	vec.SetVectorType(VectorType::FLAT_VECTOR);
	// This DuckDB fork makes FlatVector::GetData const; GetDataMutable is the writable accessor.
	auto *out = FlatVector::GetDataMutable<bool>(vec);
	const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
	Profiler::open_regions(kEmit);
	for (size_t i = 0; i < emit; i++) {
		out[i] = flags[lstate.current_offset + i] != 0;
	}
	Profiler::close_regions(kEmit);
	output.SetCardinality(emit);

	lstate.current_offset += emit;
	lstate.current_remaining -= emit;
	if (lstate.current_remaining == 0) {
		lstate.current_flags = nullptr; // Release the flag buffer; next call loads the next group.
	}
	Profiler::close_regions(kFunction);
}

} // namespace

void RegisterZScoreFunction(ExtensionLoader &loader) {
	TableFunction zscore("zscore",                                          // Function name
	                     {LogicalType::VARCHAR, LogicalType::VARCHAR},       // Args: parquet path, column name
	                     ZScoreFunction,                                     // Table function
	                     ZScoreBind,                                         // Bind
	                     ZScoreInitGlobal,                                   // Init global
	                     ZScoreInitLocal);                                   // Init local
	zscore.named_parameters["outliers_only"] = LogicalType::BOOLEAN;
	loader.RegisterFunction(zscore);
}

} // namespace duckdb

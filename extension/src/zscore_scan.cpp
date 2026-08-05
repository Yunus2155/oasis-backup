#include "zscore_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/common/string_util.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <libstf/profiling.hpp>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace duckdb {

namespace {

using libstf::Profiler;

bool PerGroupMode(); // T2 diagnostic, defined below

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

// One row group submitted to the FPGA and awaiting its flags. This is phase 2 (CLASSIFY), so the flow
// is a single pass over the group; the scheduler keeps the input buffer mapped until it completes and
// we hold the handle to collect the flag buffer, with num_values telling us how many flags it carries.
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

	// A row group's flags do NOT always arrive in one buffer: the output writer raises one interrupt
	// per completed buffer, so under load a group can be split across several. Observed on hardware
	// at 12 host threads -- a 122,880-value group came back as 122,784 values plus a remainder.
	// Reading the group as a single buffer meant reading past what the FPGA had written, which
	// produced garbage flags and row ids that changed between runs.
	std::deque<std::shared_ptr<libstf::Buffer>> pending_batches; // rest of this group, in order
	std::shared_ptr<libstf::Buffer> current_flags;
	size_t current_flags_values = 0; // values still unread in current_flags
	size_t current_flags_pos = 0;    // read position within current_flags
	size_t current_offset = 0;    // values already emitted from THIS ROW GROUP (drives the row id)
	size_t current_remaining = 0; // values still to emit from this row group
	int64_t current_first_row = 0; // global row index of this group's first value
	size_t short_by = 0;           // values the flow never delivered (diagnostic mode only)
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

	// Pass 1 accumulates Sum(x^2) into the 64-bit signed sum_square_reg of z_score_squared.sv. That
	// register wraps silently on overflow -- the run still completes and still returns flags, they are
	// just wrong -- so reject the column here instead. Worst case is N * max(|x|)^2, bounded from the
	// footer statistics; columns without statistics are let through with no check (nothing to test).
	int64_t abs_max = 0;
	if (ParquetInt32ColumnAbsMax(parquet_reader, col_id, abs_max)) {
		uint64_t num_rows = 0;
		for (auto &group : meta.groups) {
			num_rows += group.chunks[col_id].num_values;
		}
		const unsigned __int128 worst_sum_sq =
		    (unsigned __int128)num_rows * (unsigned __int128)abs_max * (unsigned __int128)abs_max;
		if (worst_sum_sq > (unsigned __int128)std::numeric_limits<int64_t>::max()) {
			const double worst_approx = (double)num_rows * (double)abs_max * (double)abs_max;
			throw BinderException(
			    "zscore() would overflow the hardware sum-of-squares accumulator on column '%s': "
			    "%s rows with max |value| %s can reach ~%s, above the 64-bit signed limit "
			    "9223372036854775807. Rescale the column so that rows * max(|value|)^2 stays below "
			    "that limit (for example store currency in whole units rather than cents).",
			    column_name, std::to_string(num_rows), std::to_string(abs_max),
			    StringUtil::Format("%.3g", worst_approx));
		}
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

// Whole-column statistics supplied by the caller, for the phase-1 bypass diagnostic. Given as
// OASIS_ZSCORE_STATS="count,sum,sum_square" (the values gen_tpch.py / get_taxi.py already record in
// the manifest). Deliberately NOT computed with context.Query() here: InitGlobal runs inside the
// query that is being planned, and re-entering the same ClientContext deadlocks -- that is what hung
// the first attempt, not the accelerator.
oasis::ZScoreStatsConfig::Statistics ParseSuppliedStatistics(const char *spec) {
	oasis::ZScoreStatsConfig::Statistics stats;
	if (sscanf(spec, "%llu,%lld,%lld", (unsigned long long *)&stats.count, (long long *)&stats.sum,
	           (long long *)&stats.sum_square) != 3) {
		throw InvalidInputException(
		    "OASIS_ZSCORE_STATS must be \"count,sum,sum_square\", got '%s'", spec);
	}
	return stats;
}

// PHASE 1 of the global z-score: streams every row group through the operator in STATS mode and adds
// up the per-group partials it returns.
//
// This exists because the hardware can never see the whole column as one stream -- `tlast` arrives at
// the end of every parquet column chunk, and that is exactly what ends pass 1. Chaining all the row
// groups into a single flow would just produce N independent pass1/pass2 pairs, not one. Sum, sum of
// squares and count are additive though, so the totals assembled here are exactly the whole-column
// statistics, and phase 2 classifies against them.
//
// Deliberately serial: it runs once, in InitGlobal, before any scan thread starts, which is what
// gives the barrier between the two phases. The submit window still keeps the decoder fed.
oasis::ZScoreStatsConfig::Statistics ComputeGlobalStatistics(ClientContext &context,
                                                            oasis::OasisContext &ctx,
                                                            const ZScoreBindData &bind) {
	constexpr size_t WINDOW = 8;
	// One 64-byte beat per row group: [0] count, [1] sum, [2] sum_square, as three int64s.
	constexpr size_t STATS_BEAT_BYTES = 64;

	auto &fs = FileSystem::GetFileSystem(context);
	auto file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);

	std::deque<oasis::SplinterResultHandle> in_flight;
	oasis::ZScoreStatsConfig::Statistics totals;
	size_t next_group = 0;

	// Collects one finished STATS stream and folds its partials into the running totals.
	auto collect_one = [&]() {
		auto handle = std::move(in_flight.front());
		in_flight.pop_front();
		auto batch = handle.get_next_batch();
		if (!batch) {
			throw InternalException("z-score statistics flow closed with no output");
		}
		// Drain the flow to completion before dropping the handle. Phase 1 submits one flow per row
		// group -- hundreds of them -- immediately before phase 2 submits hundreds more. Leaving a
		// flow half-consumed leaves its completion state behind in the scheduler, and a stale buffer
		// then surfaces on a LATER handle: phase 2 pairs another group's flags with this group's
		// first_row, which shows up as correct-looking counts with row ids that shift between runs.
		while (handle.get_next_batch()) {
		}
		if (batch->buffer->size < STATS_BEAT_BYTES) {
			throw InternalException("z-score statistics beat is %llu bytes, expected at least %llu",
			                        (unsigned long long)batch->buffer->size,
			                        (unsigned long long)STATS_BEAT_BYTES);
		}
		const auto *words = reinterpret_cast<const int64_t *>(batch->buffer->ptr);
		totals.count += (uint64_t)words[0];
		totals.sum += words[1];
		totals.sum_square += words[2];
	};

	while (next_group < bind.metadata.groups.size() || !in_flight.empty()) {
		while (in_flight.size() < WINDOW && next_group < bind.metadata.groups.size()) {
			const auto &cc = bind.metadata.groups[next_group++].chunks[bind.column_id];
			if (cc.num_values == 0) {
				continue;
			}

			void *ptr;
			auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
			if (!status.ok()) {
				throw IOException("Could not allocate z-score statistics input buffer: " + status.message());
			}
			file_handle->Read(ptr, cc.total_compressed_size, cc.offset);
			auto input_buf =
			    libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);

			// One source+decode: STATS mode runs pass 1 and then emits the partials instead of
			// classifying, so there is no second pass over this group here.
			oasis::OperatorFlow flow;
			flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
			flow.push_back(
			    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, parcore::metadata::to_libstf_type(cc.type)));
			flow.push_back(std::make_unique<oasis::LocalSinkOperator>(
			    ctx.allocate_output_buffer(STATS_BEAT_BYTES), 0));

			oasis::QuerySplinter splinter;
			splinter.streams.push_back(std::move(flow));
			in_flight.push_back(ctx.scheduler().submit(std::move(splinter)));
		}
		if (!in_flight.empty()) {
			collect_one();
		}
	}

	return totals;
}

unique_ptr<GlobalTableFunctionState> ZScoreInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind = input.bind_data->Cast<ZScoreBindData>();
	auto gstate = make_uniq<ZScoreGlobalState>();
	gstate->ctx = &GetOrCreateOasisContext(context);
	gstate->total_groups = bind.metadata.groups.size();

	// Phase 1 -> totals -> phase 2. The mode switch is only safe because nothing is in flight: the
	// stats pass is fully drained before the totals are published, and no scan thread has started.
	if (PerGroupMode()) {
		// Run no statistics pass, but DO write the mode register once, with LEGACY. On a bitstream
		// that has ZScoreStatsConfig the operator holds its input off until `mode_valid` is set, so
		// skipping the write entirely leaves it refusing data forever -- seen as a hang on build-39.
		// A pre-global bitstream has no such config and nothing to write, which is not an error.
		try {
			gstate->ctx->config<oasis::ZScoreStatsConfig>()->set_mode(
			    oasis::ZScoreStatsConfig::Mode::Legacy);
		} catch (const std::exception &) {
			// Pre-global bitstream (e.g. build-38): LEGACY-only by construction, nothing to set.
		}
		return std::move(gstate);
	}

	auto stats_config = gstate->ctx->config<oasis::ZScoreStatsConfig>();
	oasis::ZScoreStatsConfig::Statistics totals;
	if (const char *supplied = std::getenv("OASIS_ZSCORE_STATS")) {
		// Diagnostic: skip phase 1 and compute the whole-column statistics on the CPU, so phase 2
		// runs on its own. Splits the global path in two -- if the short-flow loss survives this it
		// belongs to phase 2 / CLASSIFY; if it disappears it belongs to phase 1 or to the hand-over
		// between the phases. The results are identical either way, so correctness still applies.
		totals = ParseSuppliedStatistics(supplied);
	} else {
		stats_config->set_mode(oasis::ZScoreStatsConfig::Mode::Stats);
		totals = ComputeGlobalStatistics(context, *gstate->ctx, bind);
	}

	// OASIS_ZSCORE_DEBUG_STATS=1 prints the totals phase 1 assembled, so they can be diffed against
	// the exact values computed on the CPU. A mismatch localises a wrong result to phase 1
	// (partials lost or double-counted) rather than to the classification pass.
	if (std::getenv("OASIS_ZSCORE_DEBUG_STATS")) {
		fprintf(stderr, "[zscore] phase-1 totals: n=%llu sum=%lld sum_square=%lld\n",
		        (unsigned long long)totals.count, (long long)totals.sum, (long long)totals.sum_square);
	}

	stats_config->set_global_statistics(totals);
	stats_config->set_mode(oasis::ZScoreStatsConfig::Mode::Classify);

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

// Submits one row group's CLASSIFY pass to the scheduler WITHOUT blocking, returning the handle to
// collect its flags later. The whole-column statistics were already published by phase 1 in
// ZScoreInitGlobal, so this is a single pass over the group. Claims the next group atomically, skips empty ones, and returns nullopt
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

		// ONE source+decode: in CLASSIFY mode the operator does no pass 1, it compares straight
		// against the whole-column statistics phase 1 published (see ZScoreStatsConfig). The column
		// still crosses PCIe twice per query -- once in phase 1, once here -- exactly as it did when
		// each row group carried its own 2-pass, so this costs no extra bandwidth.
		Profiler::open_regions(kBuildFlow);
		oasis::OperatorFlow flow;
		flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		if (PerGroupMode()) {
			// LEGACY needs the column twice: pass 1 accumulates this group's stats, pass 2 classifies.
			flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
			flow.push_back(
			    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		}
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

// T2 diagnostic: OASIS_ZSCORE_PER_GROUP=1 reproduces the ORIGINAL per-row-group path on top of the
// current software -- no phase 1, the mode register is never written (so the operator stays in
// LEGACY), and every row group is submitted as its own 2-pass flow. Used to tell whether the
// short-flow beat loss arrived with the two-phase global work or predates it. Results are per-row-
// group z-scores by construction, so only the SHORT-flow count is meaningful in this mode.
bool PerGroupMode() {
	static const bool on = std::getenv("OASIS_ZSCORE_PER_GROUP") != nullptr;
	return on;
}

// Moves on to the next buffer of the current row group once the current one is fully read. A group's
// flags can span several buffers (one interrupt per completed buffer), and every read must stay
// inside the buffer it belongs to.
void AdvanceFlagBuffer(ZScoreLocalState &lstate) {
	while (lstate.current_flags_values == 0 && !lstate.pending_batches.empty()) {
		lstate.current_flags = std::move(lstate.pending_batches.front());
		lstate.pending_batches.pop_front();
		lstate.current_flags_values = lstate.current_flags->size / sizeof(int32_t);
		lstate.current_flags_pos = 0;
	}
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

	// Collect every buffer this flow produced until the group's flags are complete. One interrupt is
	// raised per completed buffer, so a group can arrive in several pieces; taking only the first
	// one silently reads unwritten memory past its end.
	const size_t expected = group.num_values * sizeof(int32_t);
	size_t collected = batch->buffer->size;
	lstate.pending_batches.clear();
	lstate.pending_batches.push_back(std::move(batch->buffer));
	while (collected < expected) {
		auto more = group.handle.get_next_batch();
		if (!more) {
			// OASIS_ZSCORE_TOLERATE_SHORT=1 keeps going instead of throwing, so one query can report
			// EVERY short flow at once. That tells us whether the missing beats reappear in another
			// flow (totals conserved, a buffer/flow misalignment) or are simply gone (data loss).
			if (std::getenv("OASIS_ZSCORE_TOLERATE_SHORT") || std::getenv("OASIS_ZSCORE_IGNORE_SHORT")) {
				fprintf(stderr, "[zscore] SHORT flow: %llu of %llu bytes, first_row=%lld values=%llu\n",
				        (unsigned long long)collected, (unsigned long long)expected,
				        (long long)group.first_row, (unsigned long long)group.num_values);
				break;
			}
			throw InternalException(
			    "z-score flow ended after %llu of %llu flag bytes for a %llu value row group",
			    (unsigned long long)collected, (unsigned long long)expected,
			    (unsigned long long)group.num_values);
		}
		collected += more->buffer->size;
		lstate.pending_batches.push_back(std::move(more->buffer));
	}
	if (collected > expected) {
		throw InternalException("z-score flow produced %llu flag bytes, expected %llu",
		                        (unsigned long long)collected, (unsigned long long)expected);
	}
	// A short flow leaves the tail of the group unread; clamp so we never read past what arrived.
	lstate.short_by = (expected - collected) / sizeof(int32_t);

	// OASIS_ZSCORE_IGNORE_SHORT=1 reads the group in FULL even when the completion reported fewer
	// bytes. This separates two very different failures: if the results are still exactly right, the
	// flags WERE written and only the reported length is wrong (a notify/size-accounting bug); if
	// they are wrong, beats really are missing from memory. The buffer is allocated for the whole
	// group either way, so reading it is in-bounds.
	const bool ignore_short =
	    lstate.short_by != 0 && std::getenv("OASIS_ZSCORE_IGNORE_SHORT") && lstate.pending_batches.size() == 1;
	if (ignore_short) {
		lstate.short_by = 0;
	}

	lstate.current_flags = std::move(lstate.pending_batches.front());
	lstate.pending_batches.pop_front();
	lstate.current_flags_values = lstate.current_flags->size / sizeof(int32_t);
	if (ignore_short) {
		// Read the whole group out of the buffer that was allocated for it, past the length the
		// completion reported.
		lstate.current_flags_values = group.num_values;
	}
	lstate.current_flags_pos = 0;
	lstate.current_offset = 0;
	lstate.current_remaining = group.num_values - lstate.short_by;
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
			AdvanceFlagBuffer(lstate);
			const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
			Profiler::open_regions(kEmit);
			// Bounded by what is left in THIS buffer as well as by the group and the output vector.
			while (lstate.current_flags_values > 0 && n < STANDARD_VECTOR_SIZE) {
				if (flags[lstate.current_flags_pos] != 0) {
					out[n++] = lstate.current_first_row + (int64_t)lstate.current_offset;
				}
				lstate.current_flags_pos++;
				lstate.current_flags_values--;
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

	AdvanceFlagBuffer(lstate);
	// Never read past the current buffer: a row group can span several of them.
	const size_t emit = std::min<size_t>(lstate.current_flags_values, STANDARD_VECTOR_SIZE);

	auto &vec = output.data[0];
	vec.SetVectorType(VectorType::FLAT_VECTOR);
	// This DuckDB fork makes FlatVector::GetData const; GetDataMutable is the writable accessor.
	auto *out = FlatVector::GetDataMutable<bool>(vec);
	const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
	Profiler::open_regions(kEmit);
	for (size_t i = 0; i < emit; i++) {
		out[i] = flags[lstate.current_flags_pos + i] != 0;
	}
	Profiler::close_regions(kEmit);
	output.SetCardinality(emit);

	lstate.current_flags_pos += emit;
	lstate.current_flags_values -= emit;
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

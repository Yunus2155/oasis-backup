# Oasis Learning Path — Beginner → Advanced

Companion to `~/celeris/LEARNING_PATH.md`. Oasis is a **systems-integration** project rather than an
RTL-primitives project: the hard parts are the seams between five codebases, the build-time
configuration matrix, and end-to-end performance. The path is shaped accordingly.

**Prerequisite.** Stages 1–4 of the Celeris path (SystemVerilog from VHDL, ready/valid discipline,
the Coyote sim framework, the AXI4-Lite config plane) are assumed here. Oasis reuses libstf's
`ndata_i` / `data_i` interfaces, `GlobalConfig`/`MemConfig`, `OutputWriter`, and `StreamProfiler`
without re-explaining them. Do Celeris Stages 1–4 first; you can skip Celeris Stages 5–7 (the DB
operators) if you only care about Oasis.

---

## Stage 0 — What Oasis actually is

> "A data processing SmartNIC for cloud-native data lakes. It offloads **Parquet decoding into the
> network data path**." — [README.md](README.md)

The pitch: a query engine on a cloud host reads Parquet from remote object storage. Normally the CPU
does RDMA/network receive → decompress → decode → then compute. Oasis moves decode (and some compute)
onto the FPGA, *in the path the bytes are already travelling*, so the CPU receives ready-to-use
columns.

### The repo stack — learn these names on day one

```
oasis/                     ← this repo: the vertical, the operators, the DuckDB extension
├── parcore/               ← Parquet decoder RTL + software (the heavy lifting)
│   ├── libstf/            ← the hardware standard library (interfaces, config, OutputWriter)
│   │   └── coyote/        ← the FPGA shell: PCIe, DMA, TLB, RDMA, HBM
│   └── vhsnunzip/         ← third-party Snappy decompressor
├── celeris/               ← the DB-operator repo (submodule; source of the z-score/covariance ideas)
└── extension/
    └── duckdb/            ← DuckDB itself, as a submodule
```

Five layers deep. Most confusing bugs in this project are **layer-boundary bugs**, not logic bugs.
When something breaks, first ask "which layer owns this?"

### The end-to-end path

```
Parquet file (remote or local)
   → RDMA / local read            (hardware/src/hdl/rdma_read.sv, local_read.sv)
   → ColumnChunkDecoder           (parcore: Snappy + RLE/bitpacking + dictionary)
   → post-decoder operator        (hardware/src/hdl/z-score/, covariance/)
   → OutputWriter → host DMA      (libstf)
   → DuckDB table function        (extension/src/*_scan.cpp)
   → SQL result
```

### The diagram, with ownership

Colour code: **[O]** = oasis · **[P]** = parcore · **[L]** = libstf · **[C]** = coyote · **[3P]** =
third party · **[D]** = duckdb

```
                          ┌─────────────────────────────────────────┐
   HOST (CPU)             │  SQL:  SELECT * FROM zscore('file.pq')  │
                          └────────────────────┬────────────────────┘
                                               │
  [D]  DuckDB engine ──────────────────────────┤
                                               │
  [O]  extension/src/zscore_scan.cpp ──────────┤  Bind / InitGlobal / InitLocal / Function
       extension/src/oasis_scan.cpp            │  ← sliding WINDOW of submits lives HERE
       extension/src/rdma_file_system.cpp      │
                                               │
  [O]  software/oasis/scheduler.cpp ───────────┤  splinters: submit → in-flight → complete
       software/oasis/operator.cpp             │
       software/oasis/configuration.cpp        │  ← register layout MUST match hw/common.sv
                                               │
  [L]  libstf: MemoryPool (hugepages)  ────────┤  buffers the FPGA will DMA into
       OutputBufferManager, TlbManager         │
                                               │
  [C]  Coyote driver + TLB ────────────────────┤  maps host vaddrs; shadows pages into HBM
  ─────────────────────────────────────────────┼───────────────────────────── PCIe ──────────
                                               │
   FPGA (Alveo U55C)                           │
                                               ▼
  [C]  Coyote shell: axis_host_recv/send, sq_wr/cq_wr/sq_rd, RDMA stack, HBM ports
                                               │
                                               ▼
                     ┌─────────────────────────────────────────┐
  [O]  READ REQUEST  │ read_req_config.sv → read_req_generator │  host says {vaddr, len}
                     └─────────────────┬───────────────────────┘
                                       ▼
                     ┌─────────────────────────────────────────┐
  [O]  SOURCE        │  rdma_read.sv   OR   local_read.sv      │  ifdef EN_RDMA
                     │  fix_last.sv  ← tlast semantics shim    │
                     └─────────────────┬───────────────────────┘
                                       ▼  compressed Parquet bytes
                     ┌─────────────────────────────────────────┐
  [P]  DECODE        │  ColumnChunkDecoder                     │  × N_DECODERS lanes
                     │   ├─ page_header_parser  (Thrift)       │
                     │   ├─ decompressor ─► vhsnunzip  ◄──[3P] │  Snappy
                     │   ├─ run_decoder ─► expand_rle          │
                     │   │              └► expand_bpe          │  RLE / bit-packed
                     │   ├─ hybrid_page_decoder                │  dictionary indices
                     │   └─ normalize_until, strip_levels      │  byte realignment
                     └─────────────────┬───────────────────────┘
                                       ▼  decoded 512-bit column beats
                     ┌─────────────────────────────────────────┐        ┌──────────────────┐
  [O]  COMPUTE       │  z_score_squared.sv  (2-pass)           │◄──────►│ [O] card_write   │
                     │        OR                               │  HBM   │  zscore_card_    │
                     │  covariance.sv       (1-pass, ifdef)    │        │  replay.sv       │
                     └─────────────────┬───────────────────────┘        │ (ifdef EN_MEM)   │
                                       │                                └──────────────────┘
                                       ▼                                  decode-once cache
                     ┌─────────────────────────────────────────┐
  [L]  OUTPUT        │  OutputWriter → stream_writer           │  FPGA-initiated DMA
                     └─────────────────┬───────────────────────┘
                                       ▼
  [C]  Coyote shell → PCIe → host buffer → back up to DuckDB ↑

  ── plumbing that touches everything ──────────────────────────────────────────────────────
  [L]  GlobalConfig / MemConfig  ─ AXI4-Lite config plane      (ids in [O] hardware/src/hdl/common.sv)
  [P]  ColumnChunkDecoderConfig  ─ decoder config + profiles
  [O]  zscore_profile_config.sv  ─ counter readout → SQL oasis_stream_profile()
  [L]  StreamProfiler            ─ the 4 counters, tapped at decoder-in, z-score, PCIe egress
  [L]  MetaIntfArbiter           ─ shares sq_wr/sq_rd between host path and card path
  [O]  hardware/src/vfpga_top.svh ─ wires ALL of the above together; the ifdef matrix
```

### How to read it

- **Everything in the middle column is one file you can open.** The diagram is a file index, not an
  abstraction.
- **The `[P]` box is where the time goes.** Decoding is the expensive part; that's why decode-once
  (the HBM side-loop) exists at all.
- **The two arrows that cross the PCIe line are the only interfaces that matter for performance:**
  requests going down, decoded data coming up. Every number in Stage 10 measures one of those.
- **`[C]` is a black box you configure, not code you write.** You will read Coyote's docs, not its
  RTL.
- **Ownership predicts the fix.** Wrong values → `[P]` or `[O]` compute. Nothing arriving → `[O]`
  source/read-request. Slow but correct → the host side, `[O]` extension/scheduler. Node crash →
  `[C]` boundary (addresses, hugepages).

**Done when** you can redraw this from memory and name the owning repo of any box without looking.

---

## Stage 1 — The domain: Parquet on the wire

You cannot read the decoder RTL without knowing the format. This is a reading stage, no code.

Learn, in this order:

1. **File layout** — file → row groups → column chunks → pages. A *column chunk* is the unit Oasis
   decodes; a *row group* is the unit the host submits.
2. **Page structure** — page header (Thrift-compact-encoded, hence the varint decoder), then
   optionally repetition levels, definition levels, then values.
3. **Encodings** — PLAIN (raw fixed-width values) and RLE/bit-packed hybrid (used for dictionary
   indices and levels). The hybrid encoding alternates run-length runs and bit-packed runs, each
   introduced by a varint header — this is exactly what `run_decoder.sv` implements.
4. **Compression** — Snappy, or none. Snappy is LZ77-style: literals plus back-references.
5. **Dictionary encoding** — a dictionary page of distinct values, then indices. This is *why*
   Celeris can support strings at all (Celeris README: strings only via dictionary encoding).

ParCore's scope, from [parcore/README.md](parcore/README.md): *"Snappy or no compression, plain and
dictionary/hybrid encoding."* Everything outside that is out of scope — knowing the boundary saves
you from hunting for code that doesn't exist.

**Done when** you can hand-decode a small RLE/bit-packed hybrid run on paper from its bytes.

---

## Stage 2 — ParCore: the decoder RTL

~3300 lines and the densest hardware in the stack. Read bottom-up; each module has its own Python
unit test, which is the fastest way to understand it.

| Order | Module | Lines | What it teaches |
|---|---|---|---|
| 1 | [varint_decoder.sv](parcore/hardware/src/hdl/varint_decoder.sv) | 39 | warm-up; serial byte parsing |
| 2 | [expand_rle.sv](parcore/hardware/src/hdl/expand_rle.sv) | 119 | run expansion → variable output rate |
| 3 | [expand_bpe.sv](parcore/hardware/src/hdl/expand_bpe.sv) | 191 | bit-packed extraction at arbitrary bit widths |
| 4 | [strip_levels.sv](parcore/hardware/src/hdl/strip_levels.sv) | 143 | rep/def levels |
| 5 | [normalize_until.sv](parcore/hardware/src/hdl/normalize_until.sv) | 259 | **byte-stream realignment** — the recurring hard problem |
| 6 | [hybrid_page_decoder.sv](parcore/hardware/src/hdl/hybrid_page_decoder.sv) | 277 | orchestrating 2+3 |
| 7 | [vhsnunzip_wrapper.sv](parcore/hardware/src/hdl/vhsnunzip_wrapper.sv) | 329 | wrapping third-party VHDL IP in an SV/AXI world |
| 8 | [decompressor.sv](parcore/hardware/src/hdl/decompressor.sv) | 118 | Snappy vs pass-through |
| 9 | [page_header_parser.sv](parcore/hardware/src/hdl/page_header_parser.sv) | 414 | Thrift compact protocol in hardware |
| 10 | [run_decoder.sv](parcore/hardware/src/hdl/run_decoder.sv) | 748 | the biggest file; budget real time |
| 11 | [column_chunk_decoder.sv](parcore/hardware/src/hdl/column_chunk_decoder.sv) | 471 | the top; what Oasis instantiates |
| 12 | [column_chunk_decoder_config.sv](parcore/hardware/src/hdl/column_chunk_decoder_config.sv) | 104 | its config + `decoder_profile_i` |

Run the matching tests as you go — [parcore/hardware/unit-tests/](parcore/hardware/unit-tests/) has
one per module (`bpe_decoder_test.py`, `run_decoder_test.py`, `page_header_parser_test.py`, …).

```bash
./scripts/setup_simulation.sh     # from the parcore dir, for parcore's own tests
```

**The theme of this whole stage:** *variable-rate, byte-unaligned streaming*. Compressed data arrives
in beats that have nothing to do with value boundaries. Every module here is some flavour of "buffer,
realign, emit as many complete things as I can this cycle." `normalize_until.sv` is the purest
expression of it — if you understand that one module, the rest follow.

**Note:** the decoder has been through at least one major revision (commit `4cb4cb9`, *"Bump parcore
to b3879a0 (dual-issue Snappy decompressor, 16B datapath)"*). When comparing benchmark numbers across
bitstreams, **which decoder generation was in that build matters more than almost anything else.**
See Stage 10.

**Done when** you can explain why the decoder, not the PCIe link, is usually the throughput ceiling.

---

## Stage 3 — The Oasis vFPGA top and its build matrix

[hardware/src/vfpga_top.svh](hardware/src/vfpga_top.svh) — 597 lines, the single most important file
in this repo. It is the integration point for everything.

### The build-time configuration matrix

Oasis is not one design; it's a family selected by `` `ifdef `` at synthesis time:

| Flag | Set by | Effect |
|---|---|---|
| `EN_RDMA` | `synthesize.sh` (default on; `--no-rdma` disables) | RDMA source instead of host streams; last stream slot becomes an RDMA bypass with no decoder |
| `EN_MEM` | shell config | exposes `axis_card_recv`/`axis_card_send` (HBM); enables the decode-once replay path |
| `EN_COVARIANCE` | hand-edited at [vfpga_top.svh:6](hardware/src/vfpga_top.svh#L6) | swaps the z-score vertical for the covariance vertical |
| `N_DECODERS` | `--decoders N` | how many `ColumnChunkDecoder` lanes |

```bash
./scripts/synthesize.sh [--no-rdma] [--decoders N] [--device u55c]
```

Read [scripts/synthesize.sh](scripts/synthesize.sh) properly. Builds land in `hardware/build-NN/`
with `bitgen.log`; expect multiple hours with long silent stretches.

### Read the file in this order

1. **Lines 1–105 — configuration.** Note `NUM_CONFIGS` is 4 or 5 depending on `EN_MEM`
   ([lines 45–49](hardware/src/vfpga_top.svh#L45-L49)), and that `GlobalConfig`'s `ADDR_SPACE_SIZES`
   list must have *exactly* `NUM_CONFIGS` entries — so the `ifdef` appears **twice** and the two must
   stay in sync ([lines 88–96](hardware/src/vfpga_top.svh#L88-L96)). This is the classic Oasis bug
   shape: a build-time option that must be edited in three places.
2. **[hardware/src/hdl/common.sv](hardware/src/hdl/common.sv)** — only 38 lines but every line
   matters: `OASIS_SYSTEM_ID`, the config IDs, `read_req_t`, and the register layouts the host must
   match byte-for-byte.
3. **Lines 176–236 — arbitration.** Read and write send-queues are *shared* between the host path
   and the card path, arbitrated by `MetaIntfArbiter`. Resource sharing across `ifdef` variants is
   where subtle deadlocks live.
4. **Lines 238–539 — the datapath**, following whichever `ifdef` branch you care about first.
5. **Lines 541–597 — `OutputWriter` + the egress profiler.**

**Build:** produce a table of every `` `ifdef `` in the file and what each branch changes. You will
refer to it constantly.

**Done when** you can predict, for any `synthesize.sh` invocation, which modules end up in the
bitstream.

---

## Stage 4 — Getting data in: read requests, RDMA, and local reads

Small, readable modules — a good breather after ParCore.

- [read_req_config.sv](hardware/src/hdl/read_req_config.sv) + [read_req_generator.sv](hardware/src/hdl/read_req_generator.sv)
  — the host describes *what to fetch* as `read_req_t { vaddr, len }`
  ([common.sv:11-14](hardware/src/hdl/common.sv#L11-L14)); the generator turns that into Coyote
  descriptors. **Watch the stride arithmetic here** — a wrong stride silently fetches the wrong bytes
  rather than erroring, and has cost real debugging time on this project.
- [local_read.sv](hardware/src/hdl/local_read.sv) — host-memory source (58 lines).
- [rdma_read.sv](hardware/src/hdl/rdma_read.sv) — remote source (111 lines).
  Test: [rdma_read_test.py](hardware/unit-tests/rdma_read_test.py) +
  [vfpga-tops/rdma_read_test.sv](hardware/unit-tests/vfpga-tops/rdma_read_test.sv).
- [fix_last.sv](hardware/src/hdl/fix_last.sv) — 46 lines, and a perfect illustration of a
  layer-boundary problem: `tlast` semantics differ between producers, so a shim re-derives it.
- [rdma_server/](rdma_server/) — the peer that serves the data. Read its
  [README](rdma_server/README.md) and [main.cpp](rdma_server/src/main.cpp).

**Done when** you can trace one `read_req_t` from a host register write to bytes entering a decoder.

---

## Stage 5 — Post-decoder operators (the compute)

Both files are heavily commented by design — **read the header comments as tutorials**, they explain
the maths and the timing reasoning together.

### Covariance — single-pass, the design to imitate

[hardware/src/hdl/covariance/covariance.sv](hardware/src/hdl/covariance/covariance.sv) (220 lines)

- 512-bit beat = one observation of up to 16 features (32-bit lanes).
- One pass accumulates `Σx_i`, `Σx_i·x_j` (136 upper-triangular pairs), and `num_rows`.
- **The final divide happens on the host**: `cov(i,j) = (N·Σxy − Σx·Σy) / N²`. That's O(M²) trivial
  work for the CPU and avoids an on-chip divider entirely.
- Output is 306 raw-sum words (`TOTAL_WORDS = 2·136 + 2·16 + 2`).
- Up to **136 MACs/cycle** through pipelined `int_mult_32` IPs. Because the IP has `lat = 6` cycles
  of latency, the per-lane `keep` mask is delayed by a matching `keep_reg` pipeline, and a `lat`-cycle
  drain after `tlast` lets the last products land.

**This is the model answer for FPGA operator design:** push the O(M²·N) reduction to hardware, leave
the O(M²) finalisation to the host, and never build a divider you don't need.

### Z-score — two-pass, and a timing-closure case study

[hardware/src/hdl/z-score/z_score_squared.sv](hardware/src/hdl/z-score/z_score_squared.sv) (347 lines)

- Pass 1 accumulates `Σx`, `Σx²`, `n`; pass 2 re-streams the data and flags outliers.
- Avoids square roots and division entirely by comparing squares: outlier iff
  `(n·x − S)² > k²·(n·Q − S²)`, with `k = 3` ⇒ `k² = 9`. **Reformulating the maths to avoid an
  expensive operator is the single highest-leverage FPGA design move.**
- The pass-1 reduction is deliberately split into four registered stages (per-lane square → 16→4 →
  4→1 → accumulate) so it isn't "one deep multiply + adder tree + accumulate" cone. That split is
  what made timing close.
- `MULT_LAT = 18` and `SQ_LAT = 6` **must match `PipeStages` in `init_ip.tcl`** — both are flagged
  with `!!` comments. A mismatch is silently wrong data, not an error. Metadata (valid/keep/last)
  travels down matched delay lines to stay aligned with the products.

Tests: [z_score_test.py](hardware/unit-tests/z_score_test.py),
[z_score_decode_test.py](hardware/unit-tests/z_score_decode_test.py),
[covariance_test.py](hardware/unit-tests/covariance_test.py),
[covariance_decode_test.py](hardware/unit-tests/covariance_decode_test.py) — note the `_decode_`
variants test the operator *behind a real decoder*, which is the configuration that actually ships.

**Build:** re-derive the z-score outlier inequality from `|x − μ| > k·σ` and confirm the integer form
in the code is exact (no rounding). Then check the `DIFF_W = 64` assumption `|n·x − S| < 2^63` against
a realistic row count.

**Done when** you can state, for any operator, whether it's single-pass or two-pass and why.

---

## Stage 6 — Decode-once: HBM, replay, and the address-space lesson

The most instructive subsystem in the repo, because the design constraint is non-obvious and cost
real hardware crashes to discover.

**Problem:** the two-pass z-score decodes the same column twice. If you're decoder-bound, that's a
literal 2× on the dominant cost.

**Fix:** during pass 1, write the *decoded* column into HBM; during pass 2, replay it from HBM
instead of re-decoding.

Read:
- [hardware/src/hdl/common.sv:26-37](hardware/src/hdl/common.sv#L26-L37) — **read this comment block
  three times.** It is the hard-won lesson:
  > *"The vaddr CANNOT be invented in RTL: Coyote has no card address space... A `STRM_CARD`
  > descriptor carries a HOST USER VIRTUAL ADDRESS whose pages the driver shadows into HBM via the
  > TLB — `strm` picks which copy of that vaddr the DMA hits, not a different address space. An
  > unmapped vaddr makes the vFPGA page-fault into the driver."*

  Consequence: the host must allocate and map the scratch buffer and pass its vaddr down. RTL that
  makes up an address takes down the node with a kernel oops.
- [card_buffer_config.sv](hardware/src/hdl/card_buffer_config.sv) — how that buffer arrives (packed
  exactly like `MemConfig`: `vaddr << BUFFER_SIZE_BITS | capacity`).
- [card_write.sv](hardware/src/hdl/card_write.sv) — pass-1 store.
- [zscore_card_replay.sv](hardware/src/hdl/zscore_card_replay.sv) — pass-2 replay.
- The `EN_MEM` branches in [vfpga_top.svh:335-504](hardware/src/vfpga_top.svh#L335-L504).
- Test: [z_score_card_replay_test.py](hardware/unit-tests/z_score_card_replay_test.py).

**How to verify replay is actually engaging** (not just "it didn't crash"): the decoder's input
handshake count must **halve** versus the non-replay build. If it doesn't, the second pass is still
decoding and the feature is silently doing nothing. Wall-clock alone will not tell you this.

Also note: `EN_MEM=1` brings a hugepage ceiling into play. Allocation sizes that worked with
`EN_MEM=0` may not work here.

**Done when** you can explain why an FPGA cannot choose its own HBM addresses under Coyote.

---

## Stage 7 — The Oasis software library

The C++ layer that turns the vFPGA into something a query engine can call.

```bash
mkdir software/build
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt
cmake --build software/build -j
cmake --install software/build
```

Read in this order:
1. [software/oasis/operator.hpp](software/oasis/operator.hpp) — the pipeline model:
   `SourceOperator` (→ `RDMASourceOperator`, `LocalSourceOperator`), `DecodeColumnChunkOperator`,
   `LocalSinkOperator`. A query is a small DAG of these.
2. [query_splinter.hpp](software/oasis/query_splinter.hpp) — a *splinter* is one unit of work handed
   to the FPGA. Get this abstraction straight before reading the scheduler.
3. [scheduler.hpp](software/oasis/scheduler.hpp) / [scheduler.cpp](software/oasis/scheduler.cpp) —
   the interesting file. `InFlight`, `Pending`, `PendingCompletion`, `StreamState`: this is the
   asynchronous submit/complete engine, and **it is where throughput is won or lost** (Stage 9).
4. [oasis_context.hpp](software/oasis/oasis_context.hpp) — device/lifetime ownership.
5. [configuration.hpp](software/oasis/configuration.hpp) — the mirror image of the RTL config blocks.
   **Every register layout here must match `hardware/src/hdl/common.sv` exactly.** A mismatch is a
   silent wrong-data bug.
6. [bypass_stream_manager.hpp](software/oasis/bypass_stream_manager.hpp) — the RDMA bypass lane.

**Done when** you can follow a splinter from `Scheduler` submission to completion callback.

---

## Stage 8 — The DuckDB extension

```bash
cd extension && make -j          # requires the oasis library installed first
```

Also read [extension/README.md](extension/README.md) and [extension/docs/UPDATING.md](extension/docs/UPDATING.md).

### The DuckDB table-function contract

Every Oasis SQL entry point follows the same four-callback shape — learn it once from
[extension/src/zscore_scan.cpp](extension/src/zscore_scan.cpp) (378 lines, the clearest example):

| Callback | Role | In `zscore_scan.cpp` |
|---|---|---|
| `Bind` | parse args, declare the output schema | `ZScoreBind` (line ~106) |
| `InitGlobal` | one shared state per query | `ZScoreInitGlobal` (~165) |
| `InitLocal` | **one state per worker thread** | `ZScoreInitLocal` (~173) |
| the function | produce one `DataChunk` per call | `ZScoreFunction` (~290) |
| registration | `TableFunction` + `RegisterFunction` | ~368 |

Note the comment at `ZScoreInitLocal`: *"Each worker owns its file handle: DuckDB FileHandles are not
safe to share across threads."* Thread-safety at this boundary is a real hazard.

Then read:
- [oasis_scan.cpp](extension/src/oasis_scan.cpp) (680 lines) — the main scan; the biggest file.
- [filter_pushdown.cpp](extension/src/filter_pushdown.cpp) — pushing SQL predicates toward the FPGA.
- [coalesced_fetcher.cpp](extension/src/coalesced_fetcher.cpp) — merging small reads into large ones.
- [rdma_file_system.cpp](extension/src/rdma_file_system.cpp) — a DuckDB `FileSystem` backed by RDMA.
- [oasis_profile.cpp](extension/src/oasis_profile.cpp) — exposes the hardware counters as the
  `oasis_stream_profile()` SQL function. Stage 9 depends on this.
- [oasis_settings.cpp](extension/src/oasis_settings.cpp), [oasis_extension.cpp](extension/src/oasis_extension.cpp).

**Build:** add a trivial new table function (e.g. one returning the decoder count from a config
register) end to end: RTL read-config → `configuration.hpp` → new `*_scan.cpp` → SQL.

**Done when** you can write a new DuckDB table function without copying an existing one wholesale.

---

## Stage 9 — Build, flash, and run discipline

This stage is procedural, not conceptual, and skipping it costs hours per mistake.

### Build order (non-negotiable)

```
1. libstf / parcore software libs  (if their branch changed)
2. oasis software library          → installs into ~/opt
3. DuckDB extension                → links against ~/opt
```

> ⚠️ **The ABI trap.** There is exactly **one** `liboasis.so` in `~/opt` at a time, and different
> branches expose different symbols (e.g. `bypass_manager` vs `bypass_receiver`). An
> undefined-symbol error at link or load time almost always means *"you're linking the library built
> from a different branch."* **Rebuild and install the software library from your current branch
> first, then the extension.** Doing this also breaks binaries built on the other branch — expect to
> re-install when you switch back.

### On the board

Use the `setup-board` skill, or manually: compile the Coyote driver against the node's kernel,
reserve 1 GiB hugepages, program the bitstream, load the driver, then open DuckDB.

> ⚠️ **A hung run poisons the board.** After any hang, *every* subsequent run fails — including code
> you know is good. **Reflash the bitstream before every run** while debugging. Not knowing this
> produces confident, completely wrong diagnoses of your latest change.

Two more environment facts worth writing on a sticky note:
- HBM/`EN_MEM=1` builds hit a hugepage ceiling that `EN_MEM=0` builds don't.
- `hacc-build-02` has no FPGA — it's for building and simulation only.

### Which bitstream is which

`hardware/build-NN/` accumulates fast (05 … 31 already). Each should carry a `BUILD_INFO.txt` —
e.g. build-31 is *"4 x decoder + zscore pipeline with latest commit of hoca profiler."* **Write one
for every build you kick off.** When comparing numbers, determine the configuration from the *frozen
RTL in the build directory*, not from the directory's timestamp or your memory of what you were
working on that day.

**Done when** a full rebuild-flash-run cycle is muscle memory.

---

## Stage 10 — Performance engineering

The main event. Oasis is fast enough that the bottleneck moves between subsystems as you fix things,
and the only defence is measurement.

### The four counters

`StreamProfiler` (from libstf) taps any ready/valid pair. Read them from SQL via
`oasis_stream_profile()` ([oasis_profile.cpp](extension/src/oasis_profile.cpp)); the RTL side is
[zscore_profile_config.sv](hardware/src/hdl/zscore_profile_config.sv) and the `decoder_profile_i`
plumbing in [vfpga_top.svh](hardware/src/vfpga_top.svh).

| Counter | Condition | Means |
|---|---|---|
| `handshakes` | `valid && ready` | useful work |
| `starved` | `ready && !valid` | **upstream** is too slow (usually the decoder) |
| `stalled` | `valid && !ready` | **downstream** is too slow (DMA / output writer) |
| `idle` | neither | **the host isn't keeping work in flight** |

Taps exist on the decoder input, each z-score lane, and the PCIe egress
([vfpga_top.svh:564+](hardware/src/vfpga_top.svh#L564)). `NUM_ZSCORE_PROFILES = NUM_DECODERS +
NUM_STREAMS` — per-lane profiles plus egress taps.

### The three levers, in the order they usually matter

1. **Host feed depth (`idle`).** The single biggest lever found on this project. Submitting one row
   group at a time leaves the FPGA idle most of the time; a **sliding window** of submissions fixes
   it. See `WINDOW = 8` at
   [extension/src/zscore_scan.cpp:248](extension/src/zscore_scan.cpp#L248) and the comment at line 66
   (*"threads × WINDOW hugepage buffers must be affordable"*) — the window is bounded by memory.
   Measured effect on the covariance vertical: idle down 27–42×, throughput 3.2 → 11.3 GB/s.
2. **Host CPU work (`idle`, again).** Sparse emission (only materialise the rows you must) plus
   multithreaded emission roughly halved z-score wall time in one change. If `idle` is high and the
   window is already deep, profile the *CPU*, not the FPGA.
3. **Decoder throughput (`starved`).** More decoder lanes (`--decoders N`), a faster decoder
   generation, or decode-once replay (Stage 6).

### The trap that will catch you once

**Fixing `starved` can convert starved cycles into idle cycles one-for-one, with ~0% wall-clock
improvement.** This genuinely happened here: a new decoder generation cut starved cycles 2.75× and
delivered no speedup at 100M rows, because the bottleneck simply moved to the host feed. Rules:

- Always read **all four** counters before and after, never just the one you were targeting.
- Always confirm with **wall-clock time**. Counters explain *why*; they don't prove *faster*.
- Change **one** variable per build. With multi-hour synthesis, a 2×2 experiment matrix is a day —
  plan it deliberately rather than drifting into it.

### CPU-side profiling

libstf integrates Caliper: build **libstf from its own directory** with
`-DLIBSTF_WITH_PROFILING=ON`. Passing that flag to the Oasis CMake does **nothing** if `find_package`
resolves to a prebuilt libstf — a genuinely wasted-afternoon trap. Keep separate install prefixes
(e.g. `~/opt` vs `~/opt-prof`); Caliper's overhead is large, and it measures only what you explicitly
wrap in regions.

**Done when** you can look at an `oasis_stream_profile()` row and name the bottleneck plus the next
experiment, in one sentence each.

---

## Stage 11 — Adding a new vertical

The full recipe, once everything above is fluent:

1. **Choose the maths for one pass.** Ask whether raw moments (Σx, Σx², Σxy) let the host finish the
   job — as covariance does. If yes, you avoid two-pass entirely. If no, plan for decode-once replay
   (Stage 6) rather than naive double decode.
2. **Operator RTL** in `hardware/src/hdl/<op>/`. `AXI4S` in, `AXI4S` out, `AXIToNData` for a typed
   view. Pipeline the reduction into registered stages from the start; don't wait for timing to fail.
3. **Pipeline any multiplier as a DSP IP**, and mirror its latency onto the metadata path. Write the
   `// !! MUST match init_ip.tcl` comment — you will forget otherwise.
4. **A `StreamProfiler` on input and output**, exposed through a read-config block.
5. **Config block** in `hardware/src/hdl/`, an ID in [common.sv](hardware/src/hdl/common.sv), and a
   slot in `NUM_CONFIGS` + `ADDR_SPACE_SIZES` in [vfpga_top.svh](hardware/src/vfpga_top.svh) —
   remembering the `ifdef` appears twice.
6. **Two tests**: standalone (`<op>_test.py` + `vfpga-tops/<op>_test.sv`) and behind a real decoder
   (`<op>_decode_test.py`). Ship both.
7. **Host mirror** in [software/oasis/configuration.hpp](software/oasis/configuration.hpp), matching
   the register layout exactly.
8. **DuckDB table function** in `extension/src/<op>_scan.cpp`, with a sliding submission window from
   day one.
9. Synthesize, check timing, write `BUILD_INFO.txt`, flash, verify correctness on small input, *then*
   benchmark.

---

## Capstone ladder

1. **Beginner** — get the simulation environment up and make every existing unit test pass; explain
   one decoder test's waveform.
2. **Intermediate** — add a new read-only config register readable from SQL, end to end (RTL → C++ →
   DuckDB).
3. **Advanced** — build a new single-pass operator (min/max/quantile-sketch) with both test variants,
   synthesize to timing closure, and profile it.
4. **Expert** — take it through the full vertical with a windowed DuckDB table function, and defend
   an end-to-end speedup number using the four profiler counters plus wall-clock.

---

## Cheat-sheet: read order

```
README.md                                      ← the pitch and the build commands
hardware/src/hdl/common.sv                     ← 38 lines, all of them load-bearing
hardware/src/vfpga_top.svh                     ← THE integration file; the ifdef matrix
parcore/README.md                              ← decoder scope and limits
parcore/hardware/src/hdl/varint_decoder.sv     ← start of the decoder ladder
  → expand_rle → expand_bpe → normalize_until → hybrid_page_decoder
  → page_header_parser → run_decoder → column_chunk_decoder
hardware/src/hdl/read_req_generator.sv         ← how data gets requested
hardware/src/hdl/covariance/covariance.sv      ← the model single-pass operator
hardware/src/hdl/z-score/z_score_squared.sv    ← two-pass + timing-closure case study
hardware/src/hdl/card_buffer_config.sv         ← the HBM address-space lesson
software/oasis/scheduler.hpp                   ← where host throughput is won
extension/src/zscore_scan.cpp                  ← the DuckDB table-function template
extension/src/oasis_profile.cpp               ← reading the counters from SQL
```

## Gotchas, collected

- Five nested repos — identify the owning layer before debugging.
- `NUM_CONFIGS` and `ADDR_SPACE_SIZES` must agree; the `ifdef` appears twice.
- `MULT_LAT` / `SQ_LAT` / `lat` must match `PipeStages` in `init_ip.tcl` — mismatch = silent wrong data.
- RTL cannot invent a card vaddr; the host allocates and maps, always.
- To confirm decode-once is engaging, check that decoder handshakes **halve** — not wall-clock.
- One `liboasis.so` in `~/opt`: rebuild the software lib from your branch **before** the extension.
- Reflash before every run while debugging; a hung run poisons the board.
- `EN_MEM=1` has a hugepage ceiling that `EN_MEM=0` does not.
- Write `BUILD_INFO.txt` for every build; identify configurations from frozen RTL, not dates.
- Fixing `starved` often just converts it to `idle`. Read all four counters; confirm with wall-clock.
- `-DLIBSTF_WITH_PROFILING=ON` on the Oasis CMake does nothing — build libstf from its own directory.
- `hacc-build-02` has no FPGA.

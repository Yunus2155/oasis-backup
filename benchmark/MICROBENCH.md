# Microbenchmarks — the z-score half of the joint paper

Five tests, matching the IQR half so the two halves plot together. **Panels: 1, 3, 4.** Test 0 is a
table, Test 5 is two sentences.

| # | test | axis | what it supports | protocol |
|---|---|---|---|---|
| 0 | real datasets | 7 real columns, everything varying | the table a reviewer believes: "this works on data we did not design" | **medians of 15, END-TO-END s** |
| 1 | size sweep | 1M → 100M rows | the FPGA wins at every size, and the advantage is durable at scale | mean-of-last-3, operator ms |
| 3 | core sweep | 1 → 32 host threads | the offload claim: the FPGA path is flat in host core count | mean-of-last-3, operator ms |
| 4 | codec sweep | 8 representations of the same 20M numbers | the statistics stage is representation-invariant; the shared decoder is where the time goes | mean-of-last-3, operator ms |
| 5 | skew sweep | skewness 0 → ~3.4 | ⚠️ **a control, not a panel** — defends 1/3/4 (all uniform data) against "real data is skewed" | mean-of-last-3, **run TWICE** |

⚠️ **Test 0 uses a different protocol from the other four.** Report its numbers as end-to-end
seconds and the rest as operator milliseconds, and say which is which. Mixing them silently is
worse than having only one.

There is **no cardinality sweep**. It is IQR-specific: their CPU baseline pays for a `GROUP BY`,
ours is count/sum/sum-of-squares, i.e. O(rows) and cardinality-independent. Both of our arms would
be flat and the panel would say nothing.

## Configuration this was built for

| | |
|---|---|
| branch | `global-zscore` |
| bitstream | `hardware/build-41` (3 lanes, `--no-rdma --decoders 3`, EN_MEM=0) |
| binary | `~/duckdb-bench41` — the restore point's build **plus** the timing instrumentation |
| node | `alveo-u55c-09` |
| data | `~/bench/microbench/` |

⛔ `~/duckdb-global-fix` is the known-good restore-point binary and must not be overwritten.

## What differs from the roadmap, and why

**1. The value space is scaled down.** Pass 1 accumulates Σx² into a signed 64-bit register that
wraps silently (`z_score_squared.sv`), and the exact check in `ComputeGlobalStatistics()` throws
when it would. The roadmap's constants need Σx² = 3.63e19 at 100M rows — **3.94× over the 9.22e18
limit**, so its Test-1 recipe is unusable above ~26M rows, and its Test-4 recipe is 790× over.

z-score is scale-invariant, so dividing every value by a constant preserves **every ratio in the
gap argument exactly** while Σx², which scales with the square, shrinks quadratically:

| | roadmap | here | ratio preserved? |
|---|--:|--:|---|
| Test 1 base range | `[0, 1e6)` | `[0, 250000)` | — |
| Test 1 outlier offset | `+5e6` | `+1,250,000` | — |
| base top vs threshold | 1.49× below | **1.49× below** | ✅ |
| outlier floor vs threshold | 3.35× above | **3.35× above** | ✅ |
| Σx² at 100M rows | 3.63e19 ❌ | **2.27e18** (4.06× headroom) | — |
| Test 4 range / offset | 1e7 / +5e7 | 500,000 / +2,500,000 | ✅ same ratios |
| Σx² at 20M rows | 7.3e21 ❌ | **1.82e18** (5.1× headroom) | — |

Cost: Test 1's cardinality is 250,000 rather than 1,000,000. Row groups hold 122,880 rows, so
distinct-per-group (~97k) and therefore the writer's encoding decision are unchanged — the sweep
still runs PLAIN throughout, which is the property that mattered. Test 4's `hi` level is 400,000
rather than 1,000,000, still ~106k dictionary entries per row group: under the hardware's 524,288
bound (`ID_BITS=19`) and still large enough that the dictionary **grows** the file, which is the
sign change the design needs.

**Expected flags = rows / 1000, exactly, at every point of every test.** The generators gate on it
and the harness checks it on all 7 iterations of every point.

**2. INT32 only.** The datapath is `ELEM_BITS=32` and `ZScoreBind` rejects anything else, so every
generated column is `INTEGER`, not `BIGINT`. This also means PLAIN is 4 B/row rather than 8, which
weakens (but does not reverse) the dictionary's size effect at the `lo` level.

**3. No fusion.** That is an IQR mechanism. Test 1 is a single FPGA curve. The `pass1` and `fused`
CSV columns are kept as constants (`global` / `na`) so both halves share plotting code.

**4. `fpga_decode_ms` is phase 1, `fpga_passes_ms` is phase 2.** Our split is at the statistics
barrier, not at the decoder: phase 1 = read + decode + STATS with only 64 bytes of egress per row
group, phase 2 = read + decode + classify + flag egress. **Both phases decode.** The column names
match the IQR schema for plotting; the meaning must be stated in the paper rather than implying a
decode timer we do not have.

**5. The CPU arm is DuckDB SQL, not a table function**, so it cannot print a `heavy` line and its
operator time is the query's own wall time. That is fair here in a way it would not be for a
`CREATE TABLE`: both arms are a scan plus a count aggregate, and the aggregate is identical on both
sides. The baseline computes the **same algorithm** as the hardware — a two-pass population z-score
with |z| > 3 — not whatever DuckDB could do fastest.

**A harmless warning to expect.** `ZScoreBind` bounds Σx² by `rows × max|x|²`, which assumes every
row carries the outlier value; on this data that bound is ~100× pessimistic, so every query prints
`[zscore] warning: ... above the 64-bit limit`. It is a warning by design — the exact test runs in
phase 1 on the real sums. The harness ignores it.

## Running it

**Everything runs on the Alveo node.** The extension creates the OasisContext at `Load()`
(`oasis_extension.cpp:69`), so the binary cannot even open without 1 GiB huge pages — dataset
generation included. There is no vanilla DuckDB CLI on this host and no network from the compute
nodes, so generating elsewhere is not an option. The `tpch` extension is already cached in
`~/.duckdb/extensions`, so `LOAD tpch` works offline.

```bash
# 0. build with the instrumentation, then:  cp extension/build/release/duckdb ~/duckdb-bench41
# 1. on the Alveo node
~/flash.sh 41
timeout 300 ~/duckdb-bench41 -c \
  "SELECT count(*) FROM zscore('$HOME/bench/taxi_fare.parquet','x') WHERE is_outlier;"   # => 10312

# 2. datasets. Every generator has a `plan`/`verify` mode; GATES MUST PASS BEFORE ANY MEASUREMENT.
cd ~/oasis/benchmark
./gen_real.sh plan            # measures Sum(x^2) at both money scales, writes nothing
./gen_real.sh                 # Test 0   (~15 min; SF10 dbgen is the long pole)
./gen_size_sweep.sh           # Test 1   (~25 min; the 100M-row file)
./gen_codec_sweep.sh          # Test 4 + the Test 3 knee control (~15 min)
./gen_skew_sweep.sh           # Test 5   (~10 min)

# 3. the tests
python3 microbench.py real   --csv real_datasets.csv            | tee real.log
python3 microbench.py size   --csv size_sweep.csv               | tee size_sweep.log
python3 microbench.py codec  --csv codec_sweep.csv              | tee codec_sweep.log
python3 microbench.py thread --csv thread_sweep_balanced.csv    | tee thread_balanced.log
python3 microbench.py thread --knee --csv thread_sweep_knee.csv | tee thread_knee.log
python3 microbench.py skew   --csv skew_sweep.csv               | tee skew1.log
python3 microbench.py skew   --csv skew_sweep_rep2.csv          | tee skew2.log   # THE REPEAT
```

### Test 0 and Test 5 specifics

**Test 0 has no planted outliers**, so the correctness target is the CPU reference count that
`gen_real.sh` computes per file and writes into the manifest. It also has only **two arms**: the
roadmap's third (`sql`) exists to prove their hand-written `cpp` operator is not a strawman, but
our baseline *is* the SQL, so the question does not arise and the `cpp_*` columns stay empty.

Money scale: `l_extendedprice` is stored in **whole dollars**, not cents — cents give Σx² ≈ 8.8e19
at SF1, ~10× the accumulator (their own digest table is what shows this: mean 3.83e6 cents over
6.0M rows). So the two `extprice` digests deliberately do **not** match the roadmap's. For the taxi
column the answer is not obvious, so `gen_real.sh plan` **measures** it and picks the finest scale
with ≥2× headroom. `count(*)` and `sum(v)` are still checked against the roadmap; `sum(hash(v))`
cannot match either way, because DuckDB hashes INTEGER and BIGINT differently.

**Ragged row groups are not a hazard here.** Nothing in `zscore_scan.cpp` keys off `num_values % 8`
— we have no ragged guard — and our existing build-41 real-data runs used files built exactly this
way with exact counts. So Test 0 and Tests 1/3/4 take the **same** code path, which makes the
real-vs-synthetic comparison cleaner than the roadmap's. `min_group % 8` is still recorded per file.

**Test 5 is scaled down more than the others**: CARD 20,000 with spread 700,000, because the
roadmap's CARD=1.02e6 / S=9e6 needs Σx² ≈ 5e20 (55× over). Lowering the cardinality rather than the
spread is deliberate — skew needs S ≫ CARD or the uniform `+level` term dilutes the shape away. Its
IQR-specific power-of-two bin-width normalisation is dropped: a z-score fence does not quantise.

Test 5's expected count is **measured from each file**, not assumed: right-skew shrinks σ and pulls
the fence down, so at high skew the distribution's own tail crosses it. That is a real property of
a non-robust fence — and it is the substance of the joint "why offer both operators" figure the
roadmap asks for in its §7.6.

⛔ **Never Ctrl-C or Ctrl-Z an in-flight FPGA query.** Pinned pages and in-flight DMA survive the
process and Coyote cannot reset user logic between host processes; recovery has needed a reboot.
The harness uses SIGTERM first with a 60 s grace period, and SIGKILL only as a last resort.

## Sanity checklist before sending results

- [ ] Every point reported the exact expected flag count on **all 7** iterations (`flags_ok=1`).
- [ ] Test 1: `min_group % 8 == 0` and identical encoding on all 9 files; Σx² headroom ≥ 2× each.
- [ ] Test 4: the digest gate said `ALL GATES PASS` — the four files at each level provably hold
      the same numbers — and the dictionary's byte effect changed sign between the levels.
- [ ] Test 4: phase 2 is flat within each level (< 10% spread). If not, **stop** and re-check the
      generator's digest gate first.
- [ ] Test 3: phase 2 is flat across thread counts; the core plan is printed in the log.
- [ ] Test 3 at `threads=32` reproduces Test 1's 20M row within ~15%.
- [ ] No number quoted without its encoding and compression.
- [ ] The offload claim says "N× fewer CPU-seconds", never "zero host CPU".

## Deliverables

`size_sweep.csv`, `codec_sweep.csv`, `thread_sweep_{balanced,knee}.csv` (the roadmap's exact column
names), plus each generator's `manifest.csv`, the run logs including the printed gates, and the
node name and bitstream each test ran on.

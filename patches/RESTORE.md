# Restoring oasis after a cluster wipe

Captured 2026-08-15 from `hacc-build-02`, branch `global-zscore`.

Read this together with `../RECOVERY.md` (which repos exist and why).

---

## 1. Clone

```bash
git clone -b global-zscore <backup-remote-url> oasis
cd oasis
git submodule update --init --recursive     # takes a while: ~4.3 GB of submodule history
```

`~/celeris` is a **separate** working tree, but at capture time it was pinned identically
(`7f95831`), so the submodule copy inside oasis is sufficient for building. You only need the
standalone `~/celeris` clone if you want to work on celeris itself.

## 2. Verify the submodule chain BEFORE building

```bash
git submodule status --recursive | diff - <(tail -n +7 patches/SUBMODULE-PINS.txt)
```

Any difference here means you are about to build different hardware than the one the measurements
came from. Fix the drift before spending nine hours on a synthesis.

The chain is four deep: `oasis → parcore → libstf → coyote`. `coyote` points at third-party
`fpgasystems/Coyote`, which we cannot push to, so its local modification lives as a patch (below).

## 3. Apply the submodule patches

### `coyote-place-directive.patch`

```bash
cd parcore/libstf/coyote
git apply ../../../patches/coyote-place-directive.patch
git diff --stat
# expected:
#  scripts/dyn/flow_dyn_ultrascale_plus.tcl.in | 4 ++--
#  1 file changed, 2 insertions(+), 2 deletions(-)
cd -
```

**What it does.** In both `place_design` call sites of
`scripts/dyn/flow_dyn_ultrascale_plus.tcl.in`, it replaces Vivado's
`-directive Auto_1` with `-directive AltSpreadLogic_high`.

**Why it matters.** `Auto_1` lets Vivado's ML placer pick a strategy per run. Pinning
`AltSpreadLogic_high` spreads logic more aggressively, which is what timing closure on this design
depends on. Without the patch a rebuild silently uses a *different* placer strategy, and you can
re-measure a wrong answer after an overnight build without any error telling you why.

> ⚠️ **Unverified figure.** `GITHUB_BACKUP_GUIDE.md` attributes **+0.338 ns of WNS** to a
> placer-directive override. That guide describes an *environment-variable* override; the patch we
> actually carry is a **hardcoded** directive change. The two are not the same edit, and the
> +0.338 ns number has **not** been re-measured for this patch. Treat it as "this matters, magnitude
> unconfirmed", not as a citable result. Nothing in this repo documents when or why the directive was
> changed — if you remember, write it down here.

## 4. What is NOT in git, and what it costs to rebuild

| missing | size | how to get it back | cost |
|---|---|---|---|
| `hardware/build-NN/` (all 29 builds, incl. bitstreams) | ~40–70 MB per `.bit` | re-synthesise from the pinned RTL | overnight per build |
| `~/bench/*.parquet` (TPC-H sf17, NYC taxi) | ~1.0 GB | `benchmark/gen_tpch.py`, `benchmark/get_taxi.py` | minutes |
| `~/bench/microbench/**` (size/codec/skew/real sweeps) | ~2.4 GB | `benchmark/gen_size_sweep.sh`, `gen_codec_sweep.sh`, `gen_skew_sweep.sh`, `gen_real.sh` | tens of minutes |
| `~/celeris/benchmark/*.csv` | 4.1 GB | `benchmark/generate.py` in the celeris repo | minutes |
| `~/opt`, `~/opt-prof` (install prefixes) | — | rebuild libstf + oasis sw lib, see `oasis-build-and-run` notes | one cmake each |
| `~/duckdb-bench41`, `~/duckdb-global-fix` (patched duckdb binaries) | — | rebuild the extension against the matching branch | one build |
| `venv/` | 15 MB | `python -m venv` + requirements | minutes |

**The build-NN directories are the expensive loss.** If a specific bitstream must survive, add it via
Git LFS — see §5 of `GITHUB_BACKUP_GUIDE.md`. As of this capture **no bitstream is in LFS**; the
known-good one is `hardware/build-41/bitstreams/cyt_top.bit` (3 × decoder + z-score + egress profiler
+ fixed aggregate PCIe counter, global two-phase).

## 5. The .gitignore trap — do not re-lose these

`.gitignore` patterns without a slash match at **any depth** and match **files as well as
directories**. In this repo `build*` and `*.log` between them hide:

- `hardware/build-NN/BUILD_INFO.txt` — the only record of which build is which operator/decoder
- `benchmark/study*.log` — raw runs behind reported numbers
- `benchmark/results_*.csv`, `benchmark/profiles/*.csv` — the measurement data itself (also ignored
  explicitly by `benchmark/.gitignore`)

All of the above were **force-added** (`git add -f`) at capture time. If you add a new results or
evidence directory, re-run the audit:

```bash
git ls-files --others --ignored --exclude-standard \
  | grep -Ev '(^|/)(build|\.Xil|node_modules|__pycache__)/' \
  | grep -Ev '\.(o|d|so|a|jou|str|pb|dcp|bit)$' | sort
```

and verify what actually landed with `git ls-files <dir>` — **not** with `git status`.

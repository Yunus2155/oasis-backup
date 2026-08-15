# 🚨 READ THIS FIRST AFTER A CLUSTER WIPE

Captured **2026-08-15** on `hacc-build-02`, branch `global-zscore`.
Home (`/home/yukoek`) is NFS and **will** be wiped. This file is how you get working again in 20
minutes instead of losing a paper's worth of evidence.

---

## The two repos, and why you need both

| repo | backup remote | what is in it | needed for |
|---|---|---|---|
| `oasis` | `backup` → your private `oasis-backup` | DuckDB extension, host C++, z-score/covariance work, **all benchmark scripts, results and raw logs**, figures, `patches/` | everything |
| `celeris` | `backup` → your private `celeris-backup` | the RTL library, `LEARNING_PATH.md` | only if you work on celeris itself |

**At capture time the submodule pin matched the sibling tree** — oasis pins celeris at `7f95831`
and `~/celeris` HEAD was `7f95831`. So `oasis` alone is enough to rebuild the hardware.
(`GITHUB_BACKUP_GUIDE.md` warns that these usually drift; here they did not. **Re-check** before
relying on it: `git submodule status | grep celeris` vs `cd ~/celeris && git log --oneline -1`.)

## Get back to work

```bash
git clone -b global-zscore <your-oasis-backup-url> oasis
cd oasis
git submodule update --init --recursive     # ~4.3 GB, takes a while
# git lfs pull                              # only if a bitstream was later added to LFS
```

Then follow **`patches/RESTORE.md`**: verify the submodule pins against
`patches/SUBMODULE-PINS.txt`, and apply `patches/coyote-place-directive.patch` (the Vivado placer
directive — without it a rebuild silently uses a different placement strategy).

## `origin` is read-only — do not confuse the remotes

`origin` points at `celeris-labs/{oasis,celeris}` and you have **read-only** access
(verified 2026-08-15: `git push --dry-run origin HEAD` → `Permission denied to Yunus2155`).
`backup` is your own private repo and is the one that accepts pushes.

We deliberately did **not** fork publicly: a public fork would publish unpublished paper material,
and private → public is reversible while public → private is not.

When write access to `celeris-labs` arrives, `origin` was never touched, so it is one command:
`git push origin $(git branch --show-current)`.

## What is NOT backed up

Bitstreams (`hardware/build-NN/`, 29 builds), all datasets (`~/bench`, ~3.4 GB), the install
prefixes (`~/opt`, `~/opt-prof`) and the patched duckdb binaries. Rebuild costs are tabulated in
`patches/RESTORE.md` §4. The only expensive one is re-synthesis (overnight per build); everything
else is minutes. The known-good bitstream is **build-41**.

## ⚠️ The trap that makes `git status` lie

`git add <dir>` skips `.gitignore`d contents **silently** — no warning, exit code 0, clean tree
afterwards. In this repo `build*` and `*.log` hide `hardware/build-NN/BUILD_INFO.txt`,
`benchmark/study*.log`, `benchmark/results_*.csv` and `benchmark/profiles/`. All were force-added at
capture time.

**`git status` describes the working tree. `git ls-files` describes the repo.** Only the second one
answers "is my work saved?" Re-run the audit in `patches/RESTORE.md` §5 whenever you add a new
results or evidence directory.

## Session discipline

```bash
git add <explicit paths>          # never 'git add -A' in ~/celeris: benchmark/ is 4.1 GB
git commit -m "..."
git push backup $(git branch --show-current)
```

---

**Recovery verification status:** ✅ **VERIFIED 2026-08-15** on `alveo-u55c-09`. A fresh clone into
`/tmp/restore-test` (`GITHUB_BACKUP_GUIDE.md` §6) reproduced everything:

| check | result |
|---|---|
| `git submodule update --init --recursive` | full 4-deep chain checked out |
| `git lfs pull` → build-41 bitstream | **60 MB, md5 `a65124a5af1cb789207e704236796576`** — identical to the original (a bare LFS pointer would have been ~130 bytes) |
| `diff` of `git ls-files` vs the working repo | empty — same file list |
| `git apply --check patches/coyote-place-directive.patch` | applies cleanly |

Re-run this test after any change to LFS tracking or the submodule pins.

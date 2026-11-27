# Cycle VII benchmark tools

`bench.sh` runs one fixed-window benchmark on the Radeon 780M laptop, in one of two start settings: `bench-saved.sh` (the benchmark save in `<runs>/bench-save`, made with `capture-bench-save.ps1`) or `bench-opening.sh` (no save, the game's opening). See `docs/research/cycle-vii/README.md` for the protocol and the results.

The scripts expect `<runs>` = `~/victory-runs/cycle-vii` (override with `BENCH_RUNS`) holding `tools/`, `data/` and `bench-save/`.

Three Python helpers they call are kept outside the repository, in `<runs>/tools/`, because the asset policy's allowlist has no `.py` entry:
- `parse_run.py`: splits victory.log into overlay.csv and host.csv;
- `bench_window.py`: the 600 s window analysis;
- `audit_live.py`: the live auditor that run-test.ps1 starts.

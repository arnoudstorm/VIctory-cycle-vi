# Cycle VII audit (Radeon 780M laptop)

2026-11-27. Ryzen 7 8840HS, Radeon 780M, 16 GB, Windows 11 Home. Every benchmark run used the exe built from `0e6e5eab` (`victory-phase0-0e6e5eab-crtstatic.exe`, SHA-256 `783E2898756FEDC2401A3412DC4DAE2B2E6492F8FB184446CBC120822549A6C3`), the laptop launcher with `-Safe` (relay 0, "low" profile, ray tracing off) and warm caches. Windows TDR and the memory protections stayed on throughout. No game files, assets, saves, shader caches or screenshots are in the repository: only counts, hashes, timings and the tools that produced them.

| Document | What it covers |
|---|---|
| [shader-upscaling-framegen-audit.md](shader-upscaling-framegen-audit.md) | Shader translation pipeline and its coverage (25,700 of 25,758 programs to DXIL), cold vs warm compiles, what upscaling is actually used (VIctory's own bilinear pass, no frame generation), FSR4 ACO/NewBE, and a vendor technology matrix |
| [T7-T8-audit.md](T7-T8-audit.md) | T7 (warm rerun, no save) and T8 (fixed save, GPU device loss), and why the benchmark changed to protocol v2 |
| [data/](data) | `bench_window.py` output for T3–T8 and the full-translation measurement |
| [../../../tools/bench](../../../tools/bench) | The benchmark and audit tools |

## Findings

- **The T5c crash** (access violation in the title's script VM, reading through a null pointer) is the known #1118 Prestream stop. The title's own crash log shows `SRL "Prestream Metadata"` with game physical memory at 1,288 of 1,339 MB and 0 of 203 MB unused. The watchdog hook is off, so it shows up as a script null and not as a watchdog stop. The input devices are not supported as its cause (see below).
- **Frame rate is CPU- and memory-bound.** In the world: ~1.3 fps, with the GPU idle ~60 % of each frame while VIctory prepares and copies title memory. Freezes of 2 s or more follow low free RAM and paging, not shader compiles (T7: 29 of 35 under 500 MB free; 1 with a pipeline build).
- **Shader compiles are no longer what stalls a warm run**: 5 pipelines built in T6's world window. Cold vs warm driver cache for the 3,044 known pipelines: 1,278 s vs 426 s.
- **Frame generation cannot help at this rate.** At ~1.3 rendered fps, every vendor's guidance (~55–60 fps before generation) is far off. Rendered and presented fps are the same thing in every run: nothing generates frames.
- **T8 lost the GPU device** (hung, 0x887A0006) 132 s into the world, under the heaviest memory pressure of any run. There was no TDR event in Windows. The cause is not confirmed.

## Input-device lifecycle (requested investigation)

`crates/victory-hle/src/modules/gameinput_lifecycle_tests.rs`: synthetic tests, independent of the title, over a fake host.

| Test | Result |
|---|---|
| Repeated connections and disconnections | pass |
| Switching between the keyboard's stand-in pad and host pads | pass |
| A second input session while the first one's readings and callbacks are alive | pass |
| Stale references and failed calls always clear the out pointer | pass |
| Readings held across session changes are freed by their last release | pass |
| Device changes while other threads read and hold many readings ("memory pressure": many held readings and concurrent polling, since a failed allocation aborts a Rust process) | pass |
| Blocking enumeration reports every device before registration returns | **fails 10 of 10**: a confirmed deviation from the documented contract. Kept as `#[ignore]` with the reason: waiting for the events could deadlock when the title registers while holding a lock its callback takes. Not fixed. |

`cargo test -p victory-hle --lib`: 121 passed, 0 failed, 3 ignored.

**Conclusion:** the suspected lifecycle defect behind the T5c crash was **not reproduced**. The one confirmed deviation (blocking enumeration) is on a path the T5c run did not take: its registrations all came at start-up. A second observation is **not verified**: `xuser`'s `find_for_device` returns "user not found" without writing its out pointer.

## Benchmark protocol v2

`tools/bench/bench.sh` runs one fixed-window benchmark. There are two start settings:

- `bench-saved.sh <name> <exe> [switches] [K=V…]`: starts from the benchmark save in `<runs>/bench-save`, so every run starts at the same spot. It is the setting for comparing frame rates once a save made in free gameplay exists. Make one with `capture-bench-save.ps1` after playing to a quiet spot.
- `bench-opening.sh …`: no save; the game plays its opening. Cutscenes advance per frame, so the window's content depends on the build's speed. Use it for start-up and loading, not for comparing frame rates.

Both only ever move story saves aside (`save-backups\aside-bench-<name>-<time>`), never delete them. Both never press a key in the world, and stop the game 615 s after the world starts. `bench_window.py` reports:

- a per-minute timeline;
- a content-stability check (median draws per minute, variation ≤ 0.25);
- each freeze with the free RAM, paging and pipeline builds at that moment.

| Run | Start | World fps | Freezes | Content stable | End |
|---|---|---|---|---|---|
| T3 | opening | 1.32 | 23 / 56 s | — | — |
| T4 | opening | 1.35 | 11 / 27 s | — | window closed |
| T5c | opening | 1.26 | 19 / 57 s | — | #1118 crash |
| T6 | 07:24 autosave | 1.34 | 9 / 24 s | yes (0.14) | window closed |
| T7 | opening | 1.02 | 35 / 92 s | no (0.31) | stopped by hand |
| T8 | 07:24 autosave | 0.86 (131 s only) | 15 / 41 s | no (0.37) | GPU device removed |

The 07:24 autosave loads into a cutscene, which is why T6 and T8 differ. Frame rates are comparable only between runs from the same save made in free gameplay. That save is the next step.

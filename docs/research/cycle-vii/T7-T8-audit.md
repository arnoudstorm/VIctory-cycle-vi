# T7 audit: warm rerun of T6's exe, no save

2026-11-27 14:59:38–15:13:20. Exe `victory-phase0-0e6e5eab-crtstatic.exe`, SHA-256 `783E2898…49A6C3` (same as T6). Launcher `-Safe` (relay 0, "low" profile), warm driver and shader caches. The autosave SARC0015 was moved aside first (`save-backups\aside-cycle-vii-bench-20261127-145928`), so the game started its opening. Stopped by hand at 15:13:09 on the user's request, after the 600 s window was complete (598.2 s).

Data: `data/T7-bench-warm-rerun/` (victory.log, overlay/host/system/audit csv, 14 screenshots, `bench.json`); `data/bench-T6-T7.json` (the new per-minute and per-freeze analysis).

## Result

| | T3 | T4 | T5c | T6 (save) | **T7** |
|---|---|---|---|---|---|
| To account picker / world (s) | 36.9 / 144.4 | 96.6 / 198.7 | 12.3 / 66.9 | 71.7 / 117.7 | **13.7 / 91.3** |
| Window (s) | 598.6 | 563.8 | 386.1 | 542.4 | **598.2 (complete)** |
| FPS, world only | 1.32 | 1.35 | 1.26 | 1.34 | **1.02** |
| Frame ms p50 / p90 / p99 | 602 / 1197 / 2058 | 688 / 1054 / 2319 | 619 / 1175 / 1727 | 711 / 956 / 1369 | **1014 / 1578 / 2532** |
| Freezes ≥2 s (count / total / longest) | 23 / 56.0 / 3.7 | 11 / 27.2 / 3.8 | 19 / 56.7 / 5.6 | 9 / 23.8 / 4.1 | **35 / 92.3 / 5.3** |
| Prep / copies / GPU wait (ms per frame) | 273 / 171 / 296 | 285 / 152 / 381 | 340 / 243 / 277 | 276 / 155 / 370 | **497 / 355 / 472** |
| Draws per frame (mean) | 1,722 | 4,489 | 2,836 | 4,186 | **2,554** |
| Pipelines built in window | 52 | 0 | 4 | 5 | **35** |
| RAM growth (MB/min) | 39 | 123 | 263 | 95 | **181** |
| Free RAM, minimum (MB) | 59 | 84 | 170 | 86 | **71** |
| Paging (pages/s, mean) | — | 8,527 | 40,145 | 7,593 | **23,135** |
| VRAM over budget (s) | 342 | 519 | 187 | 393 | **502** |
| How it ended | — | window closed | #1118 Prestream crash | window closed | **stopped by hand** |

No crash, no OOM, no skipped command list, no device loss, and **0 Windows events** (driver resets, application errors, hangs) in the run's time span. One 16 s stall at 89 s (the loading into the opening).

## Why T7 is slower than T6: different content, then paging

1. **The window measured different content.** With no save, the game plays its opening: loading-screen artwork, a white transition, then the intro cutscenes (screenshots 15:06, 15:09, 15:12). As far as the screenshots show, T7 never reached free gameplay. Draws per frame, minute by minute, ranged from 1,392 to 3,695 (variation 0.31). T6 started from the autosave in the world, at 4,214–6,174 (variation 0.14). The "≥1000 draws = world" rule counts loading art and cutscenes as world. **T6 and T7 are not comparable, and neither are T3/T4/T5c with each other in content** (each reached a different point of the opening).
2. **Paging made it worse as the run went on.** Minutes 8–9: 34,000–45,000 pages/s, and prep plus copies rose from ~500 to ~1,800 ms per frame. The CPU's snapshots of title memory are where paging hurts.
3. **Freezes follow memory, not compiles.** 29 of 35 freezes happened with under 500 MB free RAM. Only 1 coincided with a pipeline build. T6: 8 of 9 under 500 MB, 1 with a build.

## What changed in the benchmark for the next runs (protocol v2)

Tools only; no game, VIctory or launcher setting changed.

- **A fixed starting point.** `bench.sh` puts the benchmark save in place before every run: `bench-save/`, a copy of the 07:24 autosave that T6 loaded. Any other SARC save is moved aside (kept, never deleted). Every run then starts in the same spot of the world and skips the opening. `BENCH_NOSAVE=1` keeps the old protocol.
- **Never a key in the world.** One Enter only if the account picker shows. In T6, an Enter press opened the pause menu (minutes 2–4 of its window); that can't happen now.
- **Automatic stop** 615 s after the world starts (the 600 s window plus a margin), recorded in `STOPPED_BY_BENCH.txt`. Runs stay the same length and need no hand stop.
- **New analysis fields** in `bench_window.py`:
  - `minutes`: per minute, fps, median draws, prep/copies/GPU, minimum free RAM and paging;
  - `content`: draws variation across minutes, `stable` when ≤0.25; a window that isn't stable is not comparable;
  - `freeze_list`: each freeze with the paging rate, free RAM and pipelines built at that moment, plus counts of freezes under 500 MB and freezes with builds;
  - `frames_in_window`, `ram_available_mb_before`, `start` (which save was used).

## Limits

- Free RAM before the run was 8,507 MB (T6: 7,230), so a higher start does not explain T7's paging. The game's own content does.
- The screenshots are one per minute. "Never reached gameplay" is an inference from them and the draw counts.

# T8: first run on protocol v2 (warm, fixed save): GPU device loss

2026-11-27 15:15:54–15:20:24. Same exe and launcher as T6/T7; the benchmark save was in place, and the autosave T7 had made was moved aside (`save-backups\aside-bench-T8-bench-v2-warm-*`). No key was pressed: the picker never showed.

- **Ended at 260 s** (132 s into the world) with **host GPU device removed**. The removal reason is 0x887A0006 (device hung). Breadcrumbs gave nothing (0x887A0004), so the command that hung is not named. The submitting thread had waited 29.3 ms for a submission of 19 lists. 13,687 submissions started and 13,687 finished. The pipeline library had no call running.
- **Windows logged no TDR event** (4101/141) in the run's time span, and there is no new LiveKernelReport. No OOM line and no skipped list.
- **Memory pressure was the highest of any run**: free RAM down to 131 MB, paging averaging 33,900 pages/s, RAM growth 721 MB/min while loading in, and prep plus copies 707 + 541 ms per frame. The earlier device losses on this laptop (gameplay tests 3 and 5 on 2026-11-25, `docs/updates/gameplay-tests-2026-11-25.md`) also came under memory pressure. **This is a hypothesis, not a confirmed cause.**
- No automatic restart (per the Cycle VII rules). Result: window 131.7 s (incomplete), 0.86 fps, not comparable.

## What T8 shows about the fixed save

The 07:24 autosave does **not** start in free gameplay. It loads into a cutscene (screens at 15:19, and T6's at 14:30), and the game reaches playable gameplay a few minutes later (T6 at 14:36: the room scene with the TALK prompt). The cutscene advances by frames, so at ~1 fps the moment gameplay starts depends on the build's speed. That makes the first minutes of every window build-dependent. T6's window was stable only because its cutscene part was short. T8's content variation is 0.37 (not stable).

A stable window needs a save made **in free gameplay**, standing somewhere quiet, with no cutscene pending. That needs someone to play to that point; the benchmark tool can't create it.

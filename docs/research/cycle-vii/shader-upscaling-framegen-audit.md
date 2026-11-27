# Cycle VII — Shader, upscaling and frame generation audit

2026-11-27, Radeon 780M laptop (Ryzen 7 8840HS, 16 GB, Windows 11 Home, driver 32.0.13074.2001).
Source: `cycle-vii/input-lifecycle` worktree at `0e6e5eab` (tag `checkpoint/cycle-vii-input-lifecycle-start`).
Executable: `victory-phase0-0e6e5eab-crtstatic.exe`, SHA-256 `783E2898756FEDC2401A3412DC4DAE2B2E6492F8FB184446CBC120822549A6C3`.
Audit only: no code or benchmark configuration was changed for it. Nothing from the game is in this report beyond counts, hashes and offsets.

Evidence levels used below: **Measured** (a number from a run or tool on this machine), **Code** (read from the source at `0e6e5eab`), **Doc** (official vendor documentation, links at the end), **Not measured** (said plainly where no measurement exists).

## 1. Shader architecture

```
 console shader (DXBC container)
   └─ DXIL part ─ XDAT index ─ XBCH (zlib) ─ FSSM records: native GFX10 machine code per hardware stage
        │                                        (the LLVM bitcode beside it is NOT used: it may hold console-only intrinsics)
        ▼
 victory-shader  (CPU, at first use or ahead of time)
   gfx10 decode ─► ir::build (SSA) ─► structure (EXEC/lane masks → per-lane branches)
     ─► resource (descriptor & scalar-address tracing → root parameters, SM 6.6 heap indexing)
     ─► io (vertex/pixel interpolants, exports) ─► emit: own DXIL bitcode writer, SM 6.6 container
        │   (dxil.dll IDxcValidator signs the container in place)
        ▼
 translated-shader cache  %LOCALAPPDATA%\victory\cache\shaders   (key: container bytes + translator fingerprint)
        ▼
 victory-gpu pipeline library  (ID3D12PipelineLibrary, mapped file, …\cache\pipelines; "start early" list of title pipelines)
        ▼
 D3D12 CreatePipelineState ─► AMD driver DXIL compiler ─► GPU ISA, kept in the driver's per-executable cache (%LOCALAPPDATA%\AMD\DxcCache)
```

| Question | Answer | Evidence |
|---|---|---|
| Original format | DXBC container; the program VIctory reads is the embedded native **GFX10 (RDNA2) machine code** (FSSM records), not the bitcode | Code (`victory-shader/src/lib.rs`, `native.rs`) |
| Host format | **DXIL, Shader Model 6.6**, emitted by VIctory's own bitcode writer; resources via `ResourceDescriptorHeap[]` | Code (`emit/mod.rs`) |
| Hardware needs | D3D12 SM 6.6 with directly indexed heaps; compute shaders that use cross-lane operations declare the console's wave size (`WaveSize`), so the host must support that wave width (the 780M does: RDNA3 runs wave32 and wave64) | Code |
| DXIL involvement | the only host shader format | Code |
| ACO involvement | **none in VIctory.** "ACO" appears only in the title's own FSR4 log line (`FFX FSR4 ACO: DeserializeComputePipelineStateX FAILED hr=0x80004001 … falling back to NewBE`). That call is device slot 0x218, which VIctory does not implement (E_NOTIMPL). Seen 29 times in T6 as "a precompiled-pipeline method that is not implemented" | Measured (logs), Code |
| NewBE involvement | **none in VIctory.** The title's fallback programs are `ACCC`/`FSPX` containers holding raw GFX10 code and no DXIL part; the translator does not read them | Measured (`docs/updates/fsr4-black-output.md`, translate pass below) |
| Optimization passes | VIctory's passes are structural (EXEC removal, guard placement only where a lane can arrive with its bit clear, waterfall-loop collapsing to non-uniform heap indexing, constant tracing) plus `VICTORY_SHADER_LOOP_LIMIT=64` (loops stop sooner) and `VICTORY_F16_NEAREST=1`. Code optimization proper is left to the driver's DXIL compiler | Code, launcher |
| Runtime vs ahead of time | Both. Translation: at first use or offline (`victory prewarm-shaders`). Driver compile: at first use, or ahead with `victory warm --used --again` (the title's recorded pipelines). At start a run begins the "start early" list (3,140 pipelines in T6) on worker threads | Code, Measured |

### Where each component comes from

| Component | Origin | Evidence |
|---|---|---|
| Shader translator (`victory-shader`), translated-shader cache, pipeline library | upstream VIctory (Marvisak), first commits 2026-11-23; 92 later commits in this tree | git log |
| `victory warm` (driver pipelines ahead of time) | Belobug `a-publier` `b7ab9c49`, ported 2026-11-25 | `docs/research/CYCLE_VI_CROSS_FORK.md`, git log |
| `victory prewarm-shaders` (translations ahead of time), compile gate on free RAM | this fork (`2e6645ec`) | same |
| `VICTORY_SHADER_LOOP_LIMIT` | in both this fork and Belobug's | same |
| Built-in upscaler (`fidelityfx.rs`, `external.rs`) | this fork (arnoudstorm, 2026-11-25); structure layouts follow upstream `0b35b7f`, whose path hands the call to AMD's PC FidelityFX DLL (not ported: needs AMD's PC SDK) | git log, `fsr4-black-output.md` |
| Ambient stand-in for ray-traced indirect light | ported from Belobug `06031237` | `CYCLE_VI_CROSS_FORK.md` |

## 2. Shader and pipeline coverage

### Every shader the game ships, through the translator (Measured)

`victory translate --jobs 4 C:\Users\Arnou\Downloads\build`, with the launcher's `VICTORY_SHADER_LOOP_LIMIT=64`, `VICTORY_F16_NEAREST=1`; no validation, no pipelines (so neither cache was touched). Raw output: `data/shader-audit/translate.out`.

| | Count |
|---|---|
| Containers found | 26,599 (614 duplicates skipped) |
| Programs | 26,148, all decoded and structured (40.6 M IR instructions) |
| Resources fully traced | 25,953 of 26,148 (195 with an address in a register that is no root parameter) |
| Vertex/pixel programs → DXIL | 14,211 of 14,259 |
| Compute programs → DXIL | 2,727 of 2,734 |
| Mesh programs → DXIL | 8,762 of 8,765 |
| **All host-stage programs → DXIL** | **25,700 of 25,758 (99.77 %)** |
| Emit failures | 58: 40 descriptor chosen by control flow, 10 hardware SGPR input, 5 descriptor read only as data, 2 lane mask read as data, 1 opaque lane mask |
| Containers with no DXIL part | 29, all in the title's FSR4 upscaler DLL (the `ACCC`/NewBE programs) |
| Programs of other hardware stages | 390 (e.g. geometry-stage programs); the tally does not emit them on their own and does not say why: **not investigated** |

Cost of translating everything (Measured): **399.6 s wall time on 4 workers, peak private memory 1,865 MB**; the structuriser's lane-mask tables reached 61.5 MiB for the largest program (708 programs needed 32 MiB or more).

### In a run (T6, warm caches, Measured)

| | Value |
|---|---|
| Title pipelines known (recorded catalogue) | 88,545 |
| Made ahead of time by `warm --used` | 3,044 (0 without a host pipeline, 0 crashed a worker) |
| Started early at launch | 3,140 |
| Built during the 9-minute world window | 5 |
| Driver compiles held back by the memory gate | 0 |
| Shader containers / translations held in memory | 19,098 (189 MB) / 3,340 (190 MB) |
| Shaders that failed to translate in the run | 1 compute (`926c46bab3b86bd6`, lane mask read as data) |
| Draws dropped for lack of a pipeline, in the world | ~288 of ~6,170 per frame (4.7 %): **all** are stages of the title's ray-tracing structure builder, which is off by design (`VICTORY_BVH_BUILDER` unset); a few more at start while pipelines were still being made |

### Compilation time, cold vs warm driver cache (Measured, `warm --used --again`, 3,044 pipelines, 4 processes)

| Driver cache | Wall time | Per pipeline: median | p90 | p99 | slowest | sum of all |
|---|---|---|---|---|---|---|
| Cold (new executable) | 1,278 s | 216.6 ms | 6,524 ms | 10,313 ms | 167,133 ms | 4,668 s |
| Warm (same executable) | 426 s | 18.7 ms | 807 ms | 8,494 ms | 13,558 ms | 1,245 s |

The driver's cache is per executable: every rebuilt or renamed exe starts cold for the driver even though VIctory's translations are still cached.

### Caches on disk (Measured)

| Cache | Size |
|---|---|
| VIctory translated shaders | 9,067 MB in 168,488 files (entries of every translator version accumulate) |
| VIctory pipeline library + start list | 242 MB |
| AMD DxcCache (all executables) | 11,891 MB in 342 files |
| VIctory mapped title images | 118 MB |

## 3. Compilation bottlenecks

1. **Cold driver compiles dominate first runs**: 1,278 s for the 3,044 known pipelines, with a long tail (p99 10.3 s, one pipeline 167 s). This is why every new executable must be warmed before a benchmark. (Measured)
2. **Warm runs no longer stall on compiles**: 5 pipelines built and 0 compile hold-backs in T6's world. The freezes left in T6 (9 of 2 s or more, longest 4.1 s) do not coincide with pipeline creation; their cause is outside this audit (memory pressure is the main suspect, see the 10-minute benchmark audit). (Measured)
3. **Translation is not the bottleneck at run time** (cached), but a full translation costs ~6.7 min and 1.9 GB peak, so translator changes invalidate a large, slow-to-rebuild cache. (Measured)
4. **Cache retention**: 21 GB of shader caches on a laptop with a nearly full RAM budget; old translator versions and old executables' driver caches are never removed. (Measured)

## 4. Upscaling and frame generation: what is actually used

| Technology | State in this build | Evidence |
|---|---|---|
| FSR 1 / 2 / 3 / 3.1 | **not present** | Code: no AMD FSR code or DLL is loaded |
| FSR 4 (the title's own, Xbox build) | **requested by the title but not run**: with `VICTORY_FFX_BUILTIN=1` (launcher default) VIctory answers `amd_fidelityfx_loader_xbox.dll`'s five calls itself, so the title's FSR4 DLL and its 28 passes are never made. Without the switch those passes are dropped (no DXIL part) and the image goes black | Code, Measured (T6 log: "FidelityFX (ours, VICTORY_FFX_BUILTIN): upscaler context made") |
| **Upscaling actually used** | VIctory's own compute pass: **spatial, bilinear**, render 1280×720 → output 1920×1080 (1.5×), window presented at 3840×2160 | Measured (T6 log), Code (`external.rs`) |
| Bicubic | implemented (Catmull-Rom from 9 bilinear taps, sharpen 0.25, clamped to the 4 nearest texels); **off** on the "low" profile (`Filter = 'bilinear'`), on for "balanced"/"quality" | Code, launcher |
| Temporal (motion vectors + history) | implemented (`VICTORY_FFX_TEMPORAL`: reprojection by the title's motion vectors, YCoCg neighbourhood clip, tone-mapped blend, two R16G16B16A16 history textures at output size); **off** (unset) | Code |
| Motion vectors | **received** from the title every call (1280×720, scale 1.0) but **unused** while temporal is off; no exposure, reactive or transparency mask is passed; jitter 0 | Measured (T6 log) |
| Native rendering | the title renders at 1280×720 internally (its own choice); there is no native-1080p path | Measured |
| Frame generation / interpolation | **none, anywhere**. The title never asked FidelityFX for any effect but the upscaler (no "another effect was refused" line in T6), VIctory has no generation code, and the driver's AFMF is not in use | Measured, Code |
| Ray tracing | off: the title's BVH-builder stages are dropped (~288 draws/frame); `VICTORY_AMBIENT=0.6` is the stand-in fill light | Measured, Code |
| Hardware vs software | all of it is ordinary D3D12 compute on the GPU; no ML, no matrix units | Code |

**Rendered vs presented FPS:** with no frame generation they are the same thing. One title frame = one present (the T6 log's `frame presented` counter advances once per title frame). T6's world ran at **1.34 rendered fps** (time-weighted, world only). No figure in Cycle VII counts generated frames.

### The FSR4 ACO / NewBE failure, re-checked independently

The translate pass above is an independent check (the game's files, not a run): the only containers without a DXIL part are the 29 in `amd_fidelityfx_upscaler_xbox.dll` (e.g. `#b5552512a4220d1b`). That matches the earlier run evidence (20 hashes, 28 passes). So the failure is **confirmed and fully contained**: those programs are console GFX10 code in a format the translator does not read, and slot 0x218 (the "ACO" precompiled path) is unimplemented. Neither matters at present because the built-in upscaler replaces the whole library. A synthetic GPU workload for the FSR4 passes was **not built**: the programs cannot be translated, so there is nothing to run.

## 5. Technology comparison (Doc: vendor pages, checked 2026-11-27)

| Technology | Hardware (vendor) | Radeon 780M (RDNA3 iGPU) | Memory | Overhead | Practical min. input fps | Quality | Latency | Integration here | Licence |
|---|---|---|---|---|---|---|---|---|---|
| Native + bilinear (current) | any | **yes, active** | none extra | one small compute pass (**not measured in isolation**) | n/a | soft, no reconstruction | none added | done | ours (repo licence) |
| Native + bicubic/sharpen (in tree) | any | yes (profile switch) | none extra | 9 taps/pixel (**not measured**) | n/a | sharper, still spatial | none added | done; profile change only | ours |
| VIctory temporal (in tree) | any | yes (switch) | 2 × 1920×1080 RGBA16F ≈ 33 MB | one pass (**not measured**) | needs coherent frame-to-frame motion: at ~1.3 fps successive frames are far apart, so ghosting/rejection is likely | can resolve dithered effects | none added | done; untested at this frame rate | ours |
| AMD FSR 3.1 upscaling | AMD, NVIDIA, Intel (DX12/Vulkan) | yes | a few hundred MB at 1080p (vendor-dependent; **not measured**) | GPU compute | n/a for upscaling | good temporal reconstruction | none added | medium: needs AMD's **PC** FidelityFX DLLs (upstream `0b35b7f` path, not ported) | MIT (FidelityFX SDK) |
| AMD FSR 3.1 frame generation | same | runs | + interpolation buffers | GPU compute + frame pacing | AMD: **~60 fps before FG** recommended | interpolation artefacts at low fps | adds at least one frame | high (swap chain proxy) | MIT |
| AMD FSR 4 upscaling (ML) | RX 9000; RX 7000/6000 now listed for "FSR Upscaling 4.1" in AMD's SDK page | **not listed** for integrated 780M; unverified | ML model + buffers | ML inference | n/a | best of AMD's | none added | high | AMD SDK terms |
| AMD FSR 4 / Redstone frame generation (ML) | **RX 9000 (RDNA4) only** | **no** | — | — | — | — | — | — | — |
| AMD Fluid Motion Frames 2 (driver) | RX 6000/7000 and Radeon 700M/800M iGPUs | **yes** (driver feature, no integration) | driver-managed | GPU compute in the driver | AMD guidance (secondary sources): **55 fps at 1080p, 70 fps at 1440p+** | no game data (no motion vectors, UI not separated) | adds at least one frame | none (driver toggle) | driver feature |
| NVIDIA DLSS Super Resolution | GeForce RTX (Tensor cores) | **no** | — | — | — | — | — | — | NVIDIA RTX SDKs licence (proprietary) |
| NVIDIA DLSS Frame Generation | RTX 40/50 | **no** | — | — | — | — | — | — | same |
| NVIDIA Multi Frame Generation | **RTX 50 only** | **no** | — | — | — | — | — | — | same |
| Intel XeSS Super Resolution | any SM 6.4 GPU (DP4a path); XMX path on Arc | yes (DP4a path) | model + buffers | ML inference on shader cores (heavier without XMX) | n/a | good | none added | high | Intel Simplified Software Licence (binary redistribution, no modification) |
| Intel XeSS Frame Generation (XeSS 2.1) | Arc (XMX); SM 6.4 GPUs from XeSS 2.1 per release coverage (Intel's whitepaper still says Arc) | possibly; **unverified** | + buffers | ML inference | not stated by Intel in what was found; same physics as the rest | — | adds at least one frame (XeLL only with FG on non-Intel) | high | ISSL |

## 6. Measured overhead and realistic estimates

| Item | Status |
|---|---|
| Shader translation of the whole game | **Measured**: 399.6 s, 4 workers, 1,865 MB peak |
| Driver pipeline compile, cold vs warm | **Measured**: 1,278 s vs 426 s for 3,044 pipelines |
| Compiles during 9 min of world (warm) | **Measured**: 5 pipelines, 0 hold-backs |
| Upscaling pass GPU time | **Not measured**: no isolated GPU timing harness exists in the tree, and writing one would be new code outside this audit-only brief |
| Frame generation overhead / latency | **Not measured**: nothing in the build generates frames |

Estimates (not measurements), with confidence:

| Question | Estimate | Confidence | Why |
|---|---|---|---|
| Would bicubic instead of bilinear change fps? | no visible change (<1 %) | high | the GPU is idle ~60 % of each frame waiting for VIctory's CPU-side preparation (T6: "nothing of ours queued" ~420 of ~440 ms) |
| Would any frame generation (AFMF 2, FSR 3.1 FG, XeSS FG) make the game playable? | **no**. At 1.34 rendered fps, 2× generation would present ~2.7 fps with at least one extra frame (≥ 700 ms) of input delay, and the simulation would still advance 1.34 times a second | high | every vendor's guidance needs ~55–60 fps before generation |
| Would FSR 3.1/4 or XeSS SR upscaling raise fps? | no, or slightly lower: they cost more GPU time than bilinear, and the bottleneck is CPU preparation and memory, not pixels | high |
| What does raise fps? | cutting CPU preparation and copy work (~276 ms prep + ~155 ms copies per world frame in T6) and memory pressure (free RAM 86 MB, VRAM over budget 393 of 542 s) | high | see the 10-minute benchmark audit |

## 7. Recommendations (prioritised)

1. **Do not pursue frame generation now.** It cannot compensate for a 1.3 fps native rate and would add large input delay. Revisit only if native world fps passes ~30 (and then AFMF 2 is the zero-integration option on the 780M).
2. **Keep the bilinear built-in upscaler on the low profile**; bicubic is a free quality option to test visually later (no measurable fps cost expected, but measure it in the benchmark before changing the default).
3. **Keep warming every new executable** (`warm --used --again`) before any benchmark; record cold vs warm per build (1,278 s vs 426 s today).
4. **Bound the shader caches on disk** (21 GB): prune translated-shader entries of old translator fingerprints and driver caches of executables no longer used. Needs a design decision (what to keep); not done here.
5. **Investigate the 58 emit failures and the 390 unemitted other-stage programs** for rendering correctness (which pipelines they feed, whether any are drawn in the first 10 minutes).
6. **Leave FSR4 ACO/NewBE alone**: implementing slot 0x218 or translating `ACCC` GFX10 code only matters if the built-in upscaler is ever dropped; porting upstream's PC FidelityFX path (FSR 3.1, MIT) is the better route to real temporal upscaling, once performance justifies it.
7. **Temporal mode** should only be evaluated after native fps rises; at ~1.3 fps the history is too stale to help.

## Sources

- AMD FSR SDK: https://gpuopen.com/amd-fsr-sdk/
- AMD FSR technologies: https://www.amd.com/en/products/graphics/technologies/fidelityfx/super-resolution.html
- AMD FSR Frame Generation: https://gpuopen.com/amd-fsr-framegeneration/
- AMD FSR 3 / 3.1 (MIT, ~60 fps guidance): https://gpuopen.com/fsr3/ , https://gpuopen.com/learn/amd_fsr_3_1_release/
- AMD Fluid Motion Frames: https://amd.com/en/products/software/adrenalin/afmf.html ; iGPU support: https://www.hwcooling.net/en/fluid-motion-frames-now-also-for-radeon-igpus-leaves-preview/ ; AFMF 2: https://www.tomshardware.com/pc-components/gpus/amd-fluid-motion-frames-2-lowers-latency-by-28-percent ; 55/70 fps guidance (secondary): https://www.pcgamer.com/amd-fluid-motion-frames-finally-goes-official-driver-based-frame-generation-for-any-dx1112-game
- NVIDIA DLSS 4 / Multi Frame Generation: https://www.nvidia.com/en-us/geforce/news/dlss4-multi-frame-generation-ai-innovations
- NVIDIA RTX SDKs licence: https://developer.download.nvidia.com/gameworks/NVIDIA-RTX-SDKs-License-23Jan2023.pdf ; https://github.com/NVIDIA/DLSS/
- Intel XeSS 2 whitepaper: https://www.intel.com/content/www/us/en/developer/articles/technical/xess2-whitepaper.html ; XeSS 2.1 cross-vendor FG: https://wccftech.com/intel-xess-2-1-sdk-upscaling-frame-generation-low-latency-support-nvidia-amd-gpus/ ; licence: https://github.com/intel/xess ; XeSS 3 SDK: https://phoronix.com/news/intel-xess-3-sdk-github

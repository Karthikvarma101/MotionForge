# MotionForge

A native Apple-silicon motion-graphics and compositing app: C++20 engine, Metal renderer,
SwiftUI/AppKit editor.

- **Phase 1** (vertical slice): composition viewer, shape and image layers, transform controls,
  an editable timeline with keyframes, undo/redo, project files, autosave/crash recovery, a
  performance monitor, automated tests and a renderer benchmark.
- **Phase 3** (this update): GPU effects (Gaussian Blur, Drop Shadow, Glow, Brightness &
  Contrast, Hue/Saturation, Fill) with animatable parameters, layer masks (rectangle / ellipse;
  add, subtract, intersect, difference; feather, expansion, opacity, invert), track mattes
  (alpha / luma, normal / inverted), an effects browser, an 8-bit cost-aware frame cache,
  background prefetch with a timeline cache bar, configurable cache size, and adaptive preview
  resolution under GPU or memory pressure.

Built and verified on: MacBook Pro (Mac17,2), Apple M5 (4P + 6E CPU, 10-core GPU), 24 GB,
macOS 27.0.1, Xcode 27.1, Swift 6.4, Apple clang 21.

## Build and launch

Requirements: macOS 26 or later on Apple silicon, Xcode (command-line tools are not enough —
Metal and SwiftUI come from the Xcode SDK). No other dependencies. The offline Metal shader
compiler is **not** needed: shaders are compiled at runtime by the OS.

```bash
cd "/Users/karthikvarma/Documents/claude editing/MotionForge"
```

```bash
make run
```

`make run` is `scripts/bundle.sh release` (SwiftPM release build → `build/MotionForge.app`,
ad-hoc signed) followed by `open build/MotionForge.app`. Other targets:

| Command | What it does |
|---|---|
| `make app` | Build `build/MotionForge.app` only |
| `make test` | Build and run `mftests` (core + GPU render-correctness tests) |
| `make bench` | Run the renderer benchmark, write `benchmarks/results-<date>.md` |
| `make sample` | Render the position / scale / opacity demo into `Examples/demo/` and the effects sheet into `Examples/effects/` |
| `scripts/ui-demo.sh` | Launch the real app, drive it (click, drag, edit, undo, play, save), screenshot each step into `build/ui-demo/` |
| `swift build -c release` | Build every target without bundling |

## Using it

- **Add layers**: toolbar or *Layer* menu (rectangle, ellipse, polygon, star, null); import images
  with ⌘I, the toolbar, or by dropping files on the viewer / project panel.
- **Viewer**: click to select, drag to move (Shift constrains to an axis; parented layers move
  in their parent's space), drag empty space or scroll to pan, pinch or ⌘-scroll to zoom.
  Arrow keys nudge 1 px (Shift: 10 px).
- **Inspector**: every number is "hot text" — drag left/right to scrub (Shift ×10, Option ×0.1)
  or click to type. Scale is linked unless you hold ⌘. The stopwatch turns keyframing on; with it
  on, any change writes a keyframe at the playhead. ◀ ◆ ▶ jumps between, adds or removes keys.
- **Timeline**: drag a bar to slide it, its ends to trim; twirl a layer open to see property rows;
  drag keyframes to retime them (frame-snapped), right-click for Linear / Easy Ease / Ease In /
  Ease Out / Hold. Drag in the ruler to scrub. Zoom with the slider; the navigator bar scrolls.
- **Playback**: Space, Home/End, Page Up/Down (or ⌘←/⌘→) for frame steps. The status bar
  shows presented fps, dropped frames, CPU eval/encode time, GPU time, frame-cache use and GPU memory.
- **Preview quality**: Auto / Full / Half / Quarter. The viewer footer always states the actual
  preview resolution (highlighted when reduced). In Auto, playback drops to half (then quarter)
  resolution when the composite takes longer than 85% of the frame budget, and the footer says so
  ("Auto lowered preview: GPU 65.4 ms > 33.3 ms frame budget"); it also stays at half for 15 s
  after a memory-pressure warning. Exports always render at full resolution.
- **Effects**: *Effects* tab in the left panel (searchable; double-click or Apply), the *Effect*
  menu, or *Add Effect* in the inspector. Each effect has a bypass checkbox, ▲▼ to reorder and
  stopwatches on every parameter. Effects run after masks, in stack order; spatial parameters are
  in layer pixels, so they scale with the layer and look identical at every preview resolution.
- **Masks**: *+* in the inspector's Masks section or *Layer → New Rectangle/Ellipse Mask*. Mode,
  invert, feather, expansion, opacity, position, size and roundness — all animatable. The
  selected layer's masks are drawn dashed in the viewer.
- **Track mattes**: *Matte* row in the Layer section: pick any other layer and Alpha / Alpha
  Inverted / Luma / Luma Inverted. The matte layer is hidden automatically but still drives the matte.
- **Frame cache**: *Composition → Frame Cache* (Smart / Cache Every Frame / Off) and *Frame Cache
  Size* (512 MB – 8 GB). Smart keeps only frames that are slow to redraw or contain effects; a
  green bar under the timeline ruler shows which frames of the current state are cached.
- **Composition settings** (⌘K): presets for 16:9 HD/4K, 9:16, 1:1, 4:5, 21:9 or custom size,
  frame rate (23.976–120), duration, background colour.
- **Files**: ⌘S / ⇧⌘S save `.mfproj`, ⌘O open, ⇧⌘E export the current frame as PNG.

## What was verified (and how)

| Claim | Evidence |
|---|---|
| Position / scale / opacity edits change the rendered pixels correctly | `mftests` reads back real Metal output: centroid moves to the new position within 0.05 px, scale 150%×50% gives exactly 300×50 px coverage, 50% opacity gives peak alpha 0.500, 90° rotation swaps extents. `make sample` writes [Examples/demo/demo-sheet.png](Examples/demo/demo-sheet.png): measured area 94,626 px vs 94,627 analytic, centroid (1400.00, 300.00) after the move, ×2.25 area at 150%, peak alpha 0.400 at 40%. |
| The GUI does it end to end | `scripts/ui-demo.sh`: a click in the viewer selects the star, a drag moves it by exactly (+260, −140) px, scale/opacity edits apply, 3× undo restores the original, the layer's keyframes show in the timeline. Screenshots of every step are in `build/ui-demo/`. |
| Undo/redo, drag = one undo step | `undo_redo_and_groups` test; UI demo undo step |
| Save → reopen is lossless; projects survive being moved | `project_file_roundtrip_and_portability` test (moves the project folder: relative media paths win; missing media is flagged, not fatal); UI demo save/reopen gives a byte-identical document |
| Autosave + crash recovery | UI demo: autosave written, read back by a second engine (opacity 40 restored), and the relaunch check reports a recovery would be offered. The recovery prompt dialog itself was not clicked through. |
| Real-time playback | UI demo: 4 s of playback of the starter scene presented 30 of 30 fps with 0 dropped frames |
| Frame cache invalidates only what changed | `frame_hash_precise_invalidation` test; benchmark: recolouring one layer (visible 0–2 s) of 1,000 changes exactly 60 of 300 frames |

| Effects render correctly | `mftests` (GPU readback): blur conserves alpha mass within 1% and matches across preview resolutions; drop shadow lands exactly `distance` px in `direction` (area 10,000 + 4,000 px); glow spills light only from pixels above the threshold; brightness +50 turns 0.5 grey into 0.75; hue +120° turns red into pure green; saturation −100 gives equal channels; fill keeps alpha. [Examples/effects/effects-sheet.png](Examples/effects/effects-sheet.png) shows every effect, a feathered mask and a matte. |
| Masks | ellipse mask area within 1% of πab; subtract and inverted-add give rect − ellipse; intersect of two masks halves it; feather keeps the area within 4%; 50% mask opacity gives alpha 0.5; masks cut before blur |
| Track mattes | alpha matte area within 1% of the circle; inverted gives the rest; 50% grey luma matte gives alpha 0.5; an out-of-range matte hides (alpha) or reveals (inverted) the layer; deleting the matte layer clears the link |
| Project format v2 | effects, masks and mattes round-trip losslessly; a v1 file still opens |
| Cost-aware 8-bit cache | cached copies are RGBA8 (8.3 MB per 1080p frame vs 16.6 MB); with a high threshold plain frames are drawn, not kept, while frames with effects are cached and hit on the next request |
| Effects in the real app | UI demo: blur applied to the card from the catalogue, ellipse mask on the star, an orange layer track-matted by the ring (the ring auto-hidden), three offscreen layers in the frame; 4 s of playback of the effect-laden scene presented 30/30 fps with 0 dropped frames, and afterwards 126 frames of the current state were in the cache (rendered ahead by prefetch) |
| Adaptive preview resolution | UI demo stress step: 4K comp with 24 animated full-frame layers blurred 120 px, at 100% zoom: composite measured 65.4 ms vs the 33.3 ms budget, Auto dropped to half resolution, playback then held 30 fps with 1 dropped frame during the switch |

Test run: **38 tests, 319 checks, 0 failures** on the M5 (stable across 5 consecutive runs).

## Benchmark

`make bench` on the machine above, 240 frames per scenario, every layer animated so the cache
is bypassed (full table: [benchmarks/results-2026-10-28.md](benchmarks/results-2026-10-28.md)):

| Scenario | Effect layers | CPU eval + encode | GPU per frame | Throughput (3 in flight) | 1-frame latency |
|---|---:|---:|---:|---:|---:|
| 1080p, 100 shapes | 0 | 0.03 ms | 0.26 ms | 3,631 fps | 0.45 ms |
| 1080p, 1,000 shapes | 0 | 0.31 ms | 2.32 ms | 404 fps | 2.80 ms |
| 1080p, 5,000 shapes | 0 | 1.48 ms | 12.69 ms | 79 fps | 14.35 ms |
| 4K UHD, 1,000 shapes | 0 | 0.33 ms | 2.36 ms | 392 fps | 2.88 ms |
| 4K, 50 images + 500 shapes | 0 | 0.19 ms | 1.28 ms | 727 fps | 1.65 ms |
| 1080p, 100 shapes, Gaussian Blur 20 px each | 100 | 1.87 ms | 3.94 ms | 262 fps | 6.14 ms |
| 1080p, 20 shapes, Drop Shadow + Glow each | 20 | 0.77 ms | 1.60 ms | 566 fps | 2.60 ms |
| 1080p, 100 shapes, Hue/Sat + Brightness each | 100 | 1.16 ms | 4.03 ms | 268 fps | 5.32 ms |
| 1080p, full-frame layer, blur 25–50 px | 1 | 0.05 ms | 0.82 ms | 869 fps | 1.52 ms |
| 4K, full-frame layer, blur 50–100 px | 1 | 0.11 ms | 3.91 ms | 203 fps | 6.39 ms |
| 1080p, 500 shapes, 2 masks each (1 feathered) | 0 | 0.27 ms | 2.33 ms | 398 fps | 2.75 ms |
| 1080p, 100 shapes, 50 track mattes | 50 | 1.00 ms | 3.45 ms | 306 fps | 4.64 ms |

How to read it: renderer-only numbers (composite, no viewer present, no media decode). Plain
layers are one or two instanced draw calls, so the GPU is the limit and its cost follows covered
pixels (overdraw), not output resolution. Masks are evaluated in the same shader and cost almost
nothing. Each effect layer adds an offscreen pass plus compute work, about 10–20 µs of CPU encode
per layer. They are not a comparison with any other application — no such benchmark has been run.

Measured during Phase 3:
- **Effect-layer encode cost**: the first version allocated an instance buffer per offscreen pass.
  One sub-allocated buffer per frame cut CPU encode by 24–55% (100 blurred layers 2.32 → 1.78 ms;
  50 mattes 1.92 → 0.86 ms).
- **Mask-free pipelines**: adding the mask loop to every fragment shader cost plain shape scenes
  8–20% on the GPU. Pipelines are now specialised with a Metal function constant, so unmasked
  layers skip it: 1,000 shapes is back within 3% of Phase 1 (2.32 vs 2.24 ms). The 5,000-shape
  case is still 13% slower than the Phase 1 run (12.7 vs 11.2 ms, reproducible). There was no
  version control to A/B the two builds, so I can't yet say whether that comes from the shader
  changes or from different machine conditions.

## Project layout

```
MotionForge/
├── Package.swift              SwiftPM manifest (C++20, macOS 26, arm64)
├── Makefile                   build / run / test / bench / sample
├── scripts/bundle.sh          release build → signed build/MotionForge.app
├── scripts/ui-demo.sh         scripted end-to-end GUI check with screenshots
├── Sources/
│   ├── MFCore/                C++20, no platform dependencies
│   │   ├── include/mf/Math.hpp        2D affine math
│   │   ├── include/mf/Model.hpp       project / composition / layer / keyframe model
│   │   ├── Model.cpp                  property defs, keyframe interpolation (linear, hold, bezier)
│   │   ├── Evaluator.cpp              timeline → flat draw list + 64-bit content hash, hit testing
│   │   ├── Document.cpp               all edits, snapshot undo/redo with groups, dirty tracking
│   │   ├── ProjectIO.cpp              versioned .mfproj (JSON), relative+absolute media paths, atomic save
│   │   ├── Json.cpp                   dependency-free JSON parser/writer
│   │   └── include/mf/LruCache.hpp    byte-budgeted LRU (frame cache policy)
│   ├── MFRender/              Objective-C++ — Metal backend + bridge
│   │   ├── Shaders.hpp                MSL: instanced SDF shapes + masks, images, blend modes, effect kernels, present
│   │   ├── MetalRenderer.mm           pipelines, offscreen effect/matte layers (MPS blur), pools, frame cache, media
│   │   ├── MFEngine.mm                Objective-C API that Swift uses
│   │   └── include/MFEngine.h         the Swift-visible bridge (module map exposes only this)
│   ├── MotionForge/           Swift — SwiftUI/AppKit editor
│   │   ├── MotionForgeApp.swift       app, window layout, toolbar, menus
│   │   ├── EditorModel.swift          UI state, edits, files, autosave, memory pressure, shortcuts
│   │   ├── ViewerView.swift           MTKView viewer, playback clock, direct manipulation
│   │   ├── TimelineView.swift         ruler, layer bars, property rows, keyframes
│   │   ├── InspectorView.swift        layer / transform / shape properties
│   │   ├── Panels.swift               project panel, composition settings, perf status bar
│   │   ├── Controls.swift             scrub fields, keyframe glyphs, theme
│   │   ├── RecoveryStore.swift        autosave + crash recovery
│   │   └── UIDemo.swift               scripted UI check used by scripts/ui-demo.sh
│   ├── mftests/               test runner (core + GPU readback)
│   ├── mfbench/               renderer benchmark
│   └── mfcli/                 headless tool: info, render PNG, PNG sequence, demo, effects-demo
├── benchmarks/                benchmark results
├── Examples/demo/             position/scale/opacity demo renders + demo.mfproj
├── Examples/effects/          effects / mask / matte contact sheet
└── docs/ARCHITECTURE.md       design notes (threading, memory, caching, colour, file format)
```

`mfcli` also works on any project: `.build/release/mfcli render my.mfproj out.png --time 2.5`,
`.build/release/mfcli frames my.mfproj out-dir --from 0 --to 5`.

## Known limitations of this slice

- **Frame cache**: cached frames are now 8-bit (8.3 MB per 1080p frame, ~4 s of 1080p30 per GB),
  so the default 2.4 GB budget holds a 9 s 1080p loop. The cache still fills to its budget when
  every frame has effects, because stale frames from earlier edits stay until the LRU evicts them.
  The budget is configurable. The cost threshold for "worth caching" (0.75 ms of GPU time) is a
  heuristic measured per composition. On a cold GPU the first frames can measure high, which the
  moving average corrects within a few frames.
- Timeline evaluation and command encoding still run on the main thread (sub-millisecond for most
  comps, ~1.9 ms for 100 effect layers). Prefetch rendering happens on the GPU without blocking,
  but its evaluation is on the main thread too. Moving evaluation to a worker is Phase 6 work.
- Masks are parametric rectangles/ellipses; bezier masks arrive with the pen tool (Phase 4).
  No motion blur, transitions or particles yet.
- Drop Shadow and Glow work on the layer's own pixels in layer space, like most motion tools; Glow
  uses the layer's own colours (no tint option yet).
- Spatial interpolation is linear (no motion-path curves yet); temporal easing is influence-only
  (no speed handles). Both come with the graph editor in Phase 4.
- No text, video, audio, masks, mattes, effects, precomps, node editor or render queue yet —
  see the roadmap. PNG still/sequence export exists in `mfcli` and *File → Export Frame*.
- The project format stores whole-document JSON; very large projects may want a binary or chunked
  format later. Its `version` field is checked on load so migrations can be added.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Native app, Metal renderer, viewer, image + shape layers, transforms, basic timeline, project files | **Done** (plus keyframes, easing, undo, parenting, blend modes, autosave pulled forward) |
| 2 | Keyframes, playback, interpolation, undo/redo, saving | Mostly done; remaining: spatial bezier paths, copy/paste of keys, multi-selection |
| 3 | Metal effects (blur, glow, shadow, colour), masks, track mattes, memory manager, background caching | **Done** (6 effects, parametric masks, 4 matte modes, cost-aware 8-bit cache, prefetch, adaptive resolution) |
| 4 | Text animation, shape tools (pen/bezier paths), graph editor, presets, node compositing | Planned |
| 5 | Video import (AVFoundation/VideoToolbox), audio, proxies, hardware export, render queue | Planned |
| 6 | Whole-app profiling on the M5, long-session stability | Planned |

## Third-party code and licences

None. MotionForge uses only Apple system frameworks (Metal, MetalKit, Metal Performance
Shaders, AppKit, SwiftUI, CoreGraphics, ImageIO, CoreText, UniformTypeIdentifiers) and its own code. If FFmpeg is added
in Phase 5 for codecs AVFoundation can't read, its LGPL/GPL obligations (dynamic linking, source
offer, no GPL-only components in a closed build) will need to be handled and documented.

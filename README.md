<p align="center"><img src="Resources/Brand/MotionForge-wordmark.png" alt="MotionForge" width="560"></p>

# MotionForge

A native Apple-silicon motion-graphics and compositing app: C++20 engine, Metal renderer,
SwiftUI/AppKit editor.

- **Phase 1** (vertical slice): composition viewer, shape and image layers, transform controls,
  an editable timeline with keyframes, undo/redo, project files, autosave/crash recovery, a
  performance monitor, automated tests and a renderer benchmark.
- **Phase 2** (completed after Phase 3): spatial bezier motion paths with on-screen handles and
  constant speed along curves, multi-selection of layers and keyframes (⌘/⇧-click, marquee),
  multi-key retiming/easing/deletion, and copy/paste of layers and keyframes, between projects too.
- **Phase 3**: GPU effects (Gaussian Blur, Drop Shadow, Glow, Brightness &
  Contrast, Hue/Saturation, Fill) with animatable parameters, layer masks (rectangle / ellipse;
  add, subtract, intersect, difference; feather, expansion, opacity, invert), track mattes
  (alpha / luma, normal / inverted), an effects browser, an 8-bit cost-aware frame cache,
  background prefetch with a timeline cache bar, configurable cache size, and adaptive preview
  resolution under GPU or memory pressure.
- **Phase 4**: text layers (CoreText layout, GPU glyph sheets, font / size / tracking / leading /
  alignment) with range-selector text animators (characters, words or lines; six selector
  shapes); a pen tool for bezier shape layers and bezier masks, Trim Paths on strokes; a value
  graph editor with ease-influence and speed handles (overshoot included); 13 built-in animation
  presets plus your own; and a node workspace that shows and rewires the layer stack as a graph.
- **After Effects import** (added to recreate a real AE project): precomp layers (nested
  compositions with start time, time remapping and collapse transformations, edited by opening
  them from the Project panel's composition browser), baked per-frame animation for any
  property and for shape / mask paths, per-layer motion blur (shutter angle, phase and samples per
  composition), text strokes, a Gradient Ramp effect and per-character stagger on text animators.
  `kids_yoga_beginners/motionforge/` (next to this repository) exports an `.aep` from After
  Effects and converts it; see "Importing After Effects projects" below.

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
| `make sample` | Render the position / scale / opacity demo into `Examples/demo/`, the effects sheet into `Examples/effects/` and the text / path sheet into `Examples/phase4/` |
| `scripts/ui-demo.sh` | Launch the real app, drive it (click, drag, edit, undo, play, save), screenshot each step into `build/ui-demo/` |
| `scripts/ui-demo-nav.sh project.mfproj` | Open a nested project and go master › scene › rig through tabs and breadcrumb; zoom with ⌥-scroll and scroll with sideways swipes (scroll events sent inside the app). Screenshots go to `build/ui-demo-nav/` |
| `swift build -c release` | Build every target without bundling |
| `scripts/make-icon.sh` | Rebuild `Resources/AppIcon.icns` from the brand artwork in `Resources/Brand/` |

## Using it

- **Add layers**: toolbar or *Layer* menu (rectangle, ellipse, polygon, star, null, text); import
  images with ⌘I, the toolbar, or by dropping files on the viewer / project panel.
- **Viewer**: click to select, drag to move (Shift constrains to an axis; parented layers move
  in their parent's space), drag empty space or scroll to pan, pinch or ⌘-scroll to zoom.
  Arrow keys nudge 1 px (Shift: 10 px).
- **Inspector**: every number is "hot text" — drag left/right to scrub (Shift ×10, Option ×0.1)
  or click to type. Scale is linked unless you hold ⌘. The stopwatch turns keyframing on; with it
  on, any change writes a keyframe at the playhead. ◀ ◆ ▶ jumps between, adds or removes keys.
- **Timeline**: drag a bar to slide it, its ends to trim; twirl a layer open to see property rows;
  drag keyframes to retime them (frame-snapped), right-click for Linear / Easy Ease / Ease In /
  Ease Out / Hold. Drag in the ruler to scrub.
- **Timeline zoom and scroll**:
  - **Zoom:** pinch on the trackpad, or ⌥- / ⌘-scroll with a mouse or trackpad. The zoom centres
    on the pointer, from the whole composition down to single frames (about 40 px per frame).
  - **Scroll through time:** swipe sideways with two fingers, or ⇧-scroll with a mouse wheel.
  - **Vertical scrolling** still moves the layer list.
  - **Keys:** = and − zoom around the playhead; \\ shows the whole composition. The slider is
    logarithmic.
  - **Navigator bar:** drag it to scroll; double-click it to fit the whole composition.
- **Compositions and precomps**:
  - **Open a precomp:** double-click its icon in the timeline, choose *Open Precomp* from its
    context menu, or use *Open* in the inspector. The playhead moves to the matching time inside
    it, including through time remapping.
  - **Tabs:** every composition you open gets a tab above the timeline. Switching back to one
    restores its playhead, zoom and scroll position.
  - **Breadcrumb:** the trail under the tabs shows how you got there (master › scene › rig).
    Click any level to go back up, or press ⌘⇧↑ for the parent. Its menus list the precomps
    inside the current composition and the compositions that use it.
- **Playback**: Space, Home/End, Page Up/Down (or ⌘←/⌘→) for frame steps. The status bar
  shows presented fps, dropped frames, CPU eval/encode time, GPU time, frame-cache use and GPU memory.
- **Preview quality**: Auto / Full / Half / Quarter. The viewer footer always states the actual
  preview resolution (highlighted when reduced). In Auto, playback drops to half (then quarter)
  resolution when the composite takes longer than 85% of the frame budget, and the footer says so
  ("Auto lowered preview: GPU 65.4 ms > 33.3 ms frame budget"); it also stays at half for 15 s
  after a memory-pressure warning. Exports always render at full resolution.
- **Selection**: ⌘-click toggles a layer, ⇧-click adds (⇧-click in the timeline selects a range),
  ⌘A selects all layers. Dragging any selected layer in the viewer moves all of them, each in its own
  parent's space; arrow keys nudge them all; delete/duplicate apply to all. Sliding a selected
  layer's bar in the timeline slides every selected layer. The inspector edits the primary
  (last-clicked) layer and says how many are selected.
- **Keyframes**: ⌘/⇧-click to build a selection, or drag a rubber band across property rows
  (⌘/⇧ to add). Dragging one selected key retimes them all by the same frame-snapped offset;
  right-click applies easing, motion-path mode, copy or delete to the whole selection.
- **Copy / paste** (⌘C, ⌘X, ⌘V): with keyframes selected, ⌘C copies them; the earliest lands on
  the playhead when pasted onto the selected layer(s), spacing intact. Tracks map by property,
  effect type and mask slot, so you can paste between layers, and anything without a match is
  reported. Otherwise ⌘C copies layers (with their effects, masks, keyframes and media); they
  paste above the topmost selected layer, keeping parent and matte links among themselves. It uses
  the system pasteboard, so it works between projects.
- **Motion paths**: new position keyframes are smooth (auto bezier), and linear timing moves
  at constant speed along the curve. The selected layer's path is drawn dotted in the viewer:
  drag a key square to move that keyframe, drag a handle dot to shape the curve (handles stay
  opposite each other; hold ⌥ to break them). Right-click a position keyframe for *Smooth* or
  *Corner*.
- **Effects**: *Effects* tab in the left panel (searchable; double-click or Apply), the *Effect*
  menu, or *Add Effect* in the inspector. Each effect has a bypass checkbox, ▲▼ to reorder and
  stopwatches on every parameter. Effects run after masks, in stack order; spatial parameters are
  in layer pixels, so they scale with the layer and look identical at every preview resolution.
- **Masks**: *+* in the inspector's Masks section or *Layer → New Rectangle/Ellipse Mask*. Mode,
  invert, feather, expansion, opacity, position, size and roundness — all animatable. The
  selected layer's masks are drawn dashed in the viewer.
- **Track mattes**: *Matte* row in the Layer section: pick any other layer and Alpha / Alpha
  Inverted / Luma / Luma Inverted. The matte layer is hidden automatically but still drives the matte.
- **Text**: *Text* in the toolbar (or ⌥⇧⌘T). Type in the inspector's *Text* box; pick a font
  (PostScript names from a curated menu) and left / centre / right alignment. *Character* has
  Font Size, Tracking (1/1000 em), Line Height and Fill Colour, all animatable. Masks and effects
  work on text like on any layer.
- **Text animators**: *+* in *Text Animators* adds an Opacity, Position, Scale or Rotation
  animator. Its range selector picks Characters, Words or Lines between Range Start and End
  (shifted by Offset), with a Square, Ramp Up, Ramp Down, Triangle, Round or Smooth shape;
  keyframe Start, End or Offset to sweep the effect across the text (a typewriter is Start
  0 → 100). Characters moved by an animator stay inside their layer's effects and masks.
- **Pen tool**: *Pen* in the toolbar or P (V or Esc returns to selection). Click for a corner
  point, drag for a smooth point with handles, click the first point to close the shape, Return
  for an open line. The toolbar switch next to it chooses *New Shape* (a new path layer) or
  *Mask on Layer* (a bezier mask on the selected layer). Afterwards, drag points and handles of the
  selected path in the viewer.
- **Trim Paths**: path layers have Trim Start, Trim End and Trim Offset in *Shape Properties*;
  animate End from 0 to 100% to make a stroke draw itself (Offset wraps round closed shapes).
- **Graph editor**: *Graph* in the timeline's transport bar swaps the keyframe rows for value
  curves of the selected keys (or of the selected layer's animated properties). Drag a key to
  change its time and value; drag a handle sideways for ease influence and up/down for speed —
  flatter is slower, past the next value overshoots. One undo step per drag.
- **Presets**: the *Effects* tab lists presets under Entrances, Exits, Attention, Styles and Text
  (e.g. Fade In, Slide Up, Bounce, Glow Pulse, Typewriter, Pop by Word). Double-click or *Apply*
  puts the preset's start at the playhead on every selected layer, as one undo step; movement
  presets are relative, so Slide Up ends where the layer already is. *Layer → Save Animation
  Preset…* saves the selected layer's keyframes, effects and text animators as a `.mfpreset`
  in `~/Library/Application Support/MotionForge/Presets` (listed under *My Presets*).
- **Node workspace**: the *Viewer | Nodes* switch in the toolbar. Each layer is a chain
  Source → Masks → Effects feeding a Composite node whose slots are the stacking order; matte and
  parent links are wires. Drag a layer's ● output onto another layer's *matte* or *parent* socket
  to link it, or onto a Composite slot to restack. It is a view and editor of the same layer
  stack, not a separate node compositor: every wire maps to a layer setting and undoes like one.
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

| Motion paths | auto keys pass exactly through every key with no corner (< 3° turn) and bow off the chord; linear keys give straight segments and a corner; equal time steps cover equal distances along the curve (±2%); explicit handles give the analytic arch (50, 75); editing a handle invalidates only the frames of that segment; pre-v3 keys load as straight paths |
| Multi-key / multi-layer ops | moving 3 keys over 2 properties is one undo step with correct new indices; a key landing on another replaces it; easing and deletion apply to all; duplicating a parent + child re-links the copies; deleting a matte source clears the link |
| Clipboard | layers pasted into a *different* project keep their stacking order, parent and matte links inside the set, effects and masks, and bring their media (reused, not duplicated, on a second paste); all ids unique; keyframes paste relative to the playhead, map effect tracks by type, report what had no match, one undo step |
| Phase 2 in the real app | UI demo: ⌘-click added Card to Star in the viewer and a drag moved both by exactly (−120, +60) as one undo step; copy + paste of the two layers added two selected copies; dragging a motion-path handle turned the key into a Bezier key with opposite handles; Card's position keys at 0/1/2 s pasted onto Star at 3/4/5 s. The demo uses a private pasteboard, so it never touches yours |

| Text | `mftests` (GPU readback): bounds come from CoreText metrics (not an estimate) and are centred on the anchor; caps sit on the baseline; left / right alignment start / end at the anchor within a few px; tracking 200 adds exactly 4 gaps × 20 px = 80 px (±3); editing the text changes the frame hash, the same text keeps it |
| Text animators | an Opacity animator over Start 0–50% hides exactly the first 5 of 10 characters (area ±3%); a typewriter (Start 0 → 100 over 1 s) shows 30% of the ink at 0.3 s; a Position animator moves the selected characters by its offset (±1.5 px), with offscreen regions following them; Triangle / Ramp Up / Ramp Down selector weights match their definitions |
| Text with masks and effects | a mask over the left half keeps half the ink (±4%); blur keeps the ink mass (±2%) |
| Bezier paths and Trim Paths | a pen-drawn triangle fills ½·200·200 px² (±200) with the layer at its centre; a 4-vertex kappa circle of radius 100 is within 1% of π·100²; a stroked open line equals rectangle + round caps (±2%); trimming to 50% leaves the first half (±3%); a closed outline trimmed to half its perimeter with a wrapping offset is within 6% |
| Bezier masks | a triangle mask on a 200×100 rectangle keeps exactly half (±150 px²); inverted keeps the other half |
| Graph editor easing | an outgoing speed of 1 leaves at linear speed (value clearly ahead of the eased curve at 25%); an incoming speed of −3 overshoots past 103 before landing exactly on 100; `setKeyframeEase` stores influence + speed and they round-trip through JSON |
| Presets | 13 built-ins; Fade In applied at 2 s puts keys at 2.0 / 2.5 s; Slide Up ends where the layer already is; a text preset on a shape layer is reported instead of half-applied; Typewriter on a text layer adds 1 animator with 2 Start keys; a user preset with an animated Glow re-creates the effect and its keys on another layer |
| Project format v4 | text, animators, bezier paths, path masks and speed handles round-trip losslessly (`back == original`); v1–v3 files still load |
| Phase 4 in the real app | UI demo: a text layer typed "MotionForge" in Avenir Next Heavy, the Typewriter preset applied (1 animator, 2 Start keys; screenshot `18-text-typewriter.png` shows "MotionF" at 60%); the pen tool drew a closed 4-point path with 2 smooth (dragged) points (`19-pen-shape.png`); the graph editor (`20-graph-editor.png`) and node workspace (`21-node-workspace.png`) were opened and screenshotted. Playback of the full scene afterwards: 31/30 fps presented, 0 dropped, 126 frames cached; save + reopen gave an identical document; the 4K stress step dropped to quarter resolution ("GPU 58.5 ms > 33.3 ms frame budget") with 6 dropped frames during the switch |

Test run: **55 tests, 473 checks, 0 failures** on the M5.

## Benchmark

`make bench` on the machine above, 240 frames per scenario, every layer animated so the cache
is bypassed (full table: [benchmarks/results-2026-10-28.md](benchmarks/results-2026-10-28.md)):

| Scenario | Effect layers | CPU eval + encode | GPU per frame | Throughput (3 in flight) | 1-frame latency |
|---|---:|---:|---:|---:|---:|
| 1080p, 100 shapes | 0 | 0.04 ms | 0.26 ms | 3,424 fps | 0.44 ms |
| 1080p, 1,000 shapes | 0 | 0.35 ms | 2.27 ms | 388 fps | 2.85 ms |
| 1080p, 5,000 shapes | 0 | 1.73 ms | 13.28 ms | 76 fps | 15.20 ms |
| 4K UHD, 1,000 shapes | 0 | 0.36 ms | 2.44 ms | 381 fps | 3.03 ms |
| 4K, 50 images + 500 shapes | 0 | 0.22 ms | 1.28 ms | 686 fps | 1.67 ms |
| 1080p, 100 shapes, Gaussian Blur 20 px each | 100 | 1.90 ms | 4.15 ms | 259 fps | 6.33 ms |
| 1080p, 20 shapes, Drop Shadow + Glow each | 20 | 0.99 ms | 1.70 ms | 468 fps | 2.93 ms |
| 1080p, 100 shapes, Hue/Sat + Brightness each | 100 | 1.15 ms | 4.31 ms | 245 fps | 5.64 ms |
| 1080p, full-frame layer, blur 25–50 px | 1 | 0.15 ms | 1.28 ms | 544 fps | 2.20 ms |
| 4K, full-frame layer, blur 50–100 px | 1 | 0.17 ms | 4.61 ms | 140 fps | 8.31 ms |
| 1080p, 500 shapes, 2 masks each (1 feathered) | 0 | 0.30 ms | 2.43 ms | 381 fps | 2.91 ms |
| 1080p, 100 shapes, 50 track mattes | 50 | 0.94 ms | 3.56 ms | 297 fps | 4.65 ms |
| 1080p, 100 text layers × 30 characters (3,000 glyphs) | 0 | 0.32 ms | 0.26 ms | 1,830 fps | 1.09 ms |
| 1080p, 20 text layers × 30 characters, range animator | 0 | 0.07 ms | 0.10 ms | 2,193 fps | 0.65 ms |
| 1080p, 200 bezier paths (8 smooth points, fill + stroke) | 0 | 0.80 ms | 20.78 ms | 48 fps | 22.29 ms |
| 1080p, 200 open paths, Trim Paths animated, 8 px stroke | 0 | 0.64 ms | 10.91 ms | 86 fps | 12.20 ms |
| 1080p, 200 shapes with a bezier mask each | 0 | 0.36 ms | 7.38 ms | 128 fps | 8.32 ms |

How to read it: renderer-only numbers (composite, no viewer present, no media decode). Plain
layers are one or two instanced draw calls, so the GPU is the limit and its cost follows covered
pixels (overdraw), not output resolution. Masks are evaluated in the same shader and cost almost
nothing. Each effect layer adds an offscreen pass plus compute work, about 10–20 µs of CPU encode
per layer. They are not a comparison with any other application — no such benchmark has been run.
`mfbench --snapshots DIR` writes the frame at 5 s of every scenario as a PNG, to check what was
measured.

This run differs from the Phase 3 table by up to +56% on single full-frame blurs (1.28 vs
0.82 ms), but a 10-frame re-run minutes later measured 0.74 ms (1080p) and 2.98 ms (4K), faster
than Phase 3; see *Comparing performance between builds* for why single runs can't be compared.

Measured during Phase 4:
- **Text** is cheap on the GPU (3,000 glyphs in 0.26 ms) and CPU-bound: each text layer is its
  own draw call because it samples its own glyph sheet, and building the per-glyph instances
  costs about 2.5 µs of encode per 30-character layer. Glyphs are rasterised once per layout and
  scale step, not per frame.
- **Bezier paths are the expensive primitive.** Every fragment of a path's bounding quad walks
  all of that path's flattened edges (winding number for the fill, distance for the stroke), so
  cost grows with covered pixels × edges. 200 overlapping 240-px blobs took 16–21 ms of GPU time
  per 1080p frame across two runs: fine for tens of paths, not for hundreds. Caching each path's
  coverage (paths aren't animated per vertex) or binning edges per tile would remove most of it;
  not done yet.
- **Specialising for paths**: the first Phase 4 shader put the path branches in every shape
  fragment, and the interleaved A/B measured plain shapes +7.7% slower than Phase 1. A second
  function constant (`kHasPaths`) took them out of path-free pipelines, bringing it back to
  +0.2% (5,000 shapes) and +0.3% (1,000 shapes); a re-run for this README gave +0.5% and +1.2%.
  The mask-enabled pipeline (what plain layers would pay without specialisation) measured +3.9%,
  then +5.2% / +3.6%. A 7.7% change is inside the run-to-run drift described below, so only the
  interleaved A/B could catch it.

Measured during Phase 3:
- **Effect-layer encode cost**: the first version allocated an instance buffer per offscreen pass.
  One sub-allocated buffer per frame cut CPU encode by 24–55% (100 blurred layers 2.32 → 1.78 ms;
  50 mattes 1.92 → 0.86 ms). These are CPU timings from consecutive runs, so they're less exposed to
  the GPU clock drift described below.
- **Mask-free pipelines**: pipelines are specialised with a Metal function constant so layers
  without masks skip the mask code. An interleaved A/B (below) puts the unspecialised mask shader
  at +3.5–4.0% GPU time for plain shapes; the specialised one is within ±1% of the Phase 1 shader.

### Comparing performance between builds

Absolute GPU times on this MacBook drift with recent load: the same 5,000-shape frames measured
13.1, 13.9 and 15.1 ms in three back-to-back runs (no thermal warning recorded, AC power, Low Power
Mode off), and 11.2 ms in the Phase 1 session. Numbers from different runs or sessions are
therefore not comparable. Phase 3 first looked 13% slower than Phase 1 at 5,000 shapes; the A/B
showed that was the machine, not the code. To compare builds, run them interleaved:

```bash
benchmarks/ab/run.sh --layers 5000 --frames 240
```

[benchmarks/ab/shader_ab.mm](benchmarks/ab/shader_ab.mm) renders identical frames through the Phase 1
shader, the current shader and the unspecialised mask shader, rotating the order every frame.
Result on the M5 at the end of Phase 3, 3 runs: current vs Phase 1 −0.8%, −0.7%, +0.1% (5,000
shapes) and −0.3% (1,000 shapes). After Phase 4 (128-byte instances, path specialisation):
+0.5% (5,000) and +1.2% (1,000), so the noise floor of this A/B is about ±1%. With git in place,
whole builds can now be compared the same way, by building two commits and alternating their
benchmark runs.

## Project layout

```
MotionForge/
├── Package.swift              SwiftPM manifest (C++20, macOS 26, arm64)
├── Makefile                   build / run / test / bench / sample
├── scripts/bundle.sh          release build → signed build/MotionForge.app
├── scripts/ui-demo.sh         scripted end-to-end GUI check with screenshots
├── scripts/make-icon.*        app icon from the brand artwork (transparent cut-out on Apple's grid)
├── Resources/                 AppIcon.icns; Brand/ = source icon, 1024 px master, wordmark
├── Sources/
│   ├── MFCore/                C++20, no platform dependencies
│   │   ├── include/mf/Math.hpp        2D affine math
│   │   ├── include/mf/Model.hpp       project / composition / layer / keyframe model
│   │   ├── Model.cpp                  property defs, keyframe interpolation (linear, hold, bezier)
│   │   ├── Evaluator.cpp              timeline → flat draw list + 64-bit content hash, hit testing
│   │   ├── Document.cpp               all edits, snapshot undo/redo with groups, dirty tracking
│   │   ├── ProjectIO.cpp              versioned .mfproj (JSON), relative+absolute media paths, atomic save
│   │   ├── Presets.cpp                animation presets: built-ins, capture from a layer, apply (relative tracks)
│   │   ├── Json.cpp                   dependency-free JSON parser/writer
│   │   └── include/mf/LruCache.hpp    byte-budgeted LRU (frame cache policy)
│   ├── MFRender/              Objective-C++ — Metal backend + bridge
│   │   ├── Shaders.hpp                MSL: instanced SDF shapes, bezier paths + masks, glyphs, blend modes, effect kernels, present
│   │   ├── MetalRenderer.mm           pipelines, path flattening, offscreen effect/matte layers (MPS blur), pools, frame cache, media
│   │   ├── TextEngine.mm              CoreText layout cache + GPU glyph sheets
│   │   ├── MFEngine.mm                Objective-C API that Swift uses
│   │   └── include/MFEngine.h         the Swift-visible bridge (module map exposes only this)
│   ├── MotionForge/           Swift — SwiftUI/AppKit editor
│   │   ├── MotionForgeApp.swift       app, window layout, toolbar, menus
│   │   ├── EditorModel.swift          UI state, edits, files, autosave, memory pressure, shortcuts
│   │   ├── ViewerView.swift           MTKView viewer, playback clock, direct manipulation
│   │   ├── TimelineView.swift         ruler, layer bars, property rows, keyframes
│   │   ├── TimelineNavigation.swift   composition tabs + breadcrumb, timeline zoom/scroll gestures
│   │   ├── GraphEditorView.swift      value curves with ease / speed handles
│   │   ├── NodeGraphView.swift        node workspace (layer stack as Source → Masks → Effects → Composite)
│   │   ├── InspectorView.swift        layer / transform / shape / text / animator / mask / effect properties
│   │   ├── Panels.swift               project, effects + presets browser, composition settings, perf status bar
│   │   ├── Controls.swift             scrub fields, keyframe glyphs, theme
│   │   ├── RecoveryStore.swift        autosave + crash recovery
│   │   └── UIDemo.swift               scripted UI check used by scripts/ui-demo.sh
│   ├── mftests/               test runner (core + GPU readback)
│   ├── mfbench/               renderer benchmark
│   └── mfcli/                 headless tool: info, render PNG, PNG sequence, demo, effects-demo, phase4-demo
├── benchmarks/                benchmark results; ab/ = interleaved shader A/B harness
├── Examples/demo/             position/scale/opacity demo renders + demo.mfproj
├── Examples/effects/          effects / mask / matte contact sheet
├── Examples/phase4/           text, animator, bezier path, trim and bezier-mask contact sheet
└── docs/ARCHITECTURE.md       design notes (threading, memory, caching, colour, text, paths, presets, file format)
```

`mfcli` also works on any project: `.build/release/mfcli render my.mfproj out.png --time 2.5`,
`.build/release/mfcli frames my.mfproj out-dir --from 0 --to 5`.

## Importing After Effects projects

AE expressions, rigs and plug-in logic aren't reimplemented. After Effects evaluates them
during the export, and MotionForge stores the results as *baked* tracks: one value or path per
frame, interpolated between frames. A baked property shows a waveform icon instead of the
stopwatch. Editing its value shifts the whole animation, and clicking the icon replaces it with an
ordinary keyframe. Baked data is shared between undo snapshots, and undo history has a 1 GB budget,
so large imports stay cheap to edit.

The first import is the 5:38 *Kids Yoga for Beginners* film (`KIDS_YOGA_BEGINNERS.aep`: 37 comps,
eight scenes with three rigged characters each). It became a project of 795 compositions and
about 5,400 layers, because each AE shape layer becomes a small composition holding its groups. The pipeline,
the mapping and what doesn't convert (audio, adjustment layers, 3D) are in
`kids_yoga_beginners/motionforge/README.md`. `mfcli time` measures a real project: CPU evaluation
and GPU composite per frame, with and without motion blur.

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
- Not exercised by the automated UI demo (they compile and their document operations are
  unit-tested, but nothing drove them through the UI): the timeline marquee, dragging several keys
  in the timeline, range-select with ⇧ in the layer list, dragging keys or handles in the graph
  editor, and wiring in the node workspace (the demo opens both and takes a screenshot).
- Viewer clicks hit-test layer *bounds*, so a full-frame layer with a track matte catches clicks
  everywhere even though it only shows through its matte (hide it, or select from the timeline).
- Dragging keys onto other keys replaces them, even if the drag continues past them.
- Only the layer position has an on-screen path editor; anchor-point and mask-position keys are
  smooth too, but are edited numerically.
- Checking each animated position for a curve made timeline evaluation ~6% slower (5,000 animated
  layers: 1.39 → 1.48 ms of CPU).
  No transitions or particles yet. Motion blur is applied when rendering stills and sequences
  (`mfcli`, *File → Export Frame*). The interactive viewer shows the frame without it.
- Drop Shadow and Glow work on the layer's own pixels in layer space, like most motion tools; Glow
  uses the layer's own colours (no tint option yet).
- No video, audio, adjustment layers or render queue yet — see the roadmap. PNG still/sequence
  export exists in `mfcli` and *File → Export Frame*. Non-collapsed precomps render as a group at
  the parent's resolution (sharper than AE's rasterise-then-transform when scaled up).
- **Paths**: a path's points can be dragged but not keyframed; animated paths exist only as baked
  tracks (imports). Trim Paths trims the stroke only; the fill stays whole. Many large paths are slow (see the
  benchmark: every fragment walks every edge of its path).
- **Text**: point text only (lines break where you press Return); one font, size, fill and stroke
  per layer; the font menu is a fixed list of 14 PostScript names (imported projects keep any
  installed font). Animators move,
  scale, rotate and fade characters / words / lines; no colour, blur or tracking animators yet.
- **Graph editor**: value curves only (no separate speed graph); a position key's two
  components share one ease, so dragging the x curve's handle also changes y's timing.
- **Node workspace**: it is computed from the layer stack, so node positions aren't saved and
  there are no free-floating nodes; it can link mattes and parents and restack, but effects and
  masks are still added in the inspector.
- The project format stores whole-document JSON; very large projects may want a binary or chunked
  format later. Its `version` field is checked on load so migrations can be added.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Native app, Metal renderer, viewer, image + shape layers, transforms, basic timeline, project files | **Done** (plus keyframes, easing, undo, parenting, blend modes, autosave pulled forward) |
| 2 | Keyframes, playback, interpolation, undo/redo, saving | **Done** (plus spatial bezier paths, multi-selection, copy/paste) |
| 3 | Metal effects (blur, glow, shadow, colour), masks, track mattes, memory manager, background caching | **Done** (6 effects, parametric masks, 4 matte modes, cost-aware 8-bit cache, prefetch, adaptive resolution) |
| 4 | Text animation, shape tools (pen/bezier paths), graph editor, presets, node compositing | **Done** (text + range-selector animators, pen paths + bezier masks + Trim Paths, value graph with speed handles, 13 built-in + user presets, node view of the layer stack) |
| 5 | Video import (AVFoundation/VideoToolbox), audio, proxies, hardware export, render queue | Planned |
| 6 | Whole-app profiling on the M5, long-session stability | Planned |

## Third-party code and licences

None. MotionForge uses only Apple system frameworks (Metal, MetalKit, Metal Performance
Shaders, AppKit, SwiftUI, CoreGraphics, ImageIO, CoreText, UniformTypeIdentifiers) and its own code. If FFmpeg is added
in Phase 5 for codecs AVFoundation can't read, its LGPL/GPL obligations (dynamic linking, source
offer, no GPL-only components in a closed build) will need to be handled and documented.

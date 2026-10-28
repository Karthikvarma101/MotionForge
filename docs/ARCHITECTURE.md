# MotionForge architecture (Phases 1–4)

## Layers of the system

```
 SwiftUI / AppKit editor (Swift)          EditorModel, viewer, timeline, inspector
          │  Objective-C bridge            MFEngine.h — the only header Swift sees
          ▼
 MFRender (Objective-C++)                  MetalRenderer: pipelines, pools, frame cache, media
                                           TextEngine: CoreText layout cache, glyph sheets
          │
          ▼
 MFCore (C++20, platform-free)             Document (edits/undo) → Evaluator (draw list + hash)
                                           ProjectIO (.mfproj), Presets, Json, LruCache, Math
```

MFCore has no Apple dependencies, so the model, keyframe maths, evaluation, undo and the file
format are unit-tested headlessly. MFRender owns every Metal object. Swift never touches C++:
the module map in `Sources/MFRender/include` exposes only `MFEngine.h`, while the Objective-C++
tools (`mftests`, `mfbench`, `mfcli`) can also include `MFRender/MetalRenderer.hpp` directly.

## Frame pipeline

1. **Evaluate (CPU)** — `evaluateFrame(project, comp, time, scale)` walks layers bottom-to-top,
   evaluates each animated property (binary search for the keyframe segment, cubic-bezier timing
   for eased segments), composes `T(position)·R(rotation)·S(scale)·T(−anchor)` through the parent
   chain, and emits one `DrawItem` per visible layer. Cost: ~0.28 µs per layer on the M5.
2. **Hash** — FNV-1a over the semantic content of the draw list (matrices, colours, sizes, blend
   modes, media generation, output size). Equal hash ⇒ identical pixels. This is the frame-cache
   key, so cache invalidation is dependency-exact by construction: an edit invalidates exactly
   the frames whose evaluated result changed — no dependency graph to maintain or get wrong.
3. **Composite (GPU)** — one render pass into an `RGBA16Float`, premultiplied, private-storage
   target. Each item is packed into a 128-byte instance (8 × float4; 112 bytes before Phase 4
   added the path edge ranges) in a shared-storage buffer (unified memory: the CPU writes, the
   GPU reads, no copy). Consecutive shapes are one instanced draw call; images batch per texture;
   a text layer is one draw call of glyph quads. Shapes are signed-distance functions (rounded
   box, ellipse, regular polygon, star, bezier path) with analytic anti-aliasing from the
   screen-space gradient, so there is no MSAA memory cost. Fill and centred stroke are evaluated
   in the same fragment.
4. **Blend** — on Apple GPUs the fragment shader reads the destination pixel (programmable
   blending / framebuffer fetch, which tile memory makes free). Normal, Add, Multiply, Screen,
   Overlay, Darken and Lighten all use the premultiplied separable formula in a single pass, with
   no ping-pong copies. Overlapping instances inside one draw call blend in submission order (the
   `render_stacking_and_blend_modes` test checks this). Non-Apple GPUs fall back to fixed-function
   premultiplied "normal".
5. **Masks** — evaluated analytically in the same fragment shader as the layer (rounded-box,
   ellipse or bezier-path SDF per mask, minus expansion, smoothstep over the feather, inverted,
   × opacity), combined in order as add (union), subtract, intersect or difference. Pipelines
   are specialised with two Metal function constants, `kHasMasks` (0) and `kHasPaths` (1), so
   plain layers run neither the mask loop nor the path-edge code (with the path branches compiled
   in, plain shapes measured 7.7% slower in the interleaved A/B; specialised, within ~1% of
   Phase 1). Text is drawn as many glyph quads, so a masked text layer goes offscreen and its
   masks are applied once to the assembled layer (`mask_apply_fragment`, fixed-function blend
   destination × source alpha).
6. **Effects and track mattes** — a layer with effects or a matte is rendered first into an
   offscreen RGBA16F region: its transformed bounds plus the reach of its effects (blur radius,
   shadow distance + softness, glow radius), limited to the frame grown by that reach, rounded
   up to 64 px so pooled textures fit from frame to frame. Opacity and blend mode are left for
   the final composite (effects see the full-opacity layer, as in most motion tools). The effect
   chain then runs in stack order:
   - Gaussian Blur: `MPSImageGaussianBlur` (σ = radius / 3, transparent edges), kernels cached by
     σ quantised to 1/8 px;
   - Drop Shadow: offset alpha × colour (compute) → MPS blur → layer *over* shadow;
   - Glow: soft-knee luminance threshold → MPS blur → added back with intensity;
   - Brightness & Contrast, Hue/Saturation (HSL), Fill: one per-pixel compute kernel each, on
     un-premultiplied colour.
   Spatial parameters are multiplied by `sqrt(|det(layer → target)|)`, so effects follow the
   layer's scale and look identical at full, half and quarter preview resolution (tested).
   Text layers size this region from their *animated* glyph boxes, so characters an animator
   moves stay inside it.
   A track matte renders its source layer (masks, effects and opacity included) into the same
   region and multiplies the layer by its alpha or luminance (optionally inverted).
   Scratch textures are recycled within the frame, since Metal orders passes on the same
   resources, so a chain of N effects needs about three textures. All instances, masks and path
   edges of a frame live in one sub-allocated shared buffer.
7. **Composite** — the main pass draws plain layers directly and offscreen results as textured
   quads, all bottom-to-top with their blend modes and opacity, in a single render pass.
8. **Present** — a full-screen triangle maps the frame into the `MTKView` drawable with the viewer
   zoom/pan, the composition background or a transparency grid, nearest sampling at ≥2× zoom.
   Composite and present are separate command buffers, so the GPU time measured for the
   composite (used for caching decisions and adaptive resolution) excludes presentation.

Nothing waits on the GPU in the app. The viewer allows 3 frames in flight; if the GPU is behind,
`drawInView:` reports `skipped` instead of blocking the main thread.

## Threads

| Work | Where |
|---|---|
| UI, edits, timeline evaluation, command encoding | main thread (sub-millisecond for typical comps) |
| GPU execution, completion handlers (stats, pool returns) | Metal's threads; renderer state is mutex-guarded |
| Image decode (ImageIO, EXIF orientation, colour conversion to sRGB) + upload + mipmaps | GCD user-initiated queue; the viewer is told when media is ready |
| Autosave | 30 s main-thread timer; serialise + atomic write takes a few ms |

Frames that reference media still decoding are drawn but not cached, and the viewer footer says
"Loading media…" until they are complete.

## Memory (24 GB unified)

The GPU shares RAM with macOS and every other app, so budgets are deliberately small:

- **Frame cache**: byte-budgeted LRU, default 10% of physical memory clamped to 256 MB–4 GB
  (2.4 GB here), settable from the Composition menu (512 MB–8 GB, persisted). Frames are
  composited in RGBA16F but cached as RGBA8 premultiplied copies (the viewer is 8-bit anyway), so
  half the memory: 8.3 MB per 1080p frame.
- **Admission (Smart policy)**: a frame is kept only if it contains effects/mattes or the
  measured GPU cost of compositing this composition at this size (moving average) is at least
  0.75 ms. Cheap frames are re-rendered on demand and don't consume cache. *All* and *Off* are
  also available. Cost estimates reset with the cache when a project is opened.
- **Background rendering**: during playback the viewer asks the engine to render up to 6 frames
  ahead into the cache (at most 2 prefetch command buffers in flight). While paused it fills the
  next 2 s a few frames per 50 ms tick. Both only render frames the policy would keep. The
  timeline's green bar shows cached frames of the current document state (it may under-report
  right after an edit, but never over-reports).
- **Adaptive resolution (Auto quality)**: during playback, if the composite exceeds 85% of the
  frame budget for 6 frames the preview resolution halves (down to quarter), and it is restored
  after 90 frames under 30%. The viewer footer states the reason. After a memory-pressure warning
  Auto stays at half resolution for 15 s.
- **Texture pool**: evicted frames return to a size-keyed pool (512 MB cap), so steady-state
  playback allocates no new textures. Instance buffers are pooled the same way.
- **Memory pressure**: a `DispatchSource` memory-pressure source calls
  `handleMemoryPressure:` — *warning* trims the cache to a quarter and empties the pools,
  *critical* drops every recreatable resource. Imported media is kept (it would only be decoded again).
- Media textures are private-storage RGBA8 with mipmaps; frame targets are private-storage
  RGBA16F, which on Apple GPUs also enables lossless framebuffer compression.
- **Glyph sheets**: R8 coverage textures within a 96 MB budget, oldest evicted first; frames in
  flight keep the sheets they use alive (see *Text*).

## Colour

Phase 1 composites in display-referred, sRGB-encoded values (the same default most motion tools
use): images are converted to sRGB on decode, colours are sRGB, blending happens on encoded
values, and the `MTKView` layer is tagged sRGB so macOS colour-manages it on P3/XDR displays.
The RGBA16F working buffer leaves room for a linear or wide-gamut working space later.

## Motion paths (spatial interpolation)

Position-like properties (layer position and anchor point, mask position) are *spatial*: each
keyframe has a mode. *Linear* keys give straight segments. *Auto* (the default for new keys)
derives handles along the line from the previous to the next key, a third as long as each
adjacent segment, which gives a smooth path that never overshoots on uneven spacing. *Bezier*
keys store explicit handles as offsets. A segment is a cubic bezier between the two keys'
handles. The temporal easing gives a fraction of the segment's *arc length* (48-sample table), so
linear timing moves at constant speed around curves. Segments whose handles lie on the chord take
the plain linear path. The viewer draws the path with the parent's transform at the current time.

## Text

- **Model**: a text layer stores the string, a font's PostScript name and alignment; Font Size,
  Tracking (1/1000 em), Line Height and Fill Colour are ordinary animatable properties. Lines
  are split on newlines (point text).
- **Layout** (`TextEngine.mm`): CoreText lays out each line once per style (string, font, size,
  tracking, line height, alignment) and the result is cached process-wide by a style key. The
  layout is in layer units, independent of zoom or preview resolution.
- **Bounds in the core**: MFCore is platform-free, so it can't call CoreText. It exposes a
  `setTextMeasurer` hook; `MetalRenderer::init` installs the CoreText measurer once
  (`std::call_once`), so evaluation, hit-testing and selection outlines use the real metrics.
  Without a renderer (pure core tests) a width estimate is used.
- **Glyph sheets**: every glyph of a layout is rasterised once into an 8-bit coverage sheet
  (shelf-packed, padded) at the layer's on-screen scale rounded *up* to a 2^(1/8) step. Glyphs
  are therefore always drawn at or below their raster size (never blurry), and animating scale or
  zoom re-rasterises only every ~9% of change. Sheets are keyed by style + scale step.
- **Drawing**: one instance per glyph, sampling the sheet, all in one draw call per layer. Each
  glyph gets its own transform and opacity from the layer's text animators.
- **Animators**: each has a range selector (Start, End, Offset in percent of the units; Amount)
  over characters, words or lines, with a shape — Square, Ramp Up, Ramp Down, Triangle, Round,
  Smooth — that turns a unit's position in the range into a weight 0–1 (`selectorWeight`). A
  unit's Position / Scale / Rotation / Opacity are blended by that weight, scaling and rotating
  about the character's baseline centre; several animators stack (offsets add, scales multiply). A typewriter is Start 0 → 100 with a Square shape.

## Bezier paths, bezier masks and Trim Paths

- **Model**: `BezierPath` = vertices (point, in-handle, out-handle, handles relative to the
  point) + closed flag, in layer space. Path shape layers and path masks share it. The pen tool
  puts the layer's position at the centre of what was drawn.
- **Flattening** (`flattenPath`, MFCore): adaptive cubic subdivision to a quarter of a *target*
  pixel (tolerance divided by the layer's on-screen scale), every frame at encode time. Edges go
  into the frame's shared buffer as float4 (x0, y0, x1, y1); an instance stores its fill edge
  range and stroke edge range in its last float4.
- **Shading**: the fragment computes the distance to every edge of its path and the winding
  number (non-zero rule) in the same loop, giving a signed distance and the same analytic AA as
  the built-in shapes. Strokes use the unsigned distance to the (possibly trimmed) stroke edges,
  so they have round caps and joins. Cost is covered pixels × edges, which is why many large
  paths are the slowest primitive in the benchmark; caching path coverage or binning edges per
  tile are the obvious next steps.
- **Trim Paths** (`trimmedEdges`): the flattened polyline is measured by arc length and only the
  edges between Start and End (+ Offset) are emitted for the stroke. Closed paths wrap around
  their start; open paths clamp. The fill always uses the whole closed outline.
- **Bezier masks**: the same signed distance, offset by the mask position, then the usual
  expansion / feather / mode / opacity of rectangle and ellipse masks.

## Graph editor easing

Temporal easing stays the cubic-bezier timing curve per segment (x = normalised time, y =
normalised progress). Each Bezier side of a key has an influence (`easeIn` / `easeOut`, the
handle's x reach) and, since Phase 4, a speed (`inSlope` / `outSlope`, the slope of the timing
curve at that key):

```
outgoing side:  x1 = easeOut,       y1 = easeOut × outSlope
incoming side:  x2 = 1 − easeIn,    y2 = 1 − easeIn × inSlope
```

Slope 0 is the old ease-to-a-stop, 1 is linear speed, >1 overshoots, <0 anticipates (clamped to
±20). Linear sides keep the diagonal (1/3, 2/3), so linear segments are exactly linear and every
pre-v4 key evaluates as before. The graph editor draws value over time by sampling the property
(curves can overshoot between keys); dragging a handle sets influence from its horizontal reach
and speed from its height (`Document::setKeyframeEase`, one undo step per drag). A key has one
ease for all components, so on a 2-D property the component that changes most carries the handles.

## Presets

A preset is JSON (`"format": "motionforge.preset"`, version 1): name, category, `tracks`,
`effects` and `animators`. `makePreset` captures a layer's animated properties with key times
relative to its earliest key. Position, anchor point and rotation tracks are *relative*: stored as
offsets from the layer's last key (category "Entrances", so the animation ends where the layer is)
or first key (everything else, so it starts there). `applyPreset` adds those offsets to each target
layer's current value, places the start at the playhead, re-creates effects and text animators
with their keys, and reports what didn't apply (a text preset on a shape layer is refused, not
half-applied). All targets change in one undo group. The 13 built-ins are built with the same
document calls as the app; user presets are `.mfpreset` files in
`~/Library/Application Support/MotionForge/Presets`.

## Node workspace

The node view is a projection of the layer stack, not a second compositor: each layer is a row
Source → Masks → Effects → output, and all outputs feed one Composite node whose slots are the
stacking order. Matte and parent links are drawn as wires into each layer's matte and parent
sockets. Dropping an output on a socket calls the same document edits as the inspector
(`setLayer(matte:)`, `setLayer(parent:)`), dropping it on a Composite slot calls `moveLayer`, so
the graph can never describe something the renderer doesn't do, and every change undoes like the
inspector's. Positions are computed from the stack each time, so nothing extra is saved.

## Selection and clipboard

The UI keeps a primary layer (shown in the inspector), a set of selected layers, and a set of
selected keyframes (layer + property reference + index). Multi-item operations go to the document
as one call: `moveKeyframes` (returns the keys' new indices so the selection follows them),
`removeKeyframes`, `setKeyframesInterpolation`, `removeLayers`, `duplicateLayers`. Each is one
undo step.

Copy/paste is JSON on the system pasteboard (type `com.motionforge.clipboard`):
- `motionforge.layers`: layers in stacking order plus the media they reference (path and size).
  `insertLayers` gives everything fresh ids, keeps parent and matte links inside the pasted set,
  drops links to anything else, and reuses media already in the project with the same path.
- `motionforge.keyframes`: tracks with times relative to the earliest key. A track names its
  property by key, its effect by type plus slot (the n-th Glow), or its mask by slot, so it can be
  pasted onto another layer with the same kind of property. With as many targets as copied layers,
  the n-th layer's tracks go to the n-th target.

## Undo

`Document` takes a snapshot of the project before each edit (projects hold no pixels, so a
snapshot is a few KB). This makes every operation undoable by construction, including ones added
later. `beginGroup`/`endGroup` make an interactive drag or a scrub one step; no-op edits record
nothing. History is capped at 500 steps.

## Project file (`.mfproj`, version 4)

Version 4 adds text layers (`"kind": "text"` with a `text` object and optional `animators`), path
shape layers and path masks (`"shape": "path"` with a `path` object: `closed` plus one
`[x, y, inX, inY, outX, outY]` array per vertex, handles relative to the point) and the graph
editor's `inSlope` / `outSlope` on keyframes (written only when non-zero). Older files have none
of these and load unchanged (abridged: every animator parameter is written):

```json
{"id": 21, "name": "Title", "kind": "text", "blend": "normal", "visible": true, "in": 0, "out": 10,
 "text": {"string": "MotionForge", "font": "AvenirNext-Heavy", "align": "center"},
 "animators": [{"id": 22, "name": "Opacity", "enabled": true, "shape": "square", "unit": "characters",
                "params": {"start": {"value": [0], "keyframes": [
                             {"t": 0, "v": [0], "in": "linear", "out": "linear"},
                             {"t": 1, "v": [100], "in": "linear", "out": "linear"}]},
                           "opacity": {"value": [0]}}}],
 "properties": {"fontSize": {"value": [120]}, "tracking": {"value": [0]}}}

{"id": 30, "name": "Shape 1", "kind": "shape", "shape": "path",
 "path": {"closed": true, "vertices": [[-100, 50, 0, 0, 0, 0], [100, 50, 0, 0, 0, 0], [0, -60, -40, 0, 40, 0]]},
 "properties": {"trimEnd": {"value": [60]}}}
```

Version 3 stores each spatial keyframe's `spatial` mode (`linear`, `auto`, `bezier`) and, for
Bezier keys, its handles `ti` / `to`; keys without it (versions 1–2) load as straight paths.
Version 2 added optional `masks`, `effects` and `trackMatte` keys per layer (shown below the main
example); version-1 files load unchanged. Effects from a newer build that this build doesn't know
are skipped instead of failing the load.

```json
"masks": [{"id": 12, "name": "Mask 1", "shape": "ellipse", "mode": "subtract", "inverted": false,
           "enabled": true, "properties": {"position": {"value": [0, 0]}, "size": {"value": [240, 240]},
                                           "feather": {"value": [20]}, "opacity": {"value": [100]}}}],
"effects": [{"id": 13, "type": "dropShadow", "enabled": true,
             "params": {"color": {"value": [0, 0, 0, 1]}, "opacity": {"value": [60]},
                        "direction": {"value": [135]}, "distance": {"value": [20]}, "softness": {"value": [30]}}}],
"trackMatte": {"layer": 7, "mode": "alphaInverted"}
```

Main structure:

```json
{
  "format": "motionforge.project",
  "version": 4,
  "nextId": 9,
  "activeComposition": 1,
  "assets": [{"id": 2, "kind": "image", "name": "photo.png",
              "relativePath": "media/photo.png", "absolutePath": "/Users/…/media/photo.png",
              "width": 1024, "height": 768}],
  "compositions": [{"id": 1, "name": "Main", "width": 1920, "height": 1080, "fps": 30,
    "duration": 10, "background": [0.07, 0.075, 0.09, 1],
    "layers": [{"id": 5, "name": "Star", "kind": "shape", "shape": "star", "blend": "normal",
      "visible": true, "fillEnabled": true, "strokeEnabled": false, "in": 0, "out": 10,
      "parent": 0, "asset": 0,
      "properties": {
        "position": {"value": [960, 540]},
        "rotation": {"value": [0], "keyframes": [
          {"t": 0, "v": [0], "in": "linear", "out": "bezier", "easeIn": 0.333, "easeOut": 0.333},
          {"t": 5, "v": [360], "in": "bezier", "out": "linear", "easeIn": 0.333, "easeOut": 0.333}]}
      }}]}]
}
```

- Layers are listed top of stack first. Times are seconds; the UI snaps edits to frames.
- On load, `relativePath` (resolved against the project's folder) wins over `absolutePath`, so a
  project folder can be moved or copied to another Mac. Unfound media is kept and flagged.
- Unknown keys are ignored; files newer than the supported `version` are refused with a clear
  message; migrations go in `deserializeProject`.
- Saves are atomic (write `.tmp`, then rename).

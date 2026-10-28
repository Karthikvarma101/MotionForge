# MotionForge architecture (Phases 1–3)

## Layers of the system

```
 SwiftUI / AppKit editor (Swift)          EditorModel, viewer, timeline, inspector
          │  Objective-C bridge            MFEngine.h — the only header Swift sees
          ▼
 MFRender (Objective-C++)                  MetalRenderer: pipelines, pools, frame cache, media
          │
          ▼
 MFCore (C++20, platform-free)             Document (edits/undo) → Evaluator (draw list + hash)
                                           ProjectIO (.mfproj), Json, LruCache, Math
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
   target. Each item is packed into a 112-byte instance in a shared-storage buffer (unified
   memory: the CPU writes, the GPU reads, no copy). Consecutive shapes are one instanced
   draw call; images batch per texture. Shapes are signed-distance functions (rounded box,
   ellipse, regular polygon, star) with analytic anti-aliasing from the screen-space gradient, so
   there is no MSAA memory cost. Fill and centred stroke are evaluated in the same fragment.
4. **Blend** — on Apple GPUs the fragment shader reads the destination pixel (programmable
   blending / framebuffer fetch, which tile memory makes free). Normal, Add, Multiply, Screen,
   Overlay, Darken and Lighten all use the premultiplied separable formula in a single pass, with
   no ping-pong copies. Overlapping instances inside one draw call blend in submission order (the
   `render_stacking_and_blend_modes` test checks this). Non-Apple GPUs fall back to fixed-function
   premultiplied "normal".
5. **Masks** — evaluated analytically in the same fragment shader as the layer (rounded-box or
   ellipse SDF per mask, minus expansion, smoothstep over the feather, inverted, × opacity),
   combined in order as add (union), subtract, intersect or difference. Layers without masks use
   pipelines specialised with a Metal function constant, so they don't run the mask code at all.
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
   A track matte renders its source layer (masks, effects and opacity included) into the same
   region and multiplies the layer by its alpha or luminance (optionally inverted).
   Scratch textures are recycled within the frame, since Metal orders passes on the same
   resources, so a chain of N effects needs about three textures. All instances and masks of a
   frame live in one sub-allocated shared buffer.
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

Known gap: cached frames at full RGBA16F are large (16.6 MB at 1080p). See the README.

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

## Project file (`.mfproj`, version 3)

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
  "version": 3,
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

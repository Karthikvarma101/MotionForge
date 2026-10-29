// MotionForge renderer — Metal Shading Language source.
//
// Compiled at runtime with -[MTLDevice newLibraryWithSource:] so the project builds with a stock
// Xcode install (the offline `metal` compiler is an optional download). MF_FBFETCH is defined
// to 1 on Apple-silicon GPUs, which read the destination pixel in the fragment shader
// ("programmable blending"): every blend mode then runs in one pass with no extra copies.
#pragma once

namespace mf::shaders {

inline constexpr const char* kSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

// Must match ItemGPU in MetalRenderer.mm (9 x float4 = 144 bytes).
struct Item {
    float4 m0;      // a b c d      (layer -> target pixel matrix, column-major 2x2)
    float4 m1;      // tx ty opacity kind
    float4 bounds;  // min.x min.y max.x max.y in layer space
    float4 fill;    // straight RGBA
    float4 stroke;  // straight RGBA
    float4 p0;      // strokeWidth roundness points innerRatio
    float4 p1;      // shapeType blendMode maskStart maskCount
    float4 p2;      // bezier paths: fillEdgeStart fillEdgeCount strokeEdgeStart strokeEdgeCount
    float4 m3;      // 3D layers: perspective row gx gy w (target = (m·p + t) / (gx·x + gy·y + w)); 0 0 1 in 2D
};

// Must match MaskGPU in MetalRenderer.mm.
struct Mask {
    float4 a;       // centre.xy halfSize.xy (layer space)
    float4 b;       // roundness feather expansion opacity
    float4 c;       // shape(0 rect, 1 ellipse, 2 path) mode(add, subtract, intersect, difference) inverted 0
};                  // path masks: a.xy = offset, a.z = edgeStart, a.w = edgeCount

// Pipelines are specialised on this at build time, so layers without masks pay nothing for them.
constant bool kHasMasks [[function_constant(0)]];
// Bezier path shapes and path masks are specialised the same way.
constant bool kHasPaths [[function_constant(1)]];

struct FrameUniforms {
    float2 targetSize;
    float2 pad;
};

struct VOut {
    float4 position [[position]];
    float2 local;
    uint item [[flat]];
};

vertex VOut item_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        constant FrameUniforms& fu [[buffer(0)]],
                        const device Item* items [[buffer(1)]]) {
    const Item it = items[iid];
    const float2x2 m = float2x2(it.m0.xy, it.m0.zw);
    const float det = abs(it.m0.x * it.m0.w - it.m0.y * it.m0.z);
    const float px = rsqrt(max(det, 1e-12f));          // ~one target pixel in layer units
    const float pad = it.p0.x * 0.5f + 2.0f * px;       // half stroke + anti-aliasing margin
    const float2 mn = it.bounds.xy - pad;
    const float2 mx = it.bounds.zw + pad;
    const float2 corner = float2((vid & 1) ? mx.x : mn.x, (vid & 2) ? mx.y : mn.y);
    const float w = max(it.m3.x * corner.x + it.m3.y * corner.y + it.m3.z, 1e-6f);
    const float2 p = (m * corner + it.m1.xy) / w;
    VOut o;
    // A homogeneous position (× w) makes the rasterizer interpolate `local` perspective-correctly,
    // so 3D layers keep exact shapes, masks and image sampling.
    o.position = float4((p.x / fu.targetSize.x * 2.0f - 1.0f) * w, (1.0f - p.y / fu.targetSize.y * 2.0f) * w, 0.0f, w);
    o.local = corner;
    o.item = iid;
    return o;
}

// ---- signed distance functions (negative inside) -------------------------------------------

static float sdRoundBox(float2 p, float2 b, float r) {
    const float2 q = abs(p) - b + r;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
}

static float sdEllipse(float2 p, float2 r) {
    r = max(r, float2(1e-4f));
    const float k0 = length(p / r);
    const float k1 = length(p / (r * r));
    return k1 > 0.0f ? k0 * (k0 - 1.0f) / k1 : -min(r.x, r.y);
}

static float gmod(float x, float y) { return x - y * floor(x / y); }

// Star with n points, outer radius R and inner radius ri, first point straight up.
// A regular polygon is the same shape with ri = R * cos(pi / n).
static float sdStar(float2 p, float R, float n, float ri) {
    const float an = M_PI_F / n;
    const float bn = gmod(atan2(p.x, -p.y) + an, 2.0f * an) - an;  // 0 on the vertex rays
    const float len = length(p);
    float2 q = len * float2(cos(bn), abs(sin(bn)));
    const float2 a = float2(R, 0.0f);
    const float2 b = ri * float2(cos(an), sin(an));
    const float2 pa = q - a, ba = b - a;
    const float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0f, 1.0f);
    const float d = length(pa - ba * h);
    const float side = ba.x * pa.y - ba.y * pa.x;   // > 0 on the centre's side of the edge
    return side > 0.0f ? -d : d;
}

// Analytic anti-aliasing: a one-pixel linear ramp across the edge. The Euclidean screen-space
// gradient (not fwidth's L1 norm) keeps diagonal edges and corners as sharp as straight ones.
// Bezier paths arrive flattened: edges are (x0, y0, x1, y1) in layer space.
static float pathDistance(const device float4* e, uint start, uint count, float2 p) {
    float d = 1e20f;
    for (uint i = 0; i < count; ++i) {
        const float2 a = e[start + i].xy, b = e[start + i].zw;
        const float2 pa = p - a, ba = b - a;
        const float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-12f), 0.0f, 1.0f);
        d = min(d, length(pa - ba * h));
    }
    return d;
}

// Signed distance to a closed polygon, negative inside (non-zero winding rule).
static float pathSignedDistance(const device float4* e, uint start, uint count, float2 p) {
    float d = 1e20f;
    int wind = 0;
    for (uint i = 0; i < count; ++i) {
        const float2 a = e[start + i].xy, b = e[start + i].zw;
        const float2 pa = p - a, ba = b - a;
        const float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-12f), 0.0f, 1.0f);
        d = min(d, length(pa - ba * h));
        const float side = ba.x * pa.y - ba.y * pa.x;
        if (a.y <= p.y) {
            if (b.y > p.y && side > 0.0f) ++wind;
        } else if (b.y <= p.y && side < 0.0f) {
            --wind;
        }
    }
    return wind != 0 ? -d : d;
}

static float coverage(float d) {
    const float w = max(length(float2(dfdx(d), dfdy(d))), 1e-5f);
    return saturate(0.5f - d / w);
}

// ---- blending (premultiplied, separable modes) ----------------------------------------------

static float3 blendRGB(float3 cs, float3 cd, int mode) {
    switch (mode) {
        case 1: return min(cs + cd, 1.0f);                                      // add
        case 2: return cs * cd;                                                 // multiply
        case 3: return cs + cd - cs * cd;                                       // screen
        case 4: return select(1.0f - 2.0f * (1.0f - cs) * (1.0f - cd), 2.0f * cs * cd, cd <= 0.5f); // overlay
        case 5: return min(cs, cd);                                             // darken
        case 6: return max(cs, cd);                                             // lighten
        default: return cs;                                                     // normal
    }
}

static float4 blendOver(float4 src, float4 dst, int mode) {
    if (mode == 0) return src + dst * (1.0f - src.a);
    const float sa = src.a, da = dst.a;
    const float3 cs = sa > 0.0f ? src.rgb / sa : float3(0.0f);
    const float3 cd = da > 0.0f ? dst.rgb / da : float3(0.0f);
    const float3 co = src.rgb * (1.0f - da) + dst.rgb * (1.0f - sa) + sa * da * blendRGB(cs, cd, mode);
    return float4(co, sa + da * (1.0f - sa));
}

static float shapeDistance(const Item it, float2 local, const device float4* edges) {
    if (kHasPaths && int(it.p1.x) == 4) return pathSignedDistance(edges, uint(it.p2.x), uint(it.p2.y), local);
    const float2 hs = (it.bounds.zw - it.bounds.xy) * 0.5f;
    const float2 p = local - (it.bounds.zw + it.bounds.xy) * 0.5f;
    const int type = int(it.p1.x);
    if (type == 0) return sdRoundBox(p, hs, min(it.p0.y, min(hs.x, hs.y)));
    if (type == 1) return sdEllipse(p, hs);
    const float R = max(min(hs.x, hs.y), 1e-4f);
    const float2 q = p * (R / max(hs, float2(1e-4f)));    // stretch to fill a non-square box
    const float n = max(it.p0.z, 3.0f);
    const float r = min(it.p0.y, R * 0.5f);               // rounding that keeps the outer size
    const float k = (R - r) / R;
    const float ri = (type == 2) ? R * cos(M_PI_F / n) : R * it.p0.w;
    return sdStar(q, R * k, n, ri * k) - r;
}

// Combined coverage of a layer's masks at `local` (1 = keep). The first mask decides the
// starting state: an Add mask starts from nothing, any other mode starts from the full layer.
static float maskFactor(const device Mask* masks, const device float4* edges, const Item it, float2 local) {
    if (!kHasMasks) return 1.0f;
    const uint count = uint(it.p1.w);
    if (count == 0) return 1.0f;
    const uint start = uint(it.p1.z);
    float m = int(masks[start].c.y) == 0 ? 0.0f : 1.0f;
    for (uint i = 0; i < count; ++i) {
        const Mask k = masks[start + i];
        const float2 hs = max(k.a.zw, float2(1e-4f));
        const float2 p = local - k.a.xy;
        const int shape = int(k.c.x);
        float d = (kHasPaths && shape == 2) ? pathSignedDistance(edges, uint(k.a.z), uint(k.a.w), local - k.a.xy)
                  : shape == 1 ? sdEllipse(p, hs)
                               : sdRoundBox(p, hs, min(k.b.x, min(hs.x, hs.y)));
        d -= k.b.z;                                                        // expansion
        float c = k.b.y > 0.0f ? 1.0f - smoothstep(-0.5f * k.b.y, 0.5f * k.b.y, d) : coverage(d);
        if (k.c.z > 0.5f) c = 1.0f - c;                                    // inverted
        c *= k.b.w;                                                        // mask opacity
        const int mode = int(k.c.y);
        if (mode == 0) m = m + c - m * c;                                  // add (union)
        else if (mode == 1) m = m * (1.0f - c);                            // subtract
        else if (mode == 2) m = m * c;                                     // intersect
        else m = m + c - 2.0f * m * c;                                     // difference
    }
    return m;
}

static float4 shapeColor(const Item it, float2 local, const device float4* edges) {
    const float d = shapeDistance(it, local, edges);
    const float sw = it.p0.x;
    const float fc = coverage(d);
    float sc = 0.0f;
    if (sw > 0.0f) {
        // Paths stroke their own (possibly trimmed) edge list; primitives stroke the outline.
        const bool path = kHasPaths && int(it.p1.x) == 4;
        const float sd = path ? (it.p2.w > 0.0f ? pathDistance(edges, uint(it.p2.z), uint(it.p2.w), local) : 1e20f) : abs(d);
        sc = coverage(sd - sw * 0.5f);
    }
    const float4 f = float4(it.fill.rgb * it.fill.a, it.fill.a) * fc;
    const float4 s = float4(it.stroke.rgb * it.stroke.a, it.stroke.a) * sc;
    return (s + f * (1.0f - s.a)) * it.m1.z;
}

// Glyphs: 8-bit coverage from the glyph sheet (R fill, G stroke); the uv rectangle travels in
// `stroke`, the stroke colour in p2 and "stroke over fill" in p0.z.
static float4 glyphColor(const Item it, float2 local, texture2d<float> tex, sampler smp) {
    const float2 t = saturate((local - it.bounds.xy) / max(it.bounds.zw - it.bounds.xy, float2(1e-6f)));
    const float2 c = tex.sample(smp, mix(it.stroke.xy, it.stroke.zw, t)).rg;
    const float4 f = float4(it.fill.rgb * it.fill.a, it.fill.a) * c.x;
    const float4 s = float4(it.p2.rgb * it.p2.a, it.p2.a) * c.y;
    return (it.p0.z > 0.5f ? s + f * (1.0f - s.a) : f + s * (1.0f - f.a)) * it.m1.z;
}

static float4 imageColor(const Item it, float2 local, texture2d<float> tex, sampler smp) {
    const float2 size = it.bounds.zw - it.bounds.xy;
    const float2 hs = size * 0.5f;
    const float d = sdRoundBox(local - (it.bounds.xy + hs), hs, 0.0f);
    const float2 uv = clamp((local - it.bounds.xy) / size, 0.0f, 1.0f);
    return tex.sample(smp, uv) * coverage(d) * it.m1.z;
}

#if MF_FBFETCH
fragment float4 shape_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               const device Mask* masks [[buffer(2)]], const device float4* edges [[buffer(3)]],
                               float4 dst [[color(0)]]) {
    const Item it = items[in.item];
    return blendOver(shapeColor(it, in.local, edges) * maskFactor(masks, edges, it, in.local), dst, int(it.p1.y));
}
fragment float4 image_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               const device Mask* masks [[buffer(2)]], const device float4* edges [[buffer(3)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]],
                               float4 dst [[color(0)]]) {
    const Item it = items[in.item];
    return blendOver(imageColor(it, in.local, tex, smp) * maskFactor(masks, edges, it, in.local), dst, int(it.p1.y));
}
fragment float4 glyph_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]],
                               float4 dst [[color(0)]]) {
    const Item it = items[in.item];
    return blendOver(glyphColor(it, in.local, tex, smp), dst, int(it.p1.y));
}
#else
// Fixed-function fallback (non-Apple GPUs): premultiplied "normal" only.
fragment float4 shape_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               const device Mask* masks [[buffer(2)]], const device float4* edges [[buffer(3)]]) {
    const Item it = items[in.item];
    return shapeColor(it, in.local, edges) * maskFactor(masks, edges, it, in.local);
}
fragment float4 image_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               const device Mask* masks [[buffer(2)]], const device float4* edges [[buffer(3)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    const Item it = items[in.item];
    return imageColor(it, in.local, tex, smp) * maskFactor(masks, edges, it, in.local);
}
fragment float4 glyph_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    return glyphColor(items[in.item], in.local, tex, smp);
}
#endif

// Masks for layers drawn as many pieces (text): multiplies what is already there by the mask,
// through fixed-function blending (destination x source alpha).
fragment float4 mask_apply_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                                    const device Mask* masks [[buffer(2)]], const device float4* edges [[buffer(3)]]) {
    return float4(maskFactor(masks, edges, items[in.item], in.local));
}

// ---- viewer presentation --------------------------------------------------------------------

struct PresentUniforms {
    float2 compOrigin;   // drawable pixels
    float2 compSize;     // drawable pixels
    float4 background;   // composition background (straight)
    float4 viewerBg;
    float checker;       // 1 = transparency grid instead of the background colour
    float checkerSize;
    float2 pad;
};

struct PresentVOut {
    float4 position [[position]];
};

vertex PresentVOut present_vertex(uint vid [[vertex_id]]) {
    const float2 p = float2((vid << 1) & 2, vid & 2);   // full-screen triangle
    PresentVOut o;
    o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    return o;
}

fragment float4 present_fragment(PresentVOut in [[stage_in]], constant PresentUniforms& u [[buffer(0)]],
                                 texture2d<float> frame [[texture(0)]], sampler smp [[sampler(0)]]) {
    const float2 px = in.position.xy;
    const float2 uv = (px - u.compOrigin) / u.compSize;
    if (any(uv < 0.0f) || any(uv > 1.0f)) return u.viewerBg;
    const float4 c = frame.sample(smp, uv);
    float3 bg = u.background.rgb;
    if (u.checker > 0.5f) {
        const float2 cell = floor((px - u.compOrigin) / u.checkerSize);
        bg = float3(gmod(cell.x + cell.y, 2.0f) > 0.5f ? 0.40f : 0.30f);
    }
    return float4(c.rgb + bg * (1.0f - c.a), 1.0f);
}

// ---- effect kernels (compute) ---------------------------------------------------------------
// All images are premultiplied RGBA16F. Each kernel writes a fresh texture.

struct FxParams {
    float4 a;
    float4 b;
    float4 c;
    float4 d;
};

static float luma(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }
static float3 unpremul(float4 c) { return c.a > 0.0f ? c.rgb / c.a : float3(0.0f); }
static bool outside(uint2 gid, texture2d<float, access::write> t) { return gid.x >= t.get_width() || gid.y >= t.get_height(); }

// Shadow source: colour * opacity * alpha, read at an offset (a = colour, b.xy = offset px, b.z = opacity).
kernel void fx_shadow(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    constexpr sampler s(coord::pixel, address::clamp_to_zero, filter::linear);
    const float a = src.sample(s, float2(gid) + 0.5f - p.b.xy).a * p.b.z * p.a.a;
    dst.write(float4(p.a.rgb * a, a), gid);
}

// dst = top over bottom (premultiplied)
kernel void fx_over(texture2d<float, access::read> top [[texture(0)]],
                    texture2d<float, access::read> bottom [[texture(1)]],
                    texture2d<float, access::write> dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    const float4 t = top.read(gid), b = bottom.read(gid);
    dst.write(t + b * (1.0f - t.a), gid);
}

// Glow bright pass: keeps pixels whose luminance is above the threshold (a.x, 0–1), soft knee.
kernel void fx_bright(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    const float4 c = src.read(gid);
    const float w = smoothstep(p.a.x - 0.08f, p.a.x + 0.08f, luma(unpremul(c)));
    dst.write(c * w, gid);
}

// dst = layer + glow * intensity (a.x), alpha accumulated like "over".
kernel void fx_glow(texture2d<float, access::read> layer [[texture(0)]],
                    texture2d<float, access::read> glow [[texture(1)]],
                    texture2d<float, access::write> dst [[texture(2)]],
                    constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    const float4 l = layer.read(gid), g = glow.read(gid) * p.a.x;
    const float a = saturate(l.a + g.a * (1.0f - l.a));
    dst.write(float4(min(l.rgb + g.rgb, float3(a)), a), gid);
}

static float3 rgb2hsl(float3 c) {
    const float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    const float l = 0.5f * (mx + mn), d = mx - mn;
    if (d < 1e-6f) return float3(0.0f, 0.0f, l);
    const float s = l > 0.5f ? d / (2.0f - mx - mn) : d / (mx + mn);
    float h;
    if (mx == c.r) h = (c.g - c.b) / d + (c.g < c.b ? 6.0f : 0.0f);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0f;
    else h = (c.r - c.g) / d + 4.0f;
    return float3(h / 6.0f, s, l);
}

static float hue2rgb(float p, float q, float t) {
    t = t - floor(t);
    if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
    if (t < 0.5f) return q;
    if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
    return p;
}

static float3 hsl2rgb(float3 hsl) {
    if (hsl.y < 1e-6f) return float3(hsl.z);
    const float q = hsl.z < 0.5f ? hsl.z * (1.0f + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
    const float p = 2.0f * hsl.z - q;
    return float3(hue2rgb(p, q, hsl.x + 1.0f / 3.0f), hue2rgb(p, q, hsl.x), hue2rgb(p, q, hsl.x - 1.0f / 3.0f));
}

// Per-pixel colour operations. d.x selects: 0 brightness/contrast (a.x, a.y in −100…100),
// 1 hue/saturation/lightness (a.x degrees, a.y, a.z in −100…100), 2 fill (a = colour, b.x = amount).
kernel void fx_color(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    const float4 s = src.read(gid);
    const int op = int(p.d.x);
    if (op == 3) { dst.write(s * p.b.x, gid); return; }  // opacity
    if (s.a <= 0.0f) { dst.write(float4(0.0f), gid); return; }
    float3 c = s.rgb / s.a;
    if (op == 0) {
        const float k = p.a.y >= 0.0f ? 1.0f / (1.0f - 0.009f * p.a.y) : 1.0f + p.a.y / 100.0f;
        c = (c - 0.5f) * k + 0.5f + p.a.x / 200.0f;
    } else if (op == 1) {
        float3 hsl = rgb2hsl(saturate(c));
        hsl.x += p.a.x / 360.0f;
        hsl.y = saturate(hsl.y * (1.0f + p.a.y / 100.0f));
        c = hsl2rgb(hsl);
        const float l = p.a.z / 100.0f;
        c = l >= 0.0f ? mix(c, float3(1.0f), l) : c * (1.0f + l);
    } else {
        c = mix(c, p.a.rgb, saturate(p.b.x * p.a.a));
    }
    dst.write(float4(saturate(c) * s.a, s.a), gid);
}

// Track matte: dst = layer * factor(matte). a.x = mode (1 alpha, 2 alpha inverted, 3 luma, 4 luma inverted).
kernel void fx_matte(texture2d<float, access::read> layer [[texture(0)]],
                     texture2d<float, access::read> matte [[texture(1)]],
                     texture2d<float, access::write> dst [[texture(2)]],
                     constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    const float4 m = matte.read(gid);
    const int mode = int(p.a.x);
    float f = (mode <= 2) ? m.a : saturate(luma(m.rgb));   // luma of the matte over black
    if (mode == 2 || mode == 4) f = 1.0f - f;
    dst.write(layer.read(gid) * f, gid);
}

// Gradient Ramp: a.xy start, a.zw end (region pixels); b, c straight colours; d.x radial, d.y blend
// with the original (0-1). Keeps the layer's alpha.
kernel void fx_ramp(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    const float4 o = src.read(gid);
    const float2 q = float2(gid) + 0.5f, s = p.a.xy, e = p.a.zw, se = e - s;
    const float len2 = max(dot(se, se), 1e-6f);
    const float t = saturate(p.d.x > 0.5f ? length(q - s) / sqrt(len2) : dot(q - s, se) / len2);
    const float3 rgb = mix(p.b.rgb, p.c.rgb, t);
    const float4 ramp = float4(rgb * o.a, o.a);
    dst.write(mix(ramp, o, p.d.y), gid);
}

// Export: running average of motion-blur subframes. a.x = weight, a.y = 1 for the first one.
kernel void fx_accum(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::read_write> acc [[texture(1)]],
                     constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= acc.get_width() || gid.y >= acc.get_height()) return;
    const float4 s = src.read(gid) * p.a.x;
    acc.write(p.a.y > 0.5f ? s : acc.read(gid) + s, gid);
}

// Export: premultiplied frame -> 8-bit BGRA. b.x = 0: over the background colour a.rgb (opaque
// video); b.x = 1: straight alpha (ProRes 4444).
kernel void to_bgra8(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant FxParams& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    float4 c = src.read(gid);
    if (p.b.x > 0.5f) {
        c.rgb = c.a > 0.0f ? c.rgb / c.a : float3(0.0f);
    } else {
        c.rgb += p.a.rgb * (1.0f - c.a);
        c.a = 1.0f;
    }
    dst.write(saturate(c), gid);
}

// Frame-cache copy: RGBA16F -> RGBA8 (premultiplied). Half the memory, same 8-bit display output.
kernel void to_rgba8(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (outside(gid, dst)) return;
    dst.write(saturate(src.read(gid)), gid);
}
)MSL";

}  // namespace mf::shaders

// Phase 1 shader source (as benchmarked on 2026-10-28), reconstructed from Shaders.hpp by removing
// the Phase 3 additions (mask struct + function, function constant, mask bindings, effect kernels).
// Used only by benchmarks/ab/shader_ab.mm.
#pragma once
namespace phase1 {
inline constexpr const char* kSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

// Must match ItemGPU in MetalRenderer.mm (7 x float4 = 112 bytes).
struct Item {
    float4 m0;      // a b c d      (layer -> target pixel matrix, column-major 2x2)
    float4 m1;      // tx ty opacity kind
    float4 bounds;  // min.x min.y max.x max.y in layer space
    float4 fill;    // straight RGBA
    float4 stroke;  // straight RGBA
    float4 p0;      // strokeWidth roundness points innerRatio
    float4 p1;      // shapeType blendMode maskStart maskCount
};

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
    const float2 p = m * corner + it.m1.xy;
    VOut o;
    o.position = float4(p.x / fu.targetSize.x * 2.0f - 1.0f, 1.0f - p.y / fu.targetSize.y * 2.0f, 0.0f, 1.0f);
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

static float shapeDistance(const Item it, float2 local) {
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

static float4 shapeColor(const Item it, float2 local) {
    const float d = shapeDistance(it, local);
    const float sw = it.p0.x;
    const float fc = coverage(d);
    const float sc = sw > 0.0f ? coverage(abs(d) - sw * 0.5f) : 0.0f;
    const float4 f = float4(it.fill.rgb * it.fill.a, it.fill.a) * fc;
    const float4 s = float4(it.stroke.rgb * it.stroke.a, it.stroke.a) * sc;
    return (s + f * (1.0f - s.a)) * it.m1.z;
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
                               float4 dst [[color(0)]]) {
    const Item it = items[in.item];
    return blendOver(shapeColor(it, in.local), dst, int(it.p1.y));
}
fragment float4 image_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]],
                               float4 dst [[color(0)]]) {
    const Item it = items[in.item];
    return blendOver(imageColor(it, in.local, tex, smp), dst, int(it.p1.y));
}
#else
// Fixed-function fallback (non-Apple GPUs): premultiplied "normal" only.
fragment float4 shape_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]]) {
    return shapeColor(items[in.item], in.local);
}
fragment float4 image_fragment(VOut in [[stage_in]], const device Item* items [[buffer(1)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    return imageColor(items[in.item], in.local, tex, smp);
}
#endif

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

)MSL";
}

// MotionForge core — 2D affine math used by evaluation, hit testing and the renderer.
#pragma once

#include <cmath>
#include <numbers>

namespace mf {

struct Vec2 {
    double x = 0, y = 0;
    constexpr Vec2 operator+(Vec2 o) const { return {x + o.x, y + o.y}; }
    constexpr Vec2 operator-(Vec2 o) const { return {x - o.x, y - o.y}; }
    constexpr Vec2 operator*(double s) const { return {x * s, y * s}; }
    constexpr bool operator==(const Vec2&) const = default;
};

// Column-vector affine transform:
//   x' = a*x + c*y + tx
//   y' = b*x + d*y + ty
// Composition coordinates are pixels with the origin top-left and +y down, so a
// positive rotation turns clockwise on screen (same convention as most motion tools).
struct Affine {
    double a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;

    static constexpr Affine identity() { return {}; }
    static constexpr Affine translate(double x, double y) { return {1, 0, 0, 1, x, y}; }
    static constexpr Affine scale(double sx, double sy) { return {sx, 0, 0, sy, 0, 0}; }
    static Affine rotateDegrees(double deg) {
        const double r = deg * std::numbers::pi / 180.0;
        const double cs = std::cos(r), sn = std::sin(r);
        return {cs, sn, -sn, cs, 0, 0};
    }

    // (this * o)(p) == this(o(p)) — o is applied first.
    constexpr Affine operator*(const Affine& o) const {
        return {a * o.a + c * o.b,       b * o.a + d * o.b,
                a * o.c + c * o.d,       b * o.c + d * o.d,
                a * o.tx + c * o.ty + tx, b * o.tx + d * o.ty + ty};
    }

    constexpr Vec2 apply(Vec2 p) const { return {a * p.x + c * p.y + tx, b * p.x + d * p.y + ty}; }
    constexpr double determinant() const { return a * d - b * c; }

    // Returns false (and leaves `out` untouched) for degenerate matrices, e.g. scale 0%.
    bool inverse(Affine& out) const {
        const double det = determinant();
        if (std::abs(det) < 1e-12) return false;
        const double id = 1.0 / det;
        out = {d * id, -b * id, -c * id, a * id, (c * ty - d * tx) * id, (b * tx - a * ty) * id};
        return true;
    }
};

}  // namespace mf

// MotionForge core — 2D affine math used by evaluation, hit testing and the renderer.
#pragma once

#include <cmath>
#include <numbers>
#include <utility>

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

struct Vec3 {
    double x = 0, y = 0, z = 0;
    constexpr bool operator==(const Vec3&) const = default;
};

// 3D layers and cameras: a row-major 4x4 acting on column vectors (x, y, z, 1), same axes as the
// composition (+x right, +y down) with +z pointing into the screen, away from the viewer.
struct Mat4 {
    double m[4][4] = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}};

    static Mat4 identity() { return {}; }
    static Mat4 translate(double x, double y, double z) {
        Mat4 r;
        r.m[0][3] = x;
        r.m[1][3] = y;
        r.m[2][3] = z;
        return r;
    }
    static Mat4 scale(double x, double y, double z) {
        Mat4 r;
        r.m[0][0] = x;
        r.m[1][1] = y;
        r.m[2][2] = z;
        return r;
    }
    // Positive angles follow the 2D convention: Z turns +x towards +y (clockwise on screen), X tips
    // the top (−y) away from the viewer, Y swings the right side (+x) towards the viewer.
    static Mat4 rotateX(double deg) {
        const double r = deg * std::numbers::pi / 180.0, c = std::cos(r), s = std::sin(r);
        Mat4 o;
        o.m[1][1] = c; o.m[1][2] = -s;
        o.m[2][1] = s; o.m[2][2] = c;
        return o;
    }
    static Mat4 rotateY(double deg) {
        const double r = deg * std::numbers::pi / 180.0, c = std::cos(r), s = std::sin(r);
        Mat4 o;
        o.m[0][0] = c; o.m[0][2] = s;
        o.m[2][0] = -s; o.m[2][2] = c;
        return o;
    }
    static Mat4 rotateZ(double deg) {
        const double r = deg * std::numbers::pi / 180.0, c = std::cos(r), s = std::sin(r);
        Mat4 o;
        o.m[0][0] = c; o.m[0][1] = -s;
        o.m[1][0] = s; o.m[1][1] = c;
        return o;
    }
    // A 2D transform as a 3D one (it leaves z alone).
    static Mat4 fromAffine(const Affine& a) {
        Mat4 o;
        o.m[0][0] = a.a; o.m[0][1] = a.c; o.m[0][3] = a.tx;
        o.m[1][0] = a.b; o.m[1][1] = a.d; o.m[1][3] = a.ty;
        return o;
    }

    Mat4 operator*(const Mat4& o) const {  // o is applied first
        Mat4 r;
        for (int i = 0; i < 4; ++i)
            for (int j = 0; j < 4; ++j) {
                double v = 0;
                for (int k = 0; k < 4; ++k) v += m[i][k] * o.m[k][j];
                r.m[i][j] = v;
            }
        return r;
    }
    Vec3 apply(Vec3 p) const {
        const double w = m[3][0] * p.x + m[3][1] * p.y + m[3][2] * p.z + m[3][3];
        const double iw = std::abs(w) > 1e-15 ? 1.0 / w : 1.0;
        return {(m[0][0] * p.x + m[0][1] * p.y + m[0][2] * p.z + m[0][3]) * iw,
                (m[1][0] * p.x + m[1][1] * p.y + m[1][2] * p.z + m[1][3]) * iw,
                (m[2][0] * p.x + m[2][1] * p.y + m[2][2] * p.z + m[2][3]) * iw};
    }
    // General inverse (Gauss-Jordan); false for singular matrices.
    bool inverse(Mat4& out) const {
        double a[4][8];
        for (int i = 0; i < 4; ++i)
            for (int j = 0; j < 8; ++j) a[i][j] = j < 4 ? m[i][j] : (j - 4 == i ? 1 : 0);
        for (int c = 0; c < 4; ++c) {
            int piv = c;
            for (int r = c + 1; r < 4; ++r)
                if (std::abs(a[r][c]) > std::abs(a[piv][c])) piv = r;
            if (std::abs(a[piv][c]) < 1e-12) return false;
            if (piv != c)
                for (int j = 0; j < 8; ++j) std::swap(a[c][j], a[piv][j]);
            const double d = a[c][c];
            for (int j = 0; j < 8; ++j) a[c][j] /= d;
            for (int r = 0; r < 4; ++r) {
                if (r == c || a[r][c] == 0) continue;
                const double f = a[r][c];
                for (int j = 0; j < 8; ++j) a[r][j] -= f * a[c][j];
            }
        }
        for (int i = 0; i < 4; ++i)
            for (int j = 0; j < 4; ++j) out.m[i][j] = a[i][j + 4];
        return true;
    }
};

}  // namespace mf

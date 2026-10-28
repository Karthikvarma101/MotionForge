// MotionForge renderer — text layout (CoreText) and glyph rasterisation for the GPU.
//
// Layout is device-independent and cached by style; the core's text measurer uses it, so bounds,
// hit-testing and selection outlines match what is drawn. Glyph *sheets* are per layout and per
// raster scale: every glyph of the text rasterised once (8-bit coverage) at the size it is shown,
// rounded up to 2^(1/8) steps, so animating scale or zoom re-rasterises only occasionally and
// glyphs are always drawn at or below their raster size (crisp, never upsampled).
#pragma once

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "mf/Evaluator.hpp"

namespace mf {

struct GlyphInfo {
    Vec2 origin;      // baseline origin in layer space (y down)
    CGRect rect;      // glyph bounding box at layout size, CoreText convention (y up from the baseline)
    CGGlyph glyph = 0;
    int font = 0;     // index into TextLayout::fonts
    int character = 0, word = 0, line = 0;
};

struct TextLayout {
    std::vector<GlyphInfo> glyphs;
    std::vector<std::shared_ptr<const void>> fonts;  // CTFontRef, released with the layout
    int characters = 0, words = 0, lines = 0;        // selector units
    Vec2 mn, mx;                                     // layout box (alignment point x = 0, first baseline y = 0)
};

struct SheetRect {
    bool empty = true;
    float u0 = 0, v0 = 0, u1 = 0, v1 = 0;  // in the sheet texture
    Vec2 qmin, qmax;                       // quad relative to the glyph origin, layer units, y down
};

struct GlyphSheet {
    id<MTLTexture> texture = nil;  // R8 coverage, or RG8 (fill, stroke) for stroked text
    std::vector<SheetRect> rects;  // one per TextLayout glyph
    double scale = 1;              // raster pixels per layer unit
    size_t bytes = 0;
};

// Process-wide layout cache (thread-safe).
std::shared_ptr<const TextLayout> layoutText(const TextStyle& style);
std::string textStyleKey(const TextStyle& style);

class GlyphSheetCache {
public:
    explicit GlyphSheetCache(id<MTLDevice> device) : device_(device) {}
    // Sheet for `layout` at no less than `pixelsPerUnit` (the layer's on-screen scale). With a
    // stroke width (layer units, centred on the outline) the G channel holds the stroke.
    std::shared_ptr<const GlyphSheet> sheet(const TextStyle& style, const TextLayout& layout, double pixelsPerUnit,
                                            double strokeWidth = 0);
    void clear();
    size_t bytes() const;

private:
    id<MTLDevice> device_;
    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::shared_ptr<const GlyphSheet>> sheets_;
    std::vector<std::string> order_;  // insertion order, oldest first
    size_t bytes_ = 0;
    static constexpr size_t kBudget = 96ull << 20;
};

}  // namespace mf

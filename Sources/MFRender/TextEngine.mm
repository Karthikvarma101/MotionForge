#import "TextEngine.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>

namespace mf {

namespace {

struct LayoutCache {
    std::mutex mutex;
    std::unordered_map<std::string, std::shared_ptr<const TextLayout>> map;
};

LayoutCache& layouts() {
    static LayoutCache c;
    return c;
}

// Width (in em) Unicode defines for the fixed-width spaces, 0 for anything else.
double fixedSpaceEm(unichar c) {
    switch (c) {
        case 0x2000: case 0x2002: return 0.5;        // en quad / en space
        case 0x2001: case 0x2003: return 1.0;        // em quad / em space
        case 0x2004: return 1.0 / 3;                 // three-per-em
        case 0x2005: return 0.25;                    // four-per-em
        case 0x2006: return 1.0 / 6;                 // six-per-em
        case 0x2009: case 0x202F: return 0.2;        // thin / narrow no-break
        case 0x200A: return 0.1;                     // hair
        case 0x205F: return 4.0 / 18;                // medium mathematical
        default: return 0;
    }
}

// The line with fixed-width spaces the font lacks turned into ordinary spaces kerned to their
// Unicode width (fallback fonts give them arbitrary widths; After Effects uses the standard ones).
NSAttributedString* lineString(NSString* line, CTFontRef base, double size, double kern) {
    NSMutableAttributedString* as = [[NSMutableAttributedString alloc]
        initWithString:line
            attributes:@{(id)kCTFontAttributeName : (__bridge id)base, (id)kCTKernAttributeName : @(kern)}];
    double spaceAdvance = -1;
    for (NSUInteger i = 0; i < line.length; ++i) {
        unichar c = [line characterAtIndex:i];
        const double em = fixedSpaceEm(c);
        if (em == 0) continue;
        CGGlyph g = 0;
        if (CTFontGetGlyphsForCharacters(base, &c, &g, 1) && g != 0) continue;  // the font has it
        if (spaceAdvance < 0) {
            unichar sp = ' ';
            CGGlyph sg = 0;
            CGSize adv = CGSizeZero;
            if (CTFontGetGlyphsForCharacters(base, &sp, &sg, 1)) CTFontGetAdvancesForGlyphs(base, kCTFontOrientationHorizontal, &sg, &adv, 1);
            spaceAdvance = adv.width;
        }
        [as replaceCharactersInRange:NSMakeRange(i, 1) withString:@" "];
        [as addAttribute:(id)kCTKernAttributeName value:@(kern + em * size - spaceAdvance) range:NSMakeRange(i, 1)];
    }
    return as;
}

std::shared_ptr<const TextLayout> buildLayout(const TextStyle& st) {
    auto out = std::make_shared<TextLayout>();
    NSString* text = [NSString stringWithUTF8String:st.text.c_str()] ?: @"";
    CTFontRef base = CTFontCreateWithName((__bridge CFStringRef)(@(st.font.c_str()) ?: @"Helvetica"), st.size, nullptr);
    if (!base) return out;
    out->fonts.push_back(std::shared_ptr<const void>(base, [](const void* f) { CFRelease(f); }));
    const double kern = st.tracking / 1000.0 * st.size;
    NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];
    out->lines = int(lines.count);

    // Word index for every character (UTF-16 units, newlines excluded): a word starts at each
    // non-space character that follows a space or a line start.
    std::vector<int> wordOf;
    int words = 0;
    for (NSString* line in lines) {
        bool inWord = false;
        for (NSUInteger i = 0; i < line.length; ++i) {
            const bool space = [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[line characterAtIndex:i]];
            if (!space && !inWord) ++words;
            inWord = !space;
            wordOf.push_back(std::max(0, words - 1));
        }
    }
    out->words = words;

    double minX = 1e300, maxX = -1e300, top = 0, bottom = 0;
    int charBase = 0;
    for (NSUInteger li = 0; li < lines.count; ++li) {
        NSString* line = lines[li];
        const double baseline = double(li) * st.size * st.lineHeight;
        NSAttributedString* as = lineString(line, base, st.size, kern);
        CTLineRef ln = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGFloat ascent = 0, descent = 0, leading = 0;
        double width = CTLineGetTypographicBounds(ln, &ascent, &descent, &leading);
        if (line.length > 0) width -= kern;  // CoreText adds tracking after the last character too
        const double x0 = st.align == TextAlign::Left ? 0 : st.align == TextAlign::Center ? -width / 2 : -width;
        minX = std::min(minX, x0);
        maxX = std::max(maxX, x0 + std::max(0.0, width));
        if (li == 0) top = -ascent;
        bottom = baseline + descent;

        CFArrayRef runs = CTLineGetGlyphRuns(ln);
        for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
            CTFontRef font = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
            int fontIndex = 0;
            if (font && font != base) {  // fallback font for characters the base font lacks
                CFRetain(font);
                out->fonts.push_back(std::shared_ptr<const void>(font, [](const void* f) { CFRelease(f); }));
                fontIndex = int(out->fonts.size()) - 1;
            } else {
                font = base;
            }
            const CFIndex n = CTRunGetGlyphCount(run);
            std::vector<CGGlyph> glyphs(static_cast<size_t>(n));
            std::vector<CGPoint> positions(static_cast<size_t>(n));
            std::vector<CFIndex> indices(static_cast<size_t>(n));
            CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs.data());
            CTRunGetPositions(run, CFRangeMake(0, 0), positions.data());
            CTRunGetStringIndices(run, CFRangeMake(0, 0), indices.data());
            std::vector<CGRect> rects(static_cast<size_t>(n));
            CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, glyphs.data(), rects.data(), n);
            for (CFIndex g = 0; g < n; ++g) {
                GlyphInfo gi;
                gi.glyph = glyphs[size_t(g)];
                gi.font = fontIndex;
                gi.origin = {x0 + positions[size_t(g)].x, baseline - positions[size_t(g)].y};
                gi.rect = rects[size_t(g)];
                gi.character = charBase + int(indices[size_t(g)]);
                gi.word = gi.character < int(wordOf.size()) ? wordOf[size_t(gi.character)] : 0;
                gi.line = int(li);
                out->glyphs.push_back(gi);
            }
        }
        CFRelease(ln);
        charBase += int(line.length);
    }
    out->characters = charBase;
    if (minX > maxX) minX = maxX = 0;
    out->mn = {minX, top};
    out->mx = {maxX, bottom};
    return out;
}

}  // namespace

std::string textStyleKey(const TextStyle& st) {
    char buf[96];
    std::snprintf(buf, sizeof buf, "|%.4f|%.4f|%.4f|%d", st.size, st.tracking, st.lineHeight, int(st.align));
    return st.text + '\x1f' + st.font + buf;
}

std::shared_ptr<const TextLayout> layoutText(const TextStyle& style) {
    const std::string key = textStyleKey(style);
    LayoutCache& c = layouts();
    {
        std::lock_guard lock(c.mutex);
        auto it = c.map.find(key);
        if (it != c.map.end()) return it->second;
    }
    auto layout = buildLayout(style);
    std::lock_guard lock(c.mutex);
    if (c.map.size() > 512) c.map.clear();  // animated text sizes create many styles; start over
    c.map[key] = layout;
    return layout;
}

std::shared_ptr<const GlyphSheet> GlyphSheetCache::sheet(const TextStyle& style, const TextLayout& layout,
                                                         double pixelsPerUnit, double strokeWidth) {
    // Raster scale rounded *up* to 2^(1/8) steps, limited so a glyph em is at most 1024 px.
    double r = std::exp2(std::ceil(std::log2(std::max(pixelsPerUnit, 1e-3)) * 8) / 8);
    r = std::min(r, 1024.0 / std::max(style.size, 1.0));
    strokeWidth = std::max(0.0, strokeWidth);
    char sk[48];
    std::snprintf(sk, sizeof sk, "@%.5f/%.3f", r, strokeWidth);
    const std::string key = textStyleKey(style) + sk;
    {
        std::lock_guard lock(mutex_);
        auto it = sheets_.find(key);
        if (it != sheets_.end()) return it->second;
    }

    auto sh = std::make_shared<GlyphSheet>();
    sh->scale = r;
    sh->rects.resize(layout.glyphs.size());
    // Shelf-pack padded glyph boxes (the padding also holds the outer half of a stroke).
    const bool stroked = strokeWidth > 0;
    const int pad = 2 + int(std::ceil(strokeWidth * 0.5 * r));
    double area = 0;
    for (const GlyphInfo& g : layout.glyphs) area += (g.rect.size.width * r + 2 * pad) * (g.rect.size.height * r + 2 * pad);
    const int W = std::clamp(int(std::ceil(std::sqrt(std::max(area, 1.0)) * 1.25)), 64, 4096);
    int x = 0, y = 0, rowH = 0;
    struct Box {
        int x, y, w, h;
    };
    std::vector<Box> boxes(layout.glyphs.size(), Box{0, 0, 0, 0});
    for (size_t i = 0; i < layout.glyphs.size(); ++i) {
        const CGRect gr = layout.glyphs[i].rect;
        if (gr.size.width <= 0 || gr.size.height <= 0) continue;  // spaces
        const int w = int(std::ceil(gr.size.width * r)) + 2 * pad, h = int(std::ceil(gr.size.height * r)) + 2 * pad;
        if (x + w > W) {
            x = 0;
            y += rowH;
            rowH = 0;
        }
        boxes[i] = {x, y, w, h};
        x += w;
        rowH = std::max(rowH, h);
    }
    const int H = std::max(1, y + rowH);
    if (H > 8192) return nullptr;  // absurd sizes: skip rather than allocate gigabytes

    std::vector<uint8_t> pixels(size_t(W) * size_t(H), 0), strokePixels(stroked ? size_t(W) * size_t(H) : 0, 0);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    auto makeContext = [&](std::vector<uint8_t>& buf) {
        CGContextRef c = CGBitmapContextCreate(buf.data(), size_t(W), size_t(H), 8, size_t(W), gray, kCGImageAlphaNone);
        CGContextSetGrayFillColor(c, 1, 1);
        CGContextSetGrayStrokeColor(c, 1, 1);
        CGContextSetAllowsFontSmoothing(c, false);
        CGContextSetShouldAntialias(c, true);
        return c;
    };
    CGContextRef ctx = makeContext(pixels);
    CGContextRef sctx = stroked ? makeContext(strokePixels) : nullptr;
    CGColorSpaceRelease(gray);
    if (sctx) {
        CGContextSetTextDrawingMode(sctx, kCGTextFillStroke);  // stroke coverage includes the inside
        CGContextSetLineWidth(sctx, strokeWidth * r);
        CGContextSetLineJoin(sctx, kCGLineJoinRound);
        CGContextSetLineCap(sctx, kCGLineCapRound);
    }
    std::vector<CTFontRef> scaled(layout.fonts.size(), nullptr);
    for (size_t i = 0; i < layout.glyphs.size(); ++i) {
        const Box b = boxes[i];
        if (b.w == 0) continue;
        const GlyphInfo& g = layout.glyphs[i];
        CTFontRef src = (CTFontRef)layout.fonts[size_t(g.font)].get();
        if (!scaled[size_t(g.font)]) scaled[size_t(g.font)] = CTFontCreateCopyWithAttributes(src, CTFontGetSize(src) * r, nullptr, nullptr);
        // CG's origin is bottom-left: the box occupies rows [H - b.y - b.h, H - b.y).
        const CGPoint origin = CGPointMake(b.x + pad - g.rect.origin.x * r, (H - b.y - b.h) + pad - g.rect.origin.y * r);
        CTFontDrawGlyphs(scaled[size_t(g.font)], &g.glyph, &origin, 1, ctx);
        if (sctx) CTFontDrawGlyphs(scaled[size_t(g.font)], &g.glyph, &origin, 1, sctx);
        SheetRect& s = sh->rects[i];
        s.empty = false;
        s.u0 = float(b.x) / W;
        s.v0 = float(b.y) / H;
        s.u1 = float(b.x + b.w) / W;
        s.v1 = float(b.y + b.h) / H;
        const double left = g.rect.origin.x - pad / r, bottomUp = g.rect.origin.y - pad / r;
        s.qmin = {left, -(bottomUp + b.h / r)};
        s.qmax = {left + b.w / r, -bottomUp};
    }
    for (CTFontRef f : scaled)
        if (f) CFRelease(f);
    CGContextRelease(ctx);
    if (sctx) CGContextRelease(sctx);
    if (stroked) {  // interleave (fill, stroke)
        std::vector<uint8_t> rg(size_t(W) * size_t(H) * 2);
        for (size_t i = 0; i < pixels.size(); ++i) {
            rg[i * 2] = pixels[i];
            rg[i * 2 + 1] = strokePixels[i];
        }
        pixels.swap(rg);
    }

    const int bpp = stroked ? 2 : 1;
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(stroked ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm)
                                                           width:NSUInteger(W)
                                                          height:NSUInteger(H)
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;  // written once by the CPU before the GPU ever sees it
    sh->texture = [device_ newTextureWithDescriptor:td];
    [sh->texture replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(W), NSUInteger(H)) mipmapLevel:0 withBytes:pixels.data()
                   bytesPerRow:NSUInteger(W * bpp)];
    sh->texture.label = @"glyph sheet";
    sh->bytes = size_t(W) * size_t(H) * size_t(bpp);

    std::lock_guard lock(mutex_);
    sheets_[key] = sh;
    order_.push_back(key);
    bytes_ += sh->bytes;
    while (bytes_ > kBudget && order_.size() > 1) {  // oldest first; in-flight frames keep theirs alive
        auto it = sheets_.find(order_.front());
        if (it != sheets_.end()) {
            bytes_ -= it->second->bytes;
            sheets_.erase(it);
        }
        order_.erase(order_.begin());
    }
    return sh;
}

void GlyphSheetCache::clear() {
    std::lock_guard lock(mutex_);
    sheets_.clear();
    order_.clear();
    bytes_ = 0;
}

size_t GlyphSheetCache::bytes() const {
    std::lock_guard lock(mutex_);
    return bytes_;
}

}  // namespace mf

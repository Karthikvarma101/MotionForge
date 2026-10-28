#import "MFEngine.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <set>
#include <unordered_map>

#include "MFRender/MetalRenderer.hpp"
#include "mf/Document.hpp"
#include "mf/Evaluator.hpp"
#include "mf/ProjectIO.hpp"

using namespace mf;

NSString* const MFErrorDomain = @"MotionForge";

namespace {

double nowMs() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

NSError* makeError(NSInteger code, const std::string& message) {
    return [NSError errorWithDomain:MFErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

Value toValue(MFValue v) { return {v.x, v.y, v.z, v.w}; }
MFValue toMF(const Value& v) { return MFValue{v[0], v[1], v[2], v[3]}; }
PropRef toRef(MFPropRef r) { return PropRef{static_cast<PropOwner>(r.owner), r.ownerID, int(r.index)}; }
MFPropRef fromRef(PropRef r) { return MFPropRef{static_cast<MFPropOwner>(r.owner), r.ownerId, NSInteger(r.index)}; }

// Inspector hints derived from the stable parameter keys.
void hintsFor(const char* key, NSString** unit, double* step) {
    const std::string k = key;
    if (k == "opacity" || k == "threshold" || k == "intensity" || k == "saturation" || k == "lightness") {
        *unit = @"%";
        *step = 0.5;
    } else if (k == "direction" || k == "hue" || k == "rotation") {
        *unit = @"°";
        *step = 0.5;
    } else if (k == "radius" || k == "distance" || k == "softness" || k == "feather" || k == "expansion" ||
               k == "roundness") {
        *unit = @"px";
        *step = 0.5;
    } else if (k == "brightness" || k == "contrast") {
        *unit = @"";
        *step = 0.5;
    } else {
        *unit = @"";
        *step = 1;
    }
}

// Media that can't be decoded yet keeps a frame "incomplete"; the default frame cache budget is
// 10% of physical memory, clamped to 256 MB…4 GB (2.4 GB on a 24 GB Mac). The GPU shares this
// memory with macOS and every other app, so the budget is deliberately far below the total.
size_t defaultCacheBudget() {
    const double phys = double(NSProcessInfo.processInfo.physicalMemory);
    return size_t(std::clamp(phys * 0.10, 256.0 * (1 << 20), 4096.0 * (1 << 20)));
}

}  // namespace

NSString* MFPropLabel(MFProp prop) { return @(propDef(static_cast<PropId>(prop)).label); }
NSInteger MFPropDimensions(MFProp prop) { return propDef(static_cast<PropId>(prop)).dims; }

// ---------------------------------------------------------------------------------------------

@implementation MFKeyframeInfo
- (instancetype)initWithKey:(const Keyframe&)k index:(NSInteger)index {
    if ((self = [super init])) {
        _index = index;
        _time = k.time;
        _value = toMF(k.value);
        _inInterp = static_cast<MFInterp>(k.inInterp);
        _outInterp = static_cast<MFInterp>(k.outInterp);
    }
    return self;
}
@end

@interface MFParamInfo ()
- (instancetype)initWithRef:(PropRef)ref def:(const PropDef&)def property:(const Property&)p;
@end

@implementation MFParamInfo
- (instancetype)initWithRef:(PropRef)ref def:(const PropDef&)def property:(const Property&)p {
    if ((self = [super init])) {
        _ref = fromRef(ref);
        _label = @(def.label);
        _key = @(def.key);
        _dimensions = def.dims;
        _minValue = def.minValue;
        _maxValue = def.maxValue;
        _isColor = def.isColor;
        NSString* unit = @"";
        double step = 1;
        hintsFor(def.key, &unit, &step);
        _unit = unit;
        _step = step;
        _animated = p.animated();
        NSMutableArray* keys = [NSMutableArray arrayWithCapacity:p.keyframes.size()];
        for (size_t i = 0; i < p.keyframes.size(); ++i)
            [keys addObject:[[MFKeyframeInfo alloc] initWithKey:p.keyframes[i] index:NSInteger(i)]];
        _keyframes = keys;
    }
    return self;
}
@end

@interface MFEffectInfo ()
- (instancetype)initWithEffect:(const Effect&)e;
@end

@implementation MFEffectInfo
- (instancetype)initWithEffect:(const Effect&)e {
    if ((self = [super init])) {
        const EffectDef& def = effectDef(e.type);
        _effectID = e.id;
        _type = static_cast<MFEffectType>(e.type);
        _name = @(def.label);
        _enabled = e.enabled;
        NSMutableArray* params = [NSMutableArray array];
        for (size_t i = 0; i < def.params.size() && i < e.params.size(); ++i)
            [params addObject:[[MFParamInfo alloc] initWithRef:PropRef::effect(e.id, int(i)) def:def.params[i] property:e.params[i]]];
        _params = params;
    }
    return self;
}
@end

@interface MFMaskInfo ()
- (instancetype)initWithMask:(const Mask&)m;
@end

@implementation MFMaskInfo
- (instancetype)initWithMask:(const Mask&)m {
    if ((self = [super init])) {
        _maskID = m.id;
        _name = @(m.name.c_str());
        _shape = static_cast<MFMaskShape>(m.shape);
        _mode = static_cast<MFMaskMode>(m.mode);
        _inverted = m.inverted;
        _enabled = m.enabled;
        NSMutableArray* params = [NSMutableArray array];
        for (int i = 0; i < kMaskParamCount; ++i) {
            const auto p = static_cast<MaskParam>(i);
            [params addObject:[[MFParamInfo alloc] initWithRef:PropRef::mask(m.id, p) def:maskParamDef(p) property:m.param(p)]];
        }
        _params = params;
    }
    return self;
}
@end

@interface MFEffectCatalogEntry ()
@property(nonatomic, readwrite) MFEffectType type;
@property(nonatomic, readwrite, copy) NSString *name, *category, *summary;
@end
@implementation MFEffectCatalogEntry
@end

@interface MFLayerInfo () {
    Layer _layer;
}
@end

@implementation MFLayerInfo
- (instancetype)initWithLayer:(const Layer&)l {
    if ((self = [super init])) _layer = l;
    return self;
}
- (uint64_t)layerID { return _layer.id; }
- (NSString*)name { return @(_layer.name.c_str()); }
- (MFLayerKind)kind { return static_cast<MFLayerKind>(_layer.kind); }
- (MFShapeType)shape { return static_cast<MFShapeType>(_layer.shape); }
- (MFBlendMode)blend { return static_cast<MFBlendMode>(_layer.blend); }
- (BOOL)visible { return _layer.visible; }
- (BOOL)fillEnabled { return _layer.fillEnabled; }
- (BOOL)strokeEnabled { return _layer.strokeEnabled; }
- (double)inPoint { return _layer.inPoint; }
- (double)outPoint { return _layer.outPoint; }
- (uint64_t)parentID { return _layer.parent; }
- (uint64_t)assetID { return _layer.asset; }
- (BOOL)isAnimated:(MFProp)prop { return _layer.prop(static_cast<PropId>(prop)).animated(); }
- (NSArray<MFKeyframeInfo*>*)keyframesFor:(MFProp)prop {
    const auto& keys = _layer.prop(static_cast<PropId>(prop)).keyframes;
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:keys.size()];
    for (size_t i = 0; i < keys.size(); ++i) [out addObject:[[MFKeyframeInfo alloc] initWithKey:keys[i] index:NSInteger(i)]];
    return out;
}
- (BOOL)isAnimatedRef:(MFPropRef)ref {
    const Property* p = resolveProperty(_layer, toRef(ref));
    return p && p->animated();
}
- (NSArray<MFKeyframeInfo*>*)keyframesForRef:(MFPropRef)ref {
    NSMutableArray* out = [NSMutableArray array];
    if (const Property* p = resolveProperty(_layer, toRef(ref)))
        for (size_t i = 0; i < p->keyframes.size(); ++i)
            [out addObject:[[MFKeyframeInfo alloc] initWithKey:p->keyframes[i] index:NSInteger(i)]];
    return out;
}
- (NSArray<MFEffectInfo*>*)effects {
    NSMutableArray* out = [NSMutableArray array];
    for (const Effect& e : _layer.effects) [out addObject:[[MFEffectInfo alloc] initWithEffect:e]];
    return out;
}
- (NSArray<MFMaskInfo*>*)masks {
    NSMutableArray* out = [NSMutableArray array];
    for (const Mask& m : _layer.masks) [out addObject:[[MFMaskInfo alloc] initWithMask:m]];
    return out;
}
- (NSArray<MFParamInfo*>*)animatedEffectAndMaskParams {
    NSMutableArray* out = [NSMutableArray array];
    for (MFMaskInfo* m in self.masks)
        for (MFParamInfo* p in m.params)
            if (p.animated) [out addObject:p];
    for (MFEffectInfo* e in self.effects)
        for (MFParamInfo* p in e.params)
            if (p.animated) [out addObject:p];
    return out;
}
- (uint64_t)matteLayerID { return _layer.matteLayer; }
- (MFMatteMode)matteMode { return static_cast<MFMatteMode>(_layer.matteMode); }
- (NSArray<NSNumber*>*)allKeyframeTimes {
    std::set<double> times;
    for (const Property& p : _layer.props)
        for (const Keyframe& k : p.keyframes) times.insert(k.time);
    for (const Mask& m : _layer.masks)
        for (const Property& p : m.params)
            for (const Keyframe& k : p.keyframes) times.insert(k.time);
    for (const Effect& e : _layer.effects)
        for (const Property& p : e.params)
            for (const Keyframe& k : p.keyframes) times.insert(k.time);
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:times.size()];
    for (double t : times) [out addObject:@(t)];
    return out;
}
@end

@implementation MFCompositionInfo
- (instancetype)initWithComp:(const Composition&)c {
    if ((self = [super init])) {
        _compID = c.id;
        _name = @(c.name.c_str());
        _width = c.width;
        _height = c.height;
        _fps = c.fps;
        _duration = c.duration;
        _background = toMF(c.background);
    }
    return self;
}
@end

@implementation MFAssetInfo
- (instancetype)initWithAsset:(const Asset&)a loaded:(BOOL)loaded {
    if ((self = [super init])) {
        _assetID = a.id;
        _name = @(a.name.c_str());
        _path = @(a.path.c_str());
        _width = a.width;
        _height = a.height;
        _missing = a.missing;
        _loaded = loaded;
    }
    return self;
}
@end

@interface MFViewerFrameInfo ()
@property(nonatomic, readwrite) BOOL cacheHit, complete, skipped;
@property(nonatomic, readwrite) double evalMs, encodeMs;
@property(nonatomic, readwrite) NSInteger itemCount, renderWidth, renderHeight;
@end
@implementation MFViewerFrameInfo
@end

@interface MFRenderStats ()
@property(nonatomic, readwrite, copy) NSString* deviceName;
@property(nonatomic, readwrite) BOOL programmableBlending;
@property(nonatomic, readwrite) double shaderCompileMs, lastGPUMs, averageGPUMs, lastEncodeMs;
@property(nonatomic, readwrite) uint64_t framesEncoded, cacheHits, cacheMisses, cacheFrames, cacheBytes, cacheBudgetBytes;
@property(nonatomic, readwrite) uint64_t poolBytes, mediaBytes, gpuAllocatedBytes, recommendedWorkingSetBytes;
@property(nonatomic, readwrite) NSInteger pendingMedia;
@property(nonatomic, readwrite) uint64_t memoryPressureEvents;
@property(nonatomic, readwrite) uint64_t cacheAdmitted, cacheSkippedCheap;
@property(nonatomic, readwrite) NSInteger offscreenLayers;
@end
@implementation MFRenderStats
@end

// ---------------------------------------------------------------------------------------------

@implementation MFEngine {
    Document _doc;
    std::unique_ptr<MetalRenderer> _renderer;
    std::shared_ptr<std::atomic<int>> _inFlight;
    std::shared_ptr<std::atomic<int>> _prefetchInFlight;
    struct CachedFrame {
        uint64_t hash, revision;
        NSInteger divisor;
    };
    std::unordered_map<int64_t, CachedFrame> _cachedFrames;  // frame index -> what was cached
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError**)error {
    if (!(self = [super init])) return nil;
    std::string err;
    _renderer = MetalRenderer::create(device, err);
    if (!_renderer) {
        if (error) *error = makeError(1, err);
        return nil;
    }
    _renderer->setCacheBudget(defaultCacheBudget());
    _inFlight = std::make_shared<std::atomic<int>>(0);
    _prefetchInFlight = std::make_shared<std::atomic<int>>(0);
    return self;
}

- (id<MTLDevice>)device { return _renderer->device(); }
- (uint64_t)revision { return _doc.revision(); }
- (BOOL)dirty { return _doc.dirty(); }

- (ObjectId)compID { return _doc.project().activeComposition; }
- (const Composition*)comp { return _doc.project().activeComp(); }

// ---- project ----

- (void)loadAllMedia {
    for (const Asset& a : _doc.project().assets)
        if (!a.missing) [self requestMedia:a];
}

- (void)requestMedia:(const Asset&)a {
    __weak MFEngine* weakSelf = self;
    const ObjectId aid = a.id;
    _renderer->requestImage(a.id, a.generation, a.path, [weakSelf, aid](bool ok, const std::string& err) {
        MFEngine* s = weakSelf;
        if (s && s.mediaDidLoad) s.mediaDidLoad(aid, ok ? nil : @(err.c_str()));
    });
}

- (void)newProjectWithWidth:(NSInteger)width height:(NSInteger)height fps:(double)fps duration:(double)duration {
    _doc.replaceProject(makeDefaultProject(int(width), int(height), fps, duration));
    _renderer->clearCache();
}

- (BOOL)openProjectAtPath:(NSString*)path error:(NSError**)error {
    Project p;
    std::string err;
    if (!loadProjectFile(path.fileSystemRepresentation, p, err)) {
        if (error) *error = makeError(2, err);
        return NO;
    }
    _doc.replaceProject(std::move(p));
    _renderer->clearCache();
    [self loadAllMedia];
    return YES;
}

- (BOOL)saveProjectToPath:(NSString*)path error:(NSError**)error {
    std::string err;
    if (!saveProjectFile(_doc.project(), path.fileSystemRepresentation, err)) {
        if (error) *error = makeError(3, err);
        return NO;
    }
    _doc.markSaved();
    return YES;
}

- (BOOL)writeRecoveryCopyToPath:(NSString*)path error:(NSError**)error {
    std::string err;
    if (!saveProjectFile(_doc.project(), path.fileSystemRepresentation, err)) {
        if (error) *error = makeError(3, err);
        return NO;
    }
    return YES;
}

- (BOOL)recoverFromPath:(NSString*)path error:(NSError**)error {
    if (![self openProjectAtPath:path error:error]) return NO;
    _doc.markUnsaved();
    return YES;
}

- (void)markCleanForNewDocument {
    _doc.clearHistory();
}

- (NSString*)serializedProjectRelativeTo:(NSString*)directory {
    return @(serializeProject(_doc.project(), directory ? directory.fileSystemRepresentation : "").c_str());
}

// ---- undo ----

- (BOOL)canUndo { return _doc.canUndo(); }
- (BOOL)canRedo { return _doc.canRedo(); }
- (NSString*)undoLabel { return @(_doc.undoLabel().c_str()); }
- (NSString*)redoLabel { return @(_doc.redoLabel().c_str()); }
- (BOOL)undo { return _doc.undo(); }
- (BOOL)redo { return _doc.redo(); }
- (void)beginUndoGroup:(NSString*)label { _doc.beginGroup(label.UTF8String); }
- (void)endUndoGroup { _doc.endGroup(); }

// ---- composition ----

- (MFCompositionInfo*)composition {
    const Composition* c = [self comp];
    return c ? [[MFCompositionInfo alloc] initWithComp:*c] : [[MFCompositionInfo alloc] initWithComp:Composition()];
}

- (BOOL)setCompositionWidth:(NSInteger)width height:(NSInteger)height fps:(double)fps duration:(double)duration
                 background:(MFValue)background name:(NSString*)name {
    return _doc.setCompositionSettings([self compID], int(width), int(height), fps, duration, toValue(background),
                                       name.UTF8String);
}

// ---- media ----

- (NSArray<MFAssetInfo*>*)assets {
    NSMutableArray* out = [NSMutableArray array];
    for (const Asset& a : _doc.project().assets)
        [out addObject:[[MFAssetInfo alloc] initWithAsset:a loaded:_renderer->hasImage(a.id, a.generation)]];
    return out;
}

- (NSNumber*)importImageAtPath:(NSString*)path error:(NSError**)error {
    int w = 0, h = 0;
    std::string err;
    if (!MetalRenderer::probeImage(path.fileSystemRepresentation, w, h, err)) {
        if (error) *error = makeError(4, err);
        return nil;
    }
    if (w > 16384 || h > 16384) {
        if (error) *error = makeError(4, "Images larger than 16384 px are not supported yet");
        return nil;
    }
    const ObjectId aid = _doc.addImageAsset(path.fileSystemRepresentation, path.lastPathComponent.UTF8String, w, h);
    if (const Asset* a = _doc.project().findAsset(aid)) [self requestMedia:*a];
    return @(aid);
}

- (BOOL)waitForMediaWithTimeout:(NSTimeInterval)seconds {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (_renderer->stats().pendingAssets > 0) {
        if ([deadline timeIntervalSinceNow] < 0) return NO;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];  // flush callbacks
    return YES;
}

// ---- layers ----

- (NSArray<MFLayerInfo*>*)layers {
    NSMutableArray* out = [NSMutableArray array];
    if (const Composition* c = [self comp])
        for (const Layer& l : c->layers) [out addObject:[[MFLayerInfo alloc] initWithLayer:l]];
    return out;
}

- (MFLayerInfo*)layerWithID:(uint64_t)layerID {
    const Composition* c = [self comp];
    const Layer* l = c ? c->findLayer(layerID) : nullptr;
    return l ? [[MFLayerInfo alloc] initWithLayer:*l] : nil;
}

- (uint64_t)addShapeLayer:(MFShapeType)shape {
    return _doc.addLayer([self compID], LayerKind::Shape, static_cast<ShapeType>(shape));
}
- (uint64_t)addImageLayerWithAsset:(uint64_t)assetID {
    return _doc.addLayer([self compID], LayerKind::Image, ShapeType::Rectangle, assetID);
}
- (uint64_t)addNullLayer { return _doc.addLayer([self compID], LayerKind::Null); }
- (BOOL)removeLayer:(uint64_t)layerID { return _doc.removeLayer([self compID], layerID); }
- (uint64_t)duplicateLayer:(uint64_t)layerID { return _doc.duplicateLayer([self compID], layerID); }
- (BOOL)moveLayer:(uint64_t)layerID toIndex:(NSInteger)index { return _doc.moveLayer([self compID], layerID, int(index)); }
- (BOOL)setLayer:(uint64_t)layerID name:(NSString*)name { return _doc.setLayerName([self compID], layerID, name.UTF8String); }
- (BOOL)setLayer:(uint64_t)layerID visible:(BOOL)visible { return _doc.setLayerVisible([self compID], layerID, visible); }
- (BOOL)setLayer:(uint64_t)layerID inPoint:(double)inPoint outPoint:(double)outPoint {
    return _doc.setLayerTiming([self compID], layerID, inPoint, outPoint);
}
- (BOOL)setLayer:(uint64_t)layerID parent:(uint64_t)parentID {
    return _doc.setLayerParent([self compID], layerID, parentID);
}
- (BOOL)setLayer:(uint64_t)layerID blendMode:(MFBlendMode)mode {
    return _doc.setLayerBlend([self compID], layerID, static_cast<BlendMode>(mode));
}
- (BOOL)setLayer:(uint64_t)layerID shapeType:(MFShapeType)shape {
    return _doc.setLayerShape([self compID], layerID, static_cast<ShapeType>(shape));
}
- (BOOL)setLayer:(uint64_t)layerID fillEnabled:(BOOL)fill strokeEnabled:(BOOL)stroke {
    return _doc.setLayerFillStroke([self compID], layerID, fill, stroke);
}

// ---- properties ----

- (MFValue)valueOf:(MFProp)prop layer:(uint64_t)layerID time:(double)time {
    return [self valueOfRef:MFPropRefMake(prop) layer:layerID time:time];
}
- (BOOL)setPropertyValue:(MFValue)value prop:(MFProp)prop layer:(uint64_t)layerID time:(double)time {
    return [self setRefValue:value ref:MFPropRefMake(prop) layer:layerID time:time];
}
- (BOOL)setAnimated:(BOOL)animated prop:(MFProp)prop layer:(uint64_t)layerID time:(double)time {
    return [self setAnimated:animated ref:MFPropRefMake(prop) layer:layerID time:time];
}
- (BOOL)addKeyframeForProp:(MFProp)prop layer:(uint64_t)layerID time:(double)time {
    return [self addKeyframeForRef:MFPropRefMake(prop) layer:layerID time:time];
}
- (BOOL)removeKeyframeAtIndex:(NSInteger)index prop:(MFProp)prop layer:(uint64_t)layerID {
    return [self removeKeyframeAtIndex:index ref:MFPropRefMake(prop) layer:layerID];
}
- (NSInteger)moveKeyframeAtIndex:(NSInteger)index prop:(MFProp)prop layer:(uint64_t)layerID toTime:(double)time {
    return [self moveKeyframeAtIndex:index ref:MFPropRefMake(prop) layer:layerID toTime:time];
}
- (BOOL)setKeyframeInterpolationAtIndex:(NSInteger)index prop:(MFProp)prop layer:(uint64_t)layerID
                                     in:(MFInterp)inInterp out:(MFInterp)outInterp {
    return [self setKeyframeInterpolationAtIndex:index ref:MFPropRefMake(prop) layer:layerID in:inInterp out:outInterp];
}

- (MFValue)valueOfRef:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time {
    const Composition* c = [self comp];
    const Layer* l = c ? c->findLayer(layerID) : nullptr;
    const Property* p = l ? resolveProperty(*l, toRef(ref)) : nullptr;
    if (!p) return MFValue{0, 0, 0, 0};
    return toMF(evaluateProperty(*p, *propertyDef(*l, toRef(ref)), time));
}
- (BOOL)setRefValue:(MFValue)value ref:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time {
    return _doc.setPropertyValue([self compID], layerID, toRef(ref), time, toValue(value));
}
- (BOOL)setAnimated:(BOOL)animated ref:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time {
    return _doc.setPropertyAnimated([self compID], layerID, toRef(ref), animated, time);
}
- (BOOL)addKeyframeForRef:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time {
    return _doc.addKeyframe([self compID], layerID, toRef(ref), time);
}
- (BOOL)removeKeyframeAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID {
    return _doc.removeKeyframe([self compID], layerID, toRef(ref), int(index));
}
- (NSInteger)moveKeyframeAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID toTime:(double)time {
    return _doc.moveKeyframe([self compID], layerID, toRef(ref), int(index), time);
}
- (BOOL)setKeyframeInterpolationAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID
                                     in:(MFInterp)inInterp out:(MFInterp)outInterp {
    return _doc.setKeyframeInterpolation([self compID], layerID, toRef(ref), int(index), static_cast<Interp>(inInterp),
                                         static_cast<Interp>(outInterp));
}

// ---- effects, masks, mattes ----

+ (NSArray<MFEffectCatalogEntry*>*)effectCatalog {
    NSMutableArray* out = [NSMutableArray array];
    for (int i = 0; i < kEffectTypeCount; ++i) {
        const EffectDef& d = effectDef(static_cast<EffectType>(i));
        MFEffectCatalogEntry* e = [MFEffectCatalogEntry new];
        e.type = static_cast<MFEffectType>(i);
        e.name = @(d.label);
        e.category = @(d.category);
        e.summary = @(d.summary);
        [out addObject:e];
    }
    return out;
}
- (uint64_t)addEffect:(MFEffectType)type layer:(uint64_t)layerID {
    return _doc.addEffect([self compID], layerID, static_cast<EffectType>(type));
}
- (BOOL)removeEffect:(uint64_t)effectID layer:(uint64_t)layerID { return _doc.removeEffect([self compID], layerID, effectID); }
- (BOOL)moveEffect:(uint64_t)effectID layer:(uint64_t)layerID toIndex:(NSInteger)index {
    return _doc.moveEffect([self compID], layerID, effectID, int(index));
}
- (BOOL)setEffect:(uint64_t)effectID layer:(uint64_t)layerID enabled:(BOOL)enabled {
    return _doc.setEffectEnabled([self compID], layerID, effectID, enabled);
}
- (uint64_t)addMask:(MFMaskShape)shape layer:(uint64_t)layerID {
    return _doc.addMask([self compID], layerID, static_cast<MaskShape>(shape));
}
- (BOOL)removeMask:(uint64_t)maskID layer:(uint64_t)layerID { return _doc.removeMask([self compID], layerID, maskID); }
- (BOOL)setMask:(uint64_t)maskID layer:(uint64_t)layerID mode:(MFMaskMode)mode inverted:(BOOL)inverted {
    return _doc.setMaskMode([self compID], layerID, maskID, static_cast<MaskMode>(mode), inverted);
}
- (BOOL)setMask:(uint64_t)maskID layer:(uint64_t)layerID shape:(MFMaskShape)shape {
    return _doc.setMaskShape([self compID], layerID, maskID, static_cast<MaskShape>(shape));
}
- (BOOL)setMask:(uint64_t)maskID layer:(uint64_t)layerID enabled:(BOOL)enabled {
    return _doc.setMaskEnabled([self compID], layerID, maskID, enabled);
}
- (BOOL)setLayer:(uint64_t)layerID matte:(uint64_t)matteLayerID mode:(MFMatteMode)mode {
    return _doc.setLayerMatte([self compID], layerID, matteLayerID, static_cast<MatteMode>(mode));
}

// ---- viewer ----

- (uint64_t)hitTestAtPoint:(CGPoint)p time:(double)time {
    const Composition* c = [self comp];
    return c ? hitTest(_doc.project(), *c, time, {p.x, p.y}) : 0;
}

- (MFQuad)quadForLayer:(uint64_t)layerID time:(double)time {
    MFQuad q{};
    const Composition* c = [self comp];
    const Layer* l = c ? c->findLayer(layerID) : nullptr;
    if (!l) return q;
    const auto k = layerCorners(_doc.project(), *c, *l, time);
    q.topLeft = CGPointMake(k[0].x, k[0].y);
    q.topRight = CGPointMake(k[1].x, k[1].y);
    q.bottomRight = CGPointMake(k[2].x, k[2].y);
    q.bottomLeft = CGPointMake(k[3].x, k[3].y);
    return q;
}

- (MFQuad)quadForMask:(uint64_t)maskID layer:(uint64_t)layerID time:(double)time {
    MFQuad q{};
    const Composition* c = [self comp];
    const Layer* l = c ? c->findLayer(layerID) : nullptr;
    const Mask* m = l ? l->findMask(maskID) : nullptr;
    if (!m) return q;
    const auto k = maskCorners(*c, *l, *m, time);
    q.topLeft = CGPointMake(k[0].x, k[0].y);
    q.topRight = CGPointMake(k[1].x, k[1].y);
    q.bottomRight = CGPointMake(k[2].x, k[2].y);
    q.bottomLeft = CGPointMake(k[3].x, k[3].y);
    return q;
}

- (CGPoint)parentSpaceVector:(CGPoint)v layer:(uint64_t)layerID time:(double)time {
    const Composition* c = [self comp];
    const Layer* l = c ? c->findLayer(layerID) : nullptr;
    const Layer* parent = (l && l->parent) ? c->findLayer(l->parent) : nullptr;
    if (!parent) return v;
    Affine m = layerWorldTransform(*c, *parent, time);
    m.tx = m.ty = 0;  // vectors ignore translation
    Affine inv;
    if (!m.inverse(inv)) return v;
    const Vec2 r = inv.apply({v.x, v.y});
    return CGPointMake(r.x, r.y);
}

- (MFViewerFrameInfo*)drawInView:(MTKView*)view
                            time:(double)time
                  qualityDivisor:(NSInteger)divisor
                          origin:(CGPoint)origin
                           scale:(double)scale
                    checkerboard:(BOOL)checkerboard {
    MFViewerFrameInfo* info = [MFViewerFrameInfo new];
    const Composition* c = [self comp];
    if (!c) return info;
    if (_inFlight->load() >= 3) {  // GPU behind: never block the main thread waiting for it
        info.skipped = YES;
        return info;
    }
    const double t0 = nowMs();
    const FrameDesc f = evaluateFrame(_doc.project(), *c, time, 1.0 / double(std::max<NSInteger>(1, divisor)));
    info.evalMs = nowMs() - t0;
    info.itemCount = NSInteger(f.items.size());
    info.renderWidth = f.width;
    info.renderHeight = f.height;

    MTLRenderPassDescriptor* pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) {
        info.skipped = YES;
        return info;
    }
    // Composite and present go in separate command buffers so the GPU time measured for the
    // composite (which drives cache admission and adaptive resolution) excludes presentation.
    id<MTLCommandBuffer> compositeCB = [_renderer->queue() commandBuffer];
    compositeCB.label = @"composite";
    id<MTLCommandBuffer> cb = [_renderer->queue() commandBuffer];
    cb.label = @"present";
    bool hit = false, complete = true;
    const double t1 = nowMs();
    id<MTLTexture> frame = _renderer->compositeFrame(f, compositeCB, true, &hit, &complete, cb);
    [compositeCB commit];
    info.encodeMs = hit ? 0 : nowMs() - t1;
    info.cacheHit = hit;
    info.complete = complete;
    if (hit || _renderer->cacheContains(f.hash))
        _cachedFrames[std::llround(time * c->fps)] = CachedFrame{f.hash, _doc.revision(), divisor};

    PresentParams p;
    p.originX = origin.x;
    p.originY = origin.y;
    p.scale = scale;
    p.compWidth = c->width;
    p.compHeight = c->height;
    p.background = c->background;
    p.checkerboard = checkerboard;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;  // the present pass covers every pixel
    _renderer->encodePresent(cb, pass, frame, p, int(view.drawableSize.width), int(view.drawableSize.height));
    [cb presentDrawable:drawable];
    auto inFlight = _inFlight;
    inFlight->fetch_add(1);
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { inFlight->fetch_sub(1); }];
    [cb commit];
    return info;
}

// ---- offscreen ----

- (CGImageRef)copyImageAtTime:(double)time scale:(double)scale transparent:(BOOL)transparent error:(NSError**)error {
    const Composition* c = [self comp];
    if (!c) {
        if (error) *error = makeError(5, "No composition");
        return nullptr;
    }
    const FrameDesc f = evaluateFrame(_doc.project(), *c, time, scale);
    std::vector<float> px;
    std::string err;
    if (!_renderer->renderToRGBA(f, px, nullptr, err)) {
        if (error) *error = makeError(5, err);
        return nullptr;
    }
    const size_t w = size_t(f.width), h = size_t(f.height);
    NSMutableData* data = [NSMutableData dataWithLength:w * h * 4];
    auto* out = static_cast<uint8_t*>(data.mutableBytes);
    const Value bg = c->background;
    auto q = [](float v) { return uint8_t(std::lround(std::clamp(v, 0.f, 1.f) * 255.f)); };
    for (size_t i = 0; i < w * h; ++i) {
        float r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2], a = px[i * 4 + 3];
        if (!transparent) {  // composite over the background colour (premultiplied over)
            r += float(bg[0]) * (1 - a);
            g += float(bg[1]) * (1 - a);
            b += float(bg[2]) * (1 - a);
            a = 1;
        }
        out[i * 4] = q(r);
        out[i * 4 + 1] = q(g);
        out[i * 4 + 2] = q(b);
        out[i * 4 + 3] = q(a);
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs,
                                   (CGBitmapInfo)(transparent ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast) |
                                       (CGBitmapInfo)kCGBitmapByteOrder32Big,
                                   provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    return img;
}

- (BOOL)writePNGAtTime:(double)time scale:(double)scale transparent:(BOOL)transparent toPath:(NSString*)path
                 error:(NSError**)error {
    CGImageRef img = [self copyImageAtTime:time scale:scale transparent:transparent error:error];
    if (!img) return NO;
    NSURL* url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    if (!dst) {
        CGImageRelease(img);
        if (error) *error = makeError(6, "Cannot create " + std::string(path.UTF8String));
        return NO;
    }
    CGImageDestinationAddImage(dst, img, nullptr);
    const bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    if (!ok && error) *error = makeError(6, "Cannot write " + std::string(path.UTF8String));
    return ok;
}

// ---- memory & stats ----

- (MFCachePolicy)cachePolicy { return static_cast<MFCachePolicy>(_renderer->cachePolicy()); }
- (void)setCachePolicy:(MFCachePolicy)p {
    _renderer->setCachePolicy(static_cast<CachePolicy>(p));
    if (p == MFCachePolicyOff) _cachedFrames.clear();
}

- (NSInteger)prefetchFromTime:(double)time frames:(NSInteger)count qualityDivisor:(NSInteger)divisor loop:(BOOL)loop {
    const Composition* c = [self comp];
    if (!c || _renderer->cachePolicy() == CachePolicy::Off) return 0;
    const int64_t frames = std::max<int64_t>(1, c->frameCount());
    const int64_t start = std::llround(time * c->fps);
    const double scale = 1.0 / double(std::max<NSInteger>(1, divisor));
    NSInteger queued = 0;
    for (NSInteger k = 1; k <= count && _prefetchInFlight->load() < 2; ++k) {
        int64_t fi = start + k;
        if (fi >= frames) {
            if (!loop) break;
            fi %= frames;
        }
        const FrameDesc f = evaluateFrame(_doc.project(), *c, double(fi) / c->fps, scale);
        if (_renderer->cacheContains(f.hash)) {
            _cachedFrames[fi] = CachedFrame{f.hash, _doc.revision(), divisor};
            continue;
        }
        if (!_renderer->wouldCache(f)) continue;  // cheap to draw on demand: not worth the memory
        id<MTLCommandBuffer> cb = [_renderer->queue() commandBuffer];
        cb.label = @"prefetch";
        bool hit = false, complete = true;
        _renderer->compositeFrame(f, cb, true, &hit, &complete);
        auto inFlight = _prefetchInFlight;
        inFlight->fetch_add(1);
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) { inFlight->fetch_sub(1); }];
        [cb commit];
        if (complete) _cachedFrames[fi] = CachedFrame{f.hash, _doc.revision(), divisor};
        ++queued;
    }
    return queued;
}

- (NSIndexSet*)cachedFramesForQualityDivisor:(NSInteger)divisor {
    NSMutableIndexSet* out = [NSMutableIndexSet indexSet];
    const uint64_t rev = _doc.revision();
    for (auto it = _cachedFrames.begin(); it != _cachedFrames.end();) {
        const CachedFrame& cf = it->second;
        if (cf.revision != rev || !_renderer->cacheContains(cf.hash)) {
            it = _cachedFrames.erase(it);  // stale or evicted
            continue;
        }
        if (cf.divisor == divisor && it->first >= 0) [out addIndex:NSUInteger(it->first)];
        ++it;
    }
    return out;
}

- (uint64_t)cacheBudgetBytes { return _renderer->stats().cacheBudget; }
- (void)setCacheBudgetBytes:(uint64_t)bytes { _renderer->setCacheBudget(size_t(bytes)); }
- (void)purgeFrameCache {
    _renderer->clearCache();
    _cachedFrames.clear();
}

- (void)handleMemoryPressure:(MFMemoryPressure)level {
    _renderer->handleMemoryPressure(level == MFMemoryPressureCritical  ? PressureLevel::Critical
                                    : level == MFMemoryPressureWarning ? PressureLevel::Warning
                                                                       : PressureLevel::Normal);
}

- (MFRenderStats*)stats {
    const RendererStats s = _renderer->stats();
    MFRenderStats* o = [MFRenderStats new];
    o.deviceName = _renderer->device().name;
    o.programmableBlending = _renderer->programmableBlending();
    o.shaderCompileMs = _renderer->shaderCompileMs();
    o.lastGPUMs = s.lastGpuMs;
    o.averageGPUMs = s.avgGpuMs;
    o.lastEncodeMs = s.lastEncodeMs;
    o.framesEncoded = s.framesEncoded;
    o.cacheHits = s.cacheHits;
    o.cacheMisses = s.cacheMisses;
    o.cacheFrames = s.cacheFrames;
    o.cacheBytes = s.cacheBytes;
    o.cacheBudgetBytes = s.cacheBudget;
    o.poolBytes = s.poolBytes;
    o.mediaBytes = s.assetBytes;
    o.gpuAllocatedBytes = s.deviceAllocated;
    o.recommendedWorkingSetBytes = s.recommendedWorkingSet;
    o.pendingMedia = s.pendingAssets;
    o.memoryPressureEvents = s.pressureEvents;
    o.cacheAdmitted = s.cacheAdmitted;
    o.cacheSkippedCheap = s.cacheSkippedCheap;
    o.offscreenLayers = NSInteger(s.offscreenLayers);
    return o;
}

- (void)resetStats { _renderer->resetCounters(); }

@end

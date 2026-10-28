// MotionForge — Objective-C bridge between the C++ engine (document, evaluation, Metal renderer)
// and the Swift/SwiftUI application. Pure Objective-C so Swift can import it directly.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MFLayerKind) { MFLayerKindShape = 0, MFLayerKindImage, MFLayerKindNull };
typedef NS_ENUM(NSInteger, MFShapeType) { MFShapeTypeRectangle = 0, MFShapeTypeEllipse, MFShapeTypePolygon, MFShapeTypeStar };
typedef NS_ENUM(NSInteger, MFBlendMode) {
    MFBlendModeNormal = 0, MFBlendModeAdd, MFBlendModeMultiply, MFBlendModeScreen,
    MFBlendModeOverlay, MFBlendModeDarken, MFBlendModeLighten
};
typedef NS_ENUM(NSInteger, MFInterp) { MFInterpLinear = 0, MFInterpHold, MFInterpBezier };
typedef NS_ENUM(NSInteger, MFProp) {
    MFPropAnchorPoint = 0, MFPropPosition, MFPropScale, MFPropRotation, MFPropOpacity,
    MFPropSize, MFPropRoundness, MFPropFillColor, MFPropStrokeColor, MFPropStrokeWidth,
    MFPropPoints, MFPropInnerRatio
};
typedef NS_ENUM(NSInteger, MFMemoryPressure) { MFMemoryPressureNormal = 0, MFMemoryPressureWarning, MFMemoryPressureCritical };
typedef NS_ENUM(NSInteger, MFEffectType) {
    MFEffectTypeGaussianBlur = 0, MFEffectTypeDropShadow, MFEffectTypeGlow,
    MFEffectTypeBrightnessContrast, MFEffectTypeHueSaturation, MFEffectTypeFill
};
typedef NS_ENUM(NSInteger, MFMaskShape) { MFMaskShapeRectangle = 0, MFMaskShapeEllipse };
typedef NS_ENUM(NSInteger, MFMaskMode) { MFMaskModeAdd = 0, MFMaskModeSubtract, MFMaskModeIntersect, MFMaskModeDifference };
typedef NS_ENUM(NSInteger, MFMatteMode) {
    MFMatteModeNone = 0, MFMatteModeAlpha, MFMatteModeAlphaInverted, MFMatteModeLuma, MFMatteModeLumaInverted
};
typedef NS_ENUM(NSInteger, MFCachePolicy) { MFCachePolicySmart = 0, MFCachePolicyAll, MFCachePolicyOff };
typedef NS_ENUM(NSInteger, MFPropOwner) { MFPropOwnerLayer = 0, MFPropOwnerMask, MFPropOwnerEffect };

// Address of any animatable property: a layer property, a mask parameter or an effect parameter.
typedef struct {
    MFPropOwner owner;
    uint64_t ownerID;  // mask / effect id (0 for layer properties)
    NSInteger index;   // MFProp, mask parameter or effect parameter index
} MFPropRef;

static inline MFPropRef MFPropRefMake(MFProp prop) {
    MFPropRef r = {MFPropOwnerLayer, 0, (NSInteger)prop};
    return r;
}

typedef struct {
    double x, y, z, w;
} MFValue;

typedef struct {
    CGPoint topLeft, topRight, bottomRight, bottomLeft;
} MFQuad;

FOUNDATION_EXPORT NSString* const MFErrorDomain;
FOUNDATION_EXPORT NSString* MFPropLabel(MFProp prop);
FOUNDATION_EXPORT NSInteger MFPropDimensions(MFProp prop);

// Immutable snapshots handed to the UI. Re-fetch after `revision` changes.
@interface MFKeyframeInfo : NSObject
@property(nonatomic, readonly) NSInteger index;
@property(nonatomic, readonly) double time;
@property(nonatomic, readonly) MFValue value;
@property(nonatomic, readonly) MFInterp inInterp;
@property(nonatomic, readonly) MFInterp outInterp;
@end

// One animatable parameter with its definition and keyframes.
@interface MFParamInfo : NSObject
@property(nonatomic, readonly) MFPropRef ref;
@property(nonatomic, readonly, copy) NSString* label;
@property(nonatomic, readonly, copy) NSString* key;
@property(nonatomic, readonly) NSInteger dimensions;
@property(nonatomic, readonly) double minValue;
@property(nonatomic, readonly) double maxValue;
@property(nonatomic, readonly) BOOL isColor;
@property(nonatomic, readonly, copy) NSString* unit;  // "%", "°", "px" or ""
@property(nonatomic, readonly) double step;            // per point of drag in the inspector
@property(nonatomic, readonly) BOOL animated;
@property(nonatomic, readonly) NSArray<MFKeyframeInfo*>* keyframes;
@end

@interface MFEffectInfo : NSObject
@property(nonatomic, readonly) uint64_t effectID;
@property(nonatomic, readonly) MFEffectType type;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) NSArray<MFParamInfo*>* params;
@end

@interface MFMaskInfo : NSObject
@property(nonatomic, readonly) uint64_t maskID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) MFMaskShape shape;
@property(nonatomic, readonly) MFMaskMode mode;
@property(nonatomic, readonly) BOOL inverted;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) NSArray<MFParamInfo*>* params;
@end

@interface MFEffectCatalogEntry : NSObject
@property(nonatomic, readonly) MFEffectType type;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* category;
@property(nonatomic, readonly, copy) NSString* summary;
@end

@interface MFLayerInfo : NSObject
@property(nonatomic, readonly) uint64_t layerID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) MFLayerKind kind;
@property(nonatomic, readonly) MFShapeType shape;
@property(nonatomic, readonly) MFBlendMode blend;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) BOOL fillEnabled;
@property(nonatomic, readonly) BOOL strokeEnabled;
@property(nonatomic, readonly) double inPoint;
@property(nonatomic, readonly) double outPoint;
@property(nonatomic, readonly) uint64_t parentID;
@property(nonatomic, readonly) uint64_t assetID;
- (BOOL)isAnimated:(MFProp)prop;
- (NSArray<MFKeyframeInfo*>*)keyframesFor:(MFProp)prop;
- (BOOL)isAnimatedRef:(MFPropRef)ref;
- (NSArray<MFKeyframeInfo*>*)keyframesForRef:(MFPropRef)ref;
@property(nonatomic, readonly) NSArray<NSNumber*>* allKeyframeTimes;  // union over every property, sorted
@property(nonatomic, readonly) NSArray<MFEffectInfo*>* effects;
@property(nonatomic, readonly) NSArray<MFMaskInfo*>* masks;
@property(nonatomic, readonly) NSArray<MFParamInfo*>* animatedEffectAndMaskParams;  // for timeline rows
@property(nonatomic, readonly) uint64_t matteLayerID;
@property(nonatomic, readonly) MFMatteMode matteMode;
@end

@interface MFCompositionInfo : NSObject
@property(nonatomic, readonly) uint64_t compID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) double fps;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) MFValue background;
@end

@interface MFAssetInfo : NSObject
@property(nonatomic, readonly) uint64_t assetID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* path;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) BOOL missing;
@property(nonatomic, readonly) BOOL loaded;
@end

@interface MFViewerFrameInfo : NSObject
@property(nonatomic, readonly) BOOL cacheHit;
@property(nonatomic, readonly) BOOL complete;     // NO while imported media is still decoding
@property(nonatomic, readonly) BOOL skipped;      // GPU was busy; nothing new was presented
@property(nonatomic, readonly) double evalMs;     // CPU timeline evaluation
@property(nonatomic, readonly) double encodeMs;   // CPU command encoding (0 on cache hit)
@property(nonatomic, readonly) NSInteger itemCount;
@property(nonatomic, readonly) NSInteger renderWidth;
@property(nonatomic, readonly) NSInteger renderHeight;
@end

@interface MFRenderStats : NSObject
@property(nonatomic, readonly, copy) NSString* deviceName;
@property(nonatomic, readonly) BOOL programmableBlending;
@property(nonatomic, readonly) double shaderCompileMs;
@property(nonatomic, readonly) double lastGPUMs;
@property(nonatomic, readonly) double averageGPUMs;
@property(nonatomic, readonly) double lastEncodeMs;
@property(nonatomic, readonly) uint64_t framesEncoded;
@property(nonatomic, readonly) uint64_t cacheHits;
@property(nonatomic, readonly) uint64_t cacheMisses;
@property(nonatomic, readonly) uint64_t cacheFrames;
@property(nonatomic, readonly) uint64_t cacheBytes;
@property(nonatomic, readonly) uint64_t cacheBudgetBytes;
@property(nonatomic, readonly) uint64_t poolBytes;
@property(nonatomic, readonly) uint64_t mediaBytes;
@property(nonatomic, readonly) uint64_t gpuAllocatedBytes;
@property(nonatomic, readonly) uint64_t recommendedWorkingSetBytes;
@property(nonatomic, readonly) NSInteger pendingMedia;
@property(nonatomic, readonly) uint64_t memoryPressureEvents;
@property(nonatomic, readonly) uint64_t cacheAdmitted;
@property(nonatomic, readonly) uint64_t cacheSkippedCheap;
@property(nonatomic, readonly) NSInteger offscreenLayers;
@end

@interface MFEngine : NSObject

- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device error:(NSError**)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic, readonly) BOOL dirty;

// Called on the main queue when imported media finishes loading (the viewer should redraw).
@property(nonatomic, copy, nullable) void (^mediaDidLoad)(uint64_t assetID, NSString* _Nullable error);

// ---- project ----
- (void)newProjectWithWidth:(NSInteger)width height:(NSInteger)height fps:(double)fps duration:(double)duration;
- (BOOL)openProjectAtPath:(NSString*)path error:(NSError**)error;
- (BOOL)saveProjectToPath:(NSString*)path error:(NSError**)error;        // marks the document clean
- (BOOL)writeRecoveryCopyToPath:(NSString*)path error:(NSError**)error;  // autosave; leaves dirty state
- (BOOL)recoverFromPath:(NSString*)path error:(NSError**)error;          // opens an autosave as unsaved work
- (void)markCleanForNewDocument;                                        // drop undo history, mark saved
- (NSString*)serializedProjectRelativeTo:(nullable NSString*)directory;

// ---- undo ----
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
@property(nonatomic, readonly, copy) NSString* undoLabel;
@property(nonatomic, readonly, copy) NSString* redoLabel;
- (BOOL)undo;
- (BOOL)redo;
- (void)beginUndoGroup:(NSString*)label;
- (void)endUndoGroup;

// ---- composition ----
@property(nonatomic, readonly) MFCompositionInfo* composition;
- (BOOL)setCompositionWidth:(NSInteger)width height:(NSInteger)height fps:(double)fps duration:(double)duration
                 background:(MFValue)background name:(NSString*)name;

// ---- media ----
- (NSArray<MFAssetInfo*>*)assets;
- (nullable NSNumber*)importImageAtPath:(NSString*)path error:(NSError**)error;  // asset id
- (BOOL)waitForMediaWithTimeout:(NSTimeInterval)seconds;               // tests / CLI only

// ---- layers (index 0 = top of the stack) ----
- (NSArray<MFLayerInfo*>*)layers;
- (nullable MFLayerInfo*)layerWithID:(uint64_t)layerID;
- (uint64_t)addShapeLayer:(MFShapeType)shape;
- (uint64_t)addImageLayerWithAsset:(uint64_t)assetID;
- (uint64_t)addNullLayer;
- (BOOL)removeLayer:(uint64_t)layerID;
- (uint64_t)duplicateLayer:(uint64_t)layerID;
- (BOOL)moveLayer:(uint64_t)layerID toIndex:(NSInteger)index;
- (BOOL)setLayer:(uint64_t)layerID name:(NSString*)name;
- (BOOL)setLayer:(uint64_t)layerID visible:(BOOL)visible;
- (BOOL)setLayer:(uint64_t)layerID inPoint:(double)inPoint outPoint:(double)outPoint;
- (BOOL)setLayer:(uint64_t)layerID parent:(uint64_t)parentID;
- (BOOL)setLayer:(uint64_t)layerID blendMode:(MFBlendMode)mode;
- (BOOL)setLayer:(uint64_t)layerID shapeType:(MFShapeType)shape;
- (BOOL)setLayer:(uint64_t)layerID fillEnabled:(BOOL)fill strokeEnabled:(BOOL)stroke;

// ---- effects, masks, track mattes ----
+ (NSArray<MFEffectCatalogEntry*>*)effectCatalog;
- (uint64_t)addEffect:(MFEffectType)type layer:(uint64_t)layerID;
- (BOOL)removeEffect:(uint64_t)effectID layer:(uint64_t)layerID;
- (BOOL)moveEffect:(uint64_t)effectID layer:(uint64_t)layerID toIndex:(NSInteger)index;
- (BOOL)setEffect:(uint64_t)effectID layer:(uint64_t)layerID enabled:(BOOL)enabled;
- (uint64_t)addMask:(MFMaskShape)shape layer:(uint64_t)layerID;
- (BOOL)removeMask:(uint64_t)maskID layer:(uint64_t)layerID;
- (BOOL)setMask:(uint64_t)maskID layer:(uint64_t)layerID mode:(MFMaskMode)mode inverted:(BOOL)inverted;
- (BOOL)setMask:(uint64_t)maskID layer:(uint64_t)layerID shape:(MFMaskShape)shape;
- (BOOL)setMask:(uint64_t)maskID layer:(uint64_t)layerID enabled:(BOOL)enabled;
// Uses `matteLayerID` as the layer's track matte (and hides the matte layer); 0 or None clears it.
- (BOOL)setLayer:(uint64_t)layerID matte:(uint64_t)matteLayerID mode:(MFMatteMode)mode;

// ---- properties & keyframes (any property, by reference) ----
- (MFValue)valueOfRef:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)setRefValue:(MFValue)value ref:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)setAnimated:(BOOL)animated ref:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)addKeyframeForRef:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)removeKeyframeAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID;
- (NSInteger)moveKeyframeAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID toTime:(double)time;
- (BOOL)setKeyframeInterpolationAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID
                                     in:(MFInterp)inInterp out:(MFInterp)outInterp;

// ---- properties & keyframes (layer properties) ----
- (MFValue)valueOf:(MFProp)prop layer:(uint64_t)layerID time:(double)time;
- (BOOL)setPropertyValue:(MFValue)value prop:(MFProp)prop layer:(uint64_t)layerID time:(double)time;
- (BOOL)setAnimated:(BOOL)animated prop:(MFProp)prop layer:(uint64_t)layerID time:(double)time;
- (BOOL)addKeyframeForProp:(MFProp)prop layer:(uint64_t)layerID time:(double)time;
- (BOOL)removeKeyframeAtIndex:(NSInteger)index prop:(MFProp)prop layer:(uint64_t)layerID;
- (NSInteger)moveKeyframeAtIndex:(NSInteger)index prop:(MFProp)prop layer:(uint64_t)layerID toTime:(double)time;
- (BOOL)setKeyframeInterpolationAtIndex:(NSInteger)index prop:(MFProp)prop layer:(uint64_t)layerID
                                     in:(MFInterp)inInterp out:(MFInterp)outInterp;

// ---- viewer ----
- (uint64_t)hitTestAtPoint:(CGPoint)compPoint time:(double)time;
- (MFQuad)quadForLayer:(uint64_t)layerID time:(double)time;
// Converts a composition-space offset into the layer's parent space (identity when unparented),
// so viewer drags move parented layers exactly under the cursor.
- (CGPoint)parentSpaceVector:(CGPoint)compVector layer:(uint64_t)layerID time:(double)time;
- (MFQuad)quadForMask:(uint64_t)maskID layer:(uint64_t)layerID time:(double)time;
// Renders the composition at `time` (quality divisor 1/2/4) and presents it into the view with
// the composition's top-left at `origin` (drawable pixels) and `scale` drawable px per comp px.
// Never waits for the GPU: if too many frames are in flight it skips and reports `skipped`.
- (MFViewerFrameInfo*)drawInView:(MTKView*)view
                            time:(double)time
                    qualityDivisor:(NSInteger)divisor
                          origin:(CGPoint)origin
                           scale:(double)scale
                    checkerboard:(BOOL)checkerboard;

// ---- offscreen rendering ----
- (nullable CGImageRef)copyImageAtTime:(double)time scale:(double)scale
                            transparent:(BOOL)transparent error:(NSError**)error CF_RETURNS_RETAINED;
- (BOOL)writePNGAtTime:(double)time scale:(double)scale transparent:(BOOL)transparent
                toPath:(NSString*)path error:(NSError**)error;

// ---- frame cache & background rendering ----
@property(nonatomic) MFCachePolicy cachePolicy;
// Renders up to `count` frames after `time` into the frame cache, on the GPU, without blocking.
// Only frames the cache policy would keep are rendered (cheap frames are drawn on demand).
// Returns how many frames were queued.
- (NSInteger)prefetchFromTime:(double)time frames:(NSInteger)count qualityDivisor:(NSInteger)divisor loop:(BOOL)loop;
// Frame indices of the current document state that are in the cache at this preview resolution
// (for the timeline's cache bar). May under-report after an edit until frames are revisited.
- (NSIndexSet*)cachedFramesForQualityDivisor:(NSInteger)divisor;

// ---- memory & stats ----
@property(nonatomic) uint64_t cacheBudgetBytes;
- (void)purgeFrameCache;
- (void)handleMemoryPressure:(MFMemoryPressure)level;
- (MFRenderStats*)stats;
- (void)resetStats;

@end

NS_ASSUME_NONNULL_END

// MotionForge — Objective-C bridge between the C++ engine (document, evaluation, Metal renderer)
// and the Swift/SwiftUI application. Pure Objective-C so Swift can import it directly.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MFLayerKind) { MFLayerKindShape = 0, MFLayerKindImage, MFLayerKindNull, MFLayerKindText, MFLayerKindPrecomp };
typedef NS_ENUM(NSInteger, MFShapeType) { MFShapeTypeRectangle = 0, MFShapeTypeEllipse, MFShapeTypePolygon, MFShapeTypeStar, MFShapeTypePath };
typedef NS_ENUM(NSInteger, MFBlendMode) {
    MFBlendModeNormal = 0, MFBlendModeAdd, MFBlendModeMultiply, MFBlendModeScreen,
    MFBlendModeOverlay, MFBlendModeDarken, MFBlendModeLighten
};
typedef NS_ENUM(NSInteger, MFInterp) { MFInterpLinear = 0, MFInterpHold, MFInterpBezier };
// Motion-path shape through a keyframe of a spatial property (position).
typedef NS_ENUM(NSInteger, MFSpatial) { MFSpatialLinear = 0, MFSpatialAuto, MFSpatialBezier };
typedef NS_ENUM(NSInteger, MFProp) {
    MFPropAnchorPoint = 0, MFPropPosition, MFPropScale, MFPropRotation, MFPropOpacity,
    MFPropSize, MFPropRoundness, MFPropFillColor, MFPropStrokeColor, MFPropStrokeWidth,
    MFPropPoints, MFPropInnerRatio, MFPropFontSize, MFPropTracking, MFPropLineHeight,
    MFPropTrimStart, MFPropTrimEnd, MFPropTrimOffset, MFPropTimeRemap
};
typedef NS_ENUM(NSInteger, MFMemoryPressure) { MFMemoryPressureNormal = 0, MFMemoryPressureWarning, MFMemoryPressureCritical };
typedef NS_ENUM(NSInteger, MFEffectType) {
    MFEffectTypeGaussianBlur = 0, MFEffectTypeDropShadow, MFEffectTypeGlow,
    MFEffectTypeBrightnessContrast, MFEffectTypeHueSaturation, MFEffectTypeFill, MFEffectTypeGradientRamp
};
typedef NS_ENUM(NSInteger, MFMaskShape) { MFMaskShapeRectangle = 0, MFMaskShapeEllipse, MFMaskShapePath };
typedef NS_ENUM(NSInteger, MFMaskMode) { MFMaskModeAdd = 0, MFMaskModeSubtract, MFMaskModeIntersect, MFMaskModeDifference };
typedef NS_ENUM(NSInteger, MFMatteMode) {
    MFMatteModeNone = 0, MFMatteModeAlpha, MFMatteModeAlphaInverted, MFMatteModeLuma, MFMatteModeLumaInverted
};
typedef NS_ENUM(NSInteger, MFCachePolicy) { MFCachePolicySmart = 0, MFCachePolicyAll, MFCachePolicyOff };
typedef NS_ENUM(NSInteger, MFPropOwner) { MFPropOwnerLayer = 0, MFPropOwnerMask, MFPropOwnerEffect, MFPropOwnerTextAnimator };
typedef NS_ENUM(NSInteger, MFTextAlign) { MFTextAlignLeft = 0, MFTextAlignCenter, MFTextAlignRight };
typedef NS_ENUM(NSInteger, MFSelectorShape) {
    MFSelectorShapeSquare = 0, MFSelectorShapeRampUp, MFSelectorShapeRampDown, MFSelectorShapeTriangle,
    MFSelectorShapeRound, MFSelectorShapeSmooth
};
typedef NS_ENUM(NSInteger, MFSelectorUnit) { MFSelectorUnitCharacters = 0, MFSelectorUnitWords, MFSelectorUnitLines };
typedef NS_ENUM(NSInteger, MFAnimatorPreset) {
    MFAnimatorPresetOpacity = 0, MFAnimatorPresetPosition, MFAnimatorPresetScale, MFAnimatorPresetRotation
};

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

@class MFParamInfo;

// Immutable snapshots handed to the UI. Re-fetch after `revision` changes.
@interface MFKeyframeInfo : NSObject
@property(nonatomic, readonly) NSInteger index;
@property(nonatomic, readonly) double time;
@property(nonatomic, readonly) MFValue value;
@property(nonatomic, readonly) MFInterp inInterp;
@property(nonatomic, readonly) MFInterp outInterp;
@property(nonatomic, readonly) MFSpatial spatial;
@property(nonatomic, readonly) MFValue tangentIn;   // Bezier handles, relative to the value
@property(nonatomic, readonly) MFValue tangentOut;
@property(nonatomic, readonly) double easeIn;       // influence 0–1 (graph editor)
@property(nonatomic, readonly) double easeOut;
@property(nonatomic, readonly) double inSlope;      // speed as a timing-curve slope
@property(nonatomic, readonly) double outSlope;
@end

// A bezier path vertex; tangents are offsets from the point.
@interface MFPathVertex : NSObject
- (instancetype)initWithPoint:(CGPoint)point inTangent:(CGPoint)inTangent outTangent:(CGPoint)outTangent;
@property(nonatomic, readonly) CGPoint point;
@property(nonatomic, readonly) CGPoint inTangent;
@property(nonatomic, readonly) CGPoint outTangent;
@end

@interface MFAnimatorInfo : NSObject
@property(nonatomic, readonly) uint64_t animatorID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) MFSelectorShape shape;
@property(nonatomic, readonly) MFSelectorUnit unit;
@property(nonatomic, readonly) NSArray<MFParamInfo*>* params;
@end

@interface MFPresetInfo : NSObject
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* category;
@property(nonatomic, readonly, copy) NSString* summary;
@property(nonatomic, readonly, copy) NSString* json;
+ (nullable MFPresetInfo*)presetWithJSON:(NSString*)json;  // reads name/category from a saved preset
@end

// A keyframe anywhere in the composition (for multi-selection operations).
@interface MFKeyAddress : NSObject
- (instancetype)initWithLayer:(uint64_t)layerID ref:(MFPropRef)ref index:(NSInteger)index;
@property(nonatomic, readonly) uint64_t layerID;
@property(nonatomic, readonly) MFPropRef ref;
@property(nonatomic, readonly) NSInteger index;
@end

// A layer's position motion path, in composition pixels at the current parent transform.
@interface MFMotionPathKey : NSObject
@property(nonatomic, readonly) NSInteger index;
@property(nonatomic, readonly) double time;
@property(nonatomic, readonly) CGPoint point;
@property(nonatomic, readonly) CGPoint inHandle;   // absolute positions of the resolved handles
@property(nonatomic, readonly) CGPoint outHandle;
@property(nonatomic, readonly) MFSpatial spatial;
@end

@interface MFMotionPath : NSObject
@property(nonatomic, readonly) MFPropRef ref;
@property(nonatomic, readonly) NSArray<NSValue*>* points;  // CGPoint values along the path
@property(nonatomic, readonly) NSArray<MFMotionPathKey*>* keys;
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
// Baked (per-frame) animation, e.g. from an After Effects import: editing shifts the whole track.
- (BOOL)isBakedRef:(MFPropRef)ref;
@property(nonatomic, readonly) BOOL hasBakedAnimation;  // any property, mask path or shape path
@property(nonatomic, readonly) NSArray<NSNumber*>* allKeyframeTimes;  // union over every property, sorted
@property(nonatomic, readonly) NSArray<MFEffectInfo*>* effects;
@property(nonatomic, readonly) NSArray<MFMaskInfo*>* masks;
@property(nonatomic, readonly) NSArray<MFParamInfo*>* animatedEffectAndMaskParams;  // for timeline rows
@property(nonatomic, readonly) uint64_t matteLayerID;
@property(nonatomic, readonly) MFMatteMode matteMode;
// Text layers
@property(nonatomic, readonly, copy) NSString* text;
@property(nonatomic, readonly, copy) NSString* fontName;
@property(nonatomic, readonly) MFTextAlign textAlign;
@property(nonatomic, readonly) NSArray<MFAnimatorInfo*>* animators;
// Bezier path shape layers (layer space)
@property(nonatomic, readonly) NSArray<MFPathVertex*>* pathVertices;
@property(nonatomic, readonly) BOOL pathClosed;
// Precomp layers
@property(nonatomic, readonly) uint64_t sourceCompID;
@property(nonatomic, readonly) double startTime;
@property(nonatomic, readonly) BOOL timeRemapEnabled;
@property(nonatomic, readonly) BOOL collapse;
@end

@interface MFCompositionInfo : NSObject
@property(nonatomic, readonly) uint64_t compID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) double fps;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) MFValue background;
@property(nonatomic, readonly, copy) NSString* folder;  // "" = top level
@property(nonatomic, readonly) NSInteger layerCount;
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
// Every composition in the project; `composition` is the one being edited.
@property(nonatomic, readonly) NSArray<MFCompositionInfo*>* compositions;
- (BOOL)openComposition:(uint64_t)compID NS_SWIFT_NAME(openComposition(_:));
- (uint64_t)addCompositionNamed:(NSString*)name width:(NSInteger)width height:(NSInteger)height fps:(double)fps
                       duration:(double)duration NS_SWIFT_NAME(addComposition(name:width:height:fps:duration:));
// A layer showing another composition (0 if it would make a composition contain itself).
- (uint64_t)addPrecompLayer:(uint64_t)sourceCompID NS_SWIFT_NAME(addPrecompLayer(source:));
- (BOOL)setPrecompLayer:(uint64_t)layerID collapse:(BOOL)collapse timeRemap:(BOOL)timeRemap startTime:(double)startTime
    NS_SWIFT_NAME(setPrecomp(_:collapse:timeRemap:startTime:));

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
- (BOOL)removeLayers:(NSArray<NSNumber*>*)layerIDs NS_SWIFT_NAME(removeLayers(_:));  // one undo step
- (NSArray<NSNumber*>*)duplicateLayers:(NSArray<NSNumber*>*)layerIDs NS_SWIFT_NAME(duplicateLayers(_:));  // new ids, top first
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

// ---- text ----
- (uint64_t)addTextLayer:(NSString*)text NS_SWIFT_NAME(addTextLayer(_:));
- (BOOL)setLayer:(uint64_t)layerID text:(NSString*)text font:(NSString*)font align:(MFTextAlign)align
    NS_SWIFT_NAME(setLayer(_:text:font:align:));
- (uint64_t)addTextAnimator:(MFAnimatorPreset)preset layer:(uint64_t)layerID NS_SWIFT_NAME(addTextAnimator(_:layer:));
- (BOOL)removeTextAnimator:(uint64_t)animatorID layer:(uint64_t)layerID NS_SWIFT_NAME(removeTextAnimator(_:layer:));
- (BOOL)setTextAnimator:(uint64_t)animatorID layer:(uint64_t)layerID enabled:(BOOL)enabled shape:(MFSelectorShape)shape
                   unit:(MFSelectorUnit)unit NS_SWIFT_NAME(setTextAnimator(_:layer:enabled:shape:unit:));

// ---- bezier paths (pen tool) ----
// Vertices in composition space; the new layer sits at the path's centre.
- (uint64_t)addPathLayerWithVertices:(NSArray<MFPathVertex*>*)vertices closed:(BOOL)closed
    NS_SWIFT_NAME(addPathLayer(vertices:closed:));
// Vertices in the layer's own space.
- (BOOL)setLayer:(uint64_t)layerID pathVertices:(NSArray<MFPathVertex*>*)vertices closed:(BOOL)closed
    NS_SWIFT_NAME(setLayer(_:pathVertices:closed:));
- (uint64_t)addPathMaskWithVertices:(NSArray<MFPathVertex*>*)vertices layer:(uint64_t)layerID
    NS_SWIFT_NAME(addPathMask(vertices:layer:));
// Composition space <-> a layer's own space at `time` (inverse of its full parent chain).
- (CGPoint)compPoint:(CGPoint)p toLayer:(uint64_t)layerID time:(double)time NS_SWIFT_NAME(compToLayer(_:layer:time:));
- (CGPoint)layerPoint:(CGPoint)p ofLayer:(uint64_t)layerID time:(double)time NS_SWIFT_NAME(layerToComp(_:layer:time:));

// ---- presets ----
+ (NSArray<MFPresetInfo*>*)builtInPresets;
- (NSString*)presetFromLayer:(uint64_t)layerID name:(NSString*)name category:(NSString*)category
    NS_SWIFT_NAME(preset(fromLayer:name:category:));
- (NSInteger)applyPreset:(NSString*)json layers:(NSArray<NSNumber*>*)layerIDs time:(double)time
                 message:(NSString* _Nullable* _Nullable)message NS_SWIFT_NAME(applyPreset(_:layers:time:message:));

// ---- properties & keyframes (any property, by reference) ----
- (MFValue)valueOfRef:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)setRefValue:(MFValue)value ref:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)setAnimated:(BOOL)animated ref:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)addKeyframeForRef:(MFPropRef)ref layer:(uint64_t)layerID time:(double)time;
- (BOOL)removeKeyframeAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID;
- (NSInteger)moveKeyframeAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID toTime:(double)time;
- (BOOL)setKeyframeInterpolationAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID
                                     in:(MFInterp)inInterp out:(MFInterp)outInterp;
// Graph editor: one side of a key becomes Bezier with this influence (0–1) and speed (slope).
- (BOOL)setKeyframeEaseAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID outgoing:(BOOL)outgoing
                     influence:(double)influence slope:(double)slope
    NS_SWIFT_NAME(setKeyframeEase(at:ref:layer:outgoing:influence:slope:));
- (BOOL)setKeyframeValueAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID value:(MFValue)value
    NS_SWIFT_NAME(setKeyframeValue(at:ref:layer:value:));
- (BOOL)setKeyframeSpatialAtIndex:(NSInteger)index ref:(MFPropRef)ref layer:(uint64_t)layerID
                             mode:(MFSpatial)mode tangentIn:(MFValue)tangentIn tangentOut:(MFValue)tangentOut
    NS_SWIFT_NAME(setKeyframeSpatial(at:ref:layer:mode:tangentIn:tangentOut:));

// ---- several keyframes at once (one undo step each) ----
- (NSArray<MFKeyAddress*>*)moveKeyframes:(NSArray<MFKeyAddress*>*)keys by:(double)dt
    NS_SWIFT_NAME(moveKeyframes(_:by:));  // new addresses, same order
- (BOOL)removeKeyframes:(NSArray<MFKeyAddress*>*)keys NS_SWIFT_NAME(removeKeyframes(_:));
- (BOOL)setInterpolationForKeyframes:(NSArray<MFKeyAddress*>*)keys
                                  in:(MFInterp)inInterp
                                 out:(MFInterp)outInterp
                               setIn:(BOOL)setIn
                              setOut:(BOOL)setOut
    NS_SWIFT_NAME(setInterpolation(of:in:out:setIn:setOut:));

// ---- motion paths ----
- (nullable MFMotionPath*)motionPathForLayer:(uint64_t)layerID time:(double)time
    NS_SWIFT_NAME(motionPath(layer:time:));  // nil unless position is animated

// ---- clipboard (JSON strings for the system pasteboard) ----
- (NSString*)clipboardForLayers:(NSArray<NSNumber*>*)layerIDs NS_SWIFT_NAME(clipboard(forLayers:));
- (NSString*)clipboardForKeyframes:(NSArray<MFKeyAddress*>*)keys NS_SWIFT_NAME(clipboard(forKeyframes:));
- (NSInteger)clipboardKind:(NSString*)text NS_SWIFT_NAME(clipboardKind(_:));  // 0 none, 1 layers, 2 keyframes
// Pastes at stack index (0 = top); returns the new layer ids (top first), or nil with `error`.
- (nullable NSArray<NSNumber*>*)pasteLayers:(NSString*)text atIndex:(NSInteger)index error:(NSError**)error
    NS_SWIFT_NAME(pasteLayers(_:at:));
// Earliest key lands at `time`. Returns keys written; `message` explains skipped tracks.
- (NSInteger)pasteKeyframes:(NSString*)text
                     layers:(NSArray<NSNumber*>*)layerIDs
                       time:(double)time
                    message:(NSString* _Nullable* _Nullable)message
    NS_SWIFT_NAME(pasteKeyframes(_:layers:time:message:));

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
// Rendered stills / exports use the composition's motion blur (subframes averaged) unless this is NO.
@property(nonatomic) BOOL renderMotionBlur;
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

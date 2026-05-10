#import "SakuraNeuralUpscale.h"
#import "SakuraBridge.h"

#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>

#import <algorithm>
#import <cmath>
#include <atomic>

static NSString * const kSakuraNeuralImportedModelsSubdir = @"NeuralUpscaleModels";
static NSString * const kSakuraNeuralLegacyImportedModelsSubdir = @"JKTModels";
static const NSInteger kMaxTiles = 8192;
static const NSUInteger kNeuralBatchFlush = 16;
static const NSUInteger kNeuralLiveMaxSide = 3840;
static const NSUInteger kNeuralLiveMaxPixels = 3840u * 2160u;

static inline float SakuraNeuralClampUnitTo255(float u)
{
    float t = u * 255.f;
    return t <= 0.f ? 0.f : (t >= 255.f ? 255.f : t);
}

static NSInteger SakuraIntGCD(NSInteger a, NSInteger b)
{
    if (a < 0)
        a = -a;
    if (b < 0)
        b = -b;
    while (b != 0) {
        NSInteger t = a % b;
        a = b;
        b = t;
    }
    return MAX(a, 1);
}

static void SakuraMetalDispatchCompute2D(id<MTLComputeCommandEncoder> ce, NSUInteger gw, NSUInteger gh)
{
    if (!ce || gw < 1 || gh < 1)
        return;
    const NSUInteger bx = 8u;
    MTLSize tpt = MTLSizeMake(std::min(bx, gw), std::min(bx, gh), 1);
    MTLSize tbg = MTLSizeMake((gw + tpt.width - 1u) / tpt.width, (gh + tpt.height - 1u) / tpt.height, 1);
    [ce dispatchThreadgroups:tbg threadsPerThreadgroup:tpt];
}

@interface SakuraNeuralUpscale ()
- (BOOL)loadModelIfNeededUnlocked:(NSError **)error;
- (void)sakuraEnsureMetalTexCacheLockedForDevice:(id<MTLDevice>)device;
- (void)sakuraInvalidateIOSurfaceBridgingFullyLocked;
- (BOOL)sakuraEnsureSurfRingLockedForWidth:(NSUInteger)w height:(NSUInteger)h;
- (void)sakuraEnsureNeuralCompositePipelinesLockedForDevice:(id<MTLDevice>)device;
- (NSData *)sakuraNeuralUpscaleInferFromBGRABase:(const uint8_t *)inferBase
                                        rowBytes:(size_t)inferRow
                                             workW:(NSUInteger)workW
                                             workH:(NSUInteger)workH
                                             snapNum:(NSUInteger)snapNum
                                             snapDen:(NSUInteger)snapDen
                                                   tin:(NSInteger)tin tout:(NSInteger)tout
                                                   runModel:(MLModel *)runModel runIn:(NSString *)runIn runOut:(NSString *)runOut
                                    compositeDevice:(nullable id<MTLDevice>)compositeDev
                                             texCache:(nullable CVMetalTextureCacheRef)texCache
                                           predOptions:(nullable MLPredictionOptions *)predOpts
                                                  error:(NSError **)error
                                       usedScaleNumOut:(NSUInteger *_Nullable)snumOpt
                                       usedScaleDenOut:(NSUInteger *_Nullable)sdenOpt
                                    usedOutputWidthOut:(NSUInteger *_Nullable)oWOpt
                                   usedOutputHeightOut:(NSUInteger *_Nullable)oHOpt
                                                outTex:(out id<MTLTexture> _Nullable *__nullable)outTex;
- (CVPixelBufferRef _Nullable)sakuraBorrowBatchedTilePixelBufferForTin:(NSInteger)tin;
@end

@implementation SakuraNeuralUpscale {
    MLModel *__model;
    NSString *__loadedKey;
    NSString *__loadBlockedSel;
    NSString *__inputName;
    NSString *__outputName;
    NSInteger __inW;
    NSInteger __inH;
    NSInteger __outW;
    NSInteger __outH;
    NSInteger __scaleNum;
    NSInteger __scaleDen;
    dispatch_queue_t __loadQueue;
    BOOL __prewarmRequested;
    id<MTLDevice> __cacheMetalDevice;
    BOOL __outputIsBGRACVPixelBuffer;
    BOOL __warmupInFlight;
    CVMetalTextureCacheRef __metalTexCache;
    CVPixelBufferRef __surfRing[4];
    NSUInteger __surfRingW;
    NSUInteger __surfRingH;
    uint32_t __surfRingCursor;
    id<MTLCommandQueue> __neuralMetalQueue;
    id<MTLComputePipelineState> __neuralClearPso;
    id<MTLComputePipelineState> __neuralAccumPso;
    id<MTLComputePipelineState> __neuralFinalPso;
    id<MTLLibrary> __presentationMetallib;
    id<MTLDevice> __compositeDev;
    dispatch_queue_t __neuralInferQueue;
    std::atomic<int> __neuralInferFlight;
    id<MTLTexture> __neuralLatestTex;
    NSUInteger __neuralLatestSurfW;
    NSUInteger __neuralLatestSurfH;
    id<MTLDevice> __neuralLatestDev;
    NSString *__neuralLatestModelKey;
    CVPixelBufferPoolRef __tilePixelBufferPool;
    NSInteger __tilePixelBufferPoolTin;
    std::atomic<uint64_t> __neuralLiveGeneration;
    std::atomic<uint64_t> __neuralCommitCount;
}

+ (instancetype)shared
{
    static SakuraNeuralUpscale *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[SakuraNeuralUpscale alloc] init];
        s->__loadQueue = dispatch_queue_create("sakura.neural.load", DISPATCH_QUEUE_SERIAL);
        s->__prewarmRequested = NO;
        s->__cacheMetalDevice = nil;
        s->__outputIsBGRACVPixelBuffer = NO;
        s->__metalTexCache = NULL;
        s->__surfRingW = s->__surfRingH = 0;
        s->__surfRingCursor = 0;
        for (unsigned i = 0; i < 4; i++)
            s->__surfRing[i] = NULL;
        s->__neuralMetalQueue = nil;
        s->__neuralClearPso = nil;
        s->__neuralAccumPso = nil;
        s->__neuralFinalPso = nil;
        dispatch_queue_attr_t inferAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        s->__neuralInferQueue = dispatch_queue_create("sakura.neural.infer", inferAttr);
        s->__neuralInferFlight.store(0, std::memory_order_relaxed);
        s->__neuralLatestTex = nil;
        s->__neuralLatestSurfW = s->__neuralLatestSurfH = 0;
        s->__neuralLatestDev = nil;
        s->__neuralLatestModelKey = nil;
        s->__tilePixelBufferPool = NULL;
        s->__tilePixelBufferPoolTin = 0;
        s->__presentationMetallib = nil;
        s->__compositeDev = nil;
        s->__neuralLiveGeneration.store(0, std::memory_order_relaxed);
        s->__neuralCommitCount.store(0, std::memory_order_relaxed);
    });
    return s;
}

- (uint64_t)neuralOutputCommitCount
{
    return __neuralCommitCount.load(std::memory_order_relaxed);
}

- (void)dealloc
{
    [self endNeuralLiveSession];
}

- (void)sakuraReleaseSurfRingOnlyLocked
{
    for (int i = 0; i < 4; i++) {
        if (__surfRing[i]) {
            CFRelease(__surfRing[i]);
            __surfRing[i] = NULL;
        }
    }
    __surfRingW = __surfRingH = 0;
    __surfRingCursor = 0;
}

- (void)sakuraTeardownNeuralMetalCompositeLocked
{
    __neuralClearPso = nil;
    __neuralAccumPso = nil;
    __neuralFinalPso = nil;
    __presentationMetallib = nil;
    __neuralMetalQueue = nil;
    __compositeDev = nil;
}

- (void)sakuraInvalidateIOSurfaceBridgingFullyLocked
{
    if (__metalTexCache) {
        CVMetalTextureCacheFlush(__metalTexCache, 0);
        CFRelease(__metalTexCache);
        __metalTexCache = NULL;
    }
    [self sakuraReleaseSurfRingOnlyLocked];
    [self sakuraTeardownNeuralMetalCompositeLocked];
}

- (void)sakuraEnsureMetalTexCacheLockedForDevice:(id<MTLDevice>)device
{
    if (!device)
        return;
    if (__metalTexCache && __cacheMetalDevice == device)
        return;
    if (__metalTexCache) {
        CFRelease(__metalTexCache);
        __metalTexCache = NULL;
    }
    __cacheMetalDevice = device;
    CVReturn c = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &__metalTexCache);
    if (c != kCVReturnSuccess || !__metalTexCache)
        SakuraLogUnified(@"Neural", @"Warning", @"CVMetalTextureCacheCreate failed; live IOSurface neural readback degrades");
}

- (BOOL)sakuraEnsureSurfRingLockedForWidth:(NSUInteger)w height:(NSUInteger)h
{
    if (w < 2 || h < 2)
        return NO;
    if (__surfRingW == w && __surfRingH == h && __surfRing[0] != NULL && __surfRing[1] != NULL && __surfRing[2] != NULL && __surfRing[3] != NULL)
        return YES;
    [self sakuraReleaseSurfRingOnlyLocked];
    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    for (unsigned i = 0; i < 4u; i++) {
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb)
            goto fail_ring;
        __surfRing[i] = pb;
    }
    __surfRingW = w;
    __surfRingH = h;
    __surfRingCursor = 0;
    return YES;
fail_ring:
    [self sakuraReleaseSurfRingOnlyLocked];
    return NO;
}

- (CVPixelBufferRef _Nullable)sakuraBorrowSurfSlotLockedUpdatingCursor
{
    if (__surfRingW < 2 || __surfRingH < 2)
        return NULL;
    NSUInteger idx = (NSUInteger)(__surfRingCursor++ % 4u);
    return __surfRing[idx];
}

- (void)sakuraEnsureNeuralCompositePipelinesLockedForDevice:(id<MTLDevice>)device
{
    if (!device)
        return;
    if (__neuralAccumPso && __neuralFinalPso && __neuralClearPso && __compositeDev == device)
        return;
    [self sakuraTeardownNeuralMetalCompositeLocked];
    __compositeDev = device;
    NSURL *libURL = [[NSBundle mainBundle] URLForResource:@"SakuraPresentation" withExtension:@"metallib"];
    if (!libURL)
        return;
    NSError *le = nil;
    id<MTLLibrary> lib = [device newLibraryWithURL:libURL error:&le];
    if (!lib) {
        SakuraLogUnified(@"Neural", @"Warning",
            [NSString stringWithFormat:@"SakuraPresentation.metallib load failed (GPU neural composite off): %@", le.localizedDescription ?: @""]);
        return;
    }
    id<MTLFunction> fnClear = [lib newFunctionWithName:@"sakura_neural_accum_clear"];
    id<MTLFunction> fnAcc = [lib newFunctionWithName:@"sakura_neural_tile_accumulate"];
    id<MTLFunction> fnFin = [lib newFunctionWithName:@"sakura_neural_finalize"];
    if (!fnClear || !fnAcc || !fnFin)
        return;
    NSError *pe = nil;
    __neuralClearPso = [device newComputePipelineStateWithFunction:fnClear error:&pe];
    if (!__neuralClearPso)
        return;
    __neuralAccumPso = [device newComputePipelineStateWithFunction:fnAcc error:&pe];
    if (!__neuralAccumPso)
        return;
    __neuralFinalPso = [device newComputePipelineStateWithFunction:fnFin error:&pe];
    if (!__neuralFinalPso)
        return;
    __presentationMetallib = lib;
    __neuralMetalQueue = [device newCommandQueue];
}

- (void)beginNeuralLiveSession:(id<MTLDevice>)device
{
    if (!device)
        return;
    @synchronized (self) {
        if (__cacheMetalDevice && __cacheMetalDevice != device)
            [self sakuraInvalidateIOSurfaceBridgingFullyLocked];
        __cacheMetalDevice = device;
        [self sakuraEnsureMetalTexCacheLockedForDevice:device];
    }
}

- (void)endNeuralLiveSession
{
    __neuralLiveGeneration.fetch_add(1, std::memory_order_acq_rel);
    __neuralInferFlight.store(0, std::memory_order_release);
    @synchronized (self) {
        __neuralLatestTex = nil;
        __neuralLatestSurfW = __neuralLatestSurfH = 0;
        __neuralLatestDev = nil;
        __neuralLatestModelKey = nil;
        if (__tilePixelBufferPool) {
            CFRelease(__tilePixelBufferPool);
            __tilePixelBufferPool = NULL;
        }
        __tilePixelBufferPoolTin = 0;
        __cacheMetalDevice = nil;
        [self sakuraInvalidateIOSurfaceBridgingFullyLocked];
    }
}

- (CVPixelBufferRef _Nullable)sakuraBorrowBatchedTilePixelBufferForTin:(NSInteger)tin
{
    if (tin < 2)
        return NULL;
    @synchronized (self) {
        if (__tilePixelBufferPoolTin != tin || __tilePixelBufferPool == NULL) {
            if (__tilePixelBufferPool) {
                CFRelease(__tilePixelBufferPool);
                __tilePixelBufferPool = NULL;
            }
            __tilePixelBufferPoolTin = tin;
            NSDictionary *pbAttrs = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferWidthKey : @(tin),
                (id)kCVPixelBufferHeightKey : @(tin),
                (id)kCVPixelBufferMetalCompatibilityKey : @YES,
                (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
                (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            };
            NSDictionary *poolAttrs = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey : @8 };
            CVReturn pc = CVPixelBufferPoolCreate(
                kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttrs, (__bridge CFDictionaryRef)pbAttrs, &__tilePixelBufferPool);
            if (pc != kCVReturnSuccess || __tilePixelBufferPool == NULL) {
                __tilePixelBufferPoolTin = 0;
                return NULL;
            }
        }
        CVPixelBufferRef pb = NULL;
        CVReturn c2 = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, __tilePixelBufferPool, &pb);
        if (c2 != kCVReturnSuccess || !pb)
            return NULL;
        return pb;
    }
}

- (void)prewarmLiveSessionForLastKnownSurface
{
    @synchronized (self) {
        __prewarmRequested = YES;
        id<MTLDevice> dev = __cacheMetalDevice;
        NSUInteger pw = __surfRingW;
        NSUInteger ph = __surfRingH;
        if (dev) {
            [self sakuraEnsureMetalTexCacheLockedForDevice:dev];
            if (pw >= 2 && ph >= 2)
                [self sakuraEnsureSurfRingLockedForWidth:pw height:ph];
            [self sakuraEnsureNeuralCompositePipelinesLockedForDevice:dev];
        }
    }
}


- (void)warmUpAsync
{
    BOOL live = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_live" defaultValue:NO];
    BOOL texArt = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_texture_art" defaultValue:NO];
    if (!live && !texArt)
        return;
    NSString *sel = [SakuraBridge getINIString:@"EmuCore/GS" key:@"neural_upscale_model" defaultValue:@"bundle"];
    @synchronized (self) {
        if (sel.length && __loadBlockedSel.length && [__loadBlockedSel isEqualToString:sel])
            return;
        if (__warmupInFlight)
            return;
        __warmupInFlight = YES;
    }
    dispatch_async(__loadQueue, ^{
        NSError *err = nil;
        [self loadModelIfNeeded:&err];
        @synchronized (self) {
            __warmupInFlight = NO;
        }
    });
}

- (void)invalidateCompiledModelCache
{
    __neuralLiveGeneration.fetch_add(1, std::memory_order_acq_rel);
    __neuralInferFlight.store(0, std::memory_order_release);
    @synchronized (self) {
        __neuralLatestTex = nil;
        __neuralLatestSurfW = __neuralLatestSurfH = 0;
        __neuralLatestDev = nil;
        __neuralLatestModelKey = nil;
        if (__tilePixelBufferPool) {
            CFRelease(__tilePixelBufferPool);
            __tilePixelBufferPool = NULL;
        }
        __tilePixelBufferPoolTin = 0;
        __model = nil;
        __loadedKey = nil;
        __inputName = nil;
        __outputName = nil;
        __inW = __inH = __outW = __outH = __scaleNum = __scaleDen = 0;
        __loadBlockedSel = nil;
        __outputIsBGRACVPixelBuffer = NO;
        __cacheMetalDevice = nil;
        [self sakuraInvalidateIOSurfaceBridgingFullyLocked];
    }
}

- (NSURL *)importedNeuralModelsDirectoryURL
{
    NSString *docs = [SakuraBridge documentsDirectory];
    if (!docs.length)
        return nil;
    NSURL *base = [NSURL fileURLWithPath:docs isDirectory:YES];
    NSURL *current = [base URLByAppendingPathComponent:kSakuraNeuralImportedModelsSubdir isDirectory:YES];
    NSURL *legacy = [base URLByAppendingPathComponent:kSakuraNeuralLegacyImportedModelsSubdir isDirectory:YES];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL legacyIsDir = NO;
    if ([fm fileExistsAtPath:legacy.path isDirectory:&legacyIsDir] && legacyIsDir && ![fm fileExistsAtPath:current.path]) {
        [fm moveItemAtURL:legacy toURL:current error:nil];
    }
    return current;
}

- (NSURL *)bundledFastSRGANURL
{
    return [[NSBundle mainBundle] URLForResource:@"Fast-SRGAN" withExtension:@"mlmodel" subdirectory:@"NeuralUpscale"];
}

- (NSURL *)resolvedModelURL:(NSString *)modelSel
{
    if (!modelSel.length || [modelSel isEqualToString:@"bundle"]) {
        return [self bundledFastSRGANURL];
    }
    static NSString *bundledPrefix = @"bundled:";
    if ([modelSel hasPrefix:bundledPrefix]) {
        NSString *fn = [[modelSel substringFromIndex:bundledPrefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!fn.length)
            return nil;
        if ([fn containsString:@".."])
            return nil;
        NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:"];
        if ([fn rangeOfCharacterFromSet:illegal].location != NSNotFound)
            return nil;
        NSString *base = [fn stringByDeletingPathExtension];
        NSString *ext = [fn pathExtension];
        if (!base.length || !ext.length)
            return nil;
        return [[NSBundle mainBundle] URLForResource:base withExtension:ext subdirectory:@"NeuralUpscale"];
    }
    static NSString *importPrefix = @"neuralimport:";
    static NSString *legacyPrefix = @"jkt:";
    NSString *usedPrefix = nil;
    if ([modelSel hasPrefix:importPrefix])
        usedPrefix = importPrefix;
    else if ([modelSel hasPrefix:legacyPrefix])
        usedPrefix = legacyPrefix;
    if (usedPrefix) {
        NSString *fn = [[modelSel substringFromIndex:usedPrefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!fn.length)
            return nil;
        NSURL *dir = [self importedNeuralModelsDirectoryURL];
        if (!dir)
            return nil;
        return [dir URLByAppendingPathComponent:fn];
    }
    return nil;
}

static BOOL SakuraMLImageConstraintFixedSize(MLImageConstraint *ic, NSInteger *outW, NSInteger *outH)
{
    if (!ic || !outW || !outH)
        return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const NSInteger w = ic.pixelsWide;
    const NSInteger h = ic.pixelsHigh;
#pragma clang diagnostic pop
    if (w > 0 && h > 0) {
        *outW = w;
        *outH = h;
        return YES;
    }
    return NO;
}

static BOOL SakuraProbeNeuralDims(MLModel *m, NSString **inNameOut, NSString **outNameOut, NSInteger *tinOut, NSInteger *toutOut,
    BOOL *outOutputIsBGRAPixelBufferOpt, NSError **error)
{
    MLModelDescription *desc = m.modelDescription;
    if (desc.inputDescriptionsByName.count < 1 || desc.outputDescriptionsByName.count < 1) {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"Model missing inputs/outputs" }];
        return NO;
    }

    NSString *inKey = desc.inputDescriptionsByName.allKeys.firstObject;
    NSString *outKey = desc.outputDescriptionsByName.allKeys.firstObject;
    MLFeatureDescription *inDesc = desc.inputDescriptionsByName[inKey];

    NSInteger tin = 256;
    NSInteger tinH = 256;
    if (inDesc.type == MLFeatureTypeImage) {
        if (!SakuraMLImageConstraintFixedSize(inDesc.imageConstraint, &tin, &tinH)) {
            if (error)
                *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:3 userInfo:@{ NSLocalizedDescriptionKey: @"Neural input image must have fixed width and height" }];
            return NO;
        }
    } else {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:3 userInfo:@{ NSLocalizedDescriptionKey: @"Neural input must be an image type model" }];
        return NO;
    }

    if (tin <= 0 || tinH <= 0 || tin != tinH) {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:3 userInfo:@{ NSLocalizedDescriptionKey: @"Neural input tile must be square" }];
        return NO;
    }

    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef tile = NULL;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)tin, (size_t)tin, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &tile);
    if (cr != kCVReturnSuccess || !tile) {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:11 userInfo:@{ NSLocalizedDescriptionKey: @"CVPixelBuffer create failed" }];
        return NO;
    }

    NSError *err = nil;
    MLFeatureValue *fv = [MLFeatureValue featureValueWithPixelBuffer:tile];
    MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ inKey: fv } error:&err];
    CFRelease(tile);
    if (!fp) {
        if (error)
            *error = err;
        return NO;
    }

    id<MLFeatureProvider> pred = [m predictionFromFeatures:fp error:&err];
    if (!pred) {
        if (error)
            *error = err;
        return NO;
    }

    MLFeatureValue *ov = [pred featureValueForName:outKey];
    NSInteger tout = 0;
    NSInteger toutH = 0;
    if (ov.type == MLFeatureTypeImage) {
        CVPixelBufferRef pb = ov.imageBufferValue;
        if (pb) {
            tout = (NSInteger)CVPixelBufferGetWidth(pb);
            toutH = (NSInteger)CVPixelBufferGetHeight(pb);
        }
        if (outOutputIsBGRAPixelBufferOpt)
            *outOutputIsBGRAPixelBufferOpt = !!(pb && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA && tout >= 2 && toutH >= 2);
    } else if (ov.type == MLFeatureTypeMultiArray) {
        MLMultiArray *arr = ov.multiArrayValue;
        if (arr.shape.count == 4) {
            tout = arr.shape[3].integerValue;
            toutH = arr.shape[2].integerValue;
        }
        if (outOutputIsBGRAPixelBufferOpt)
            *outOutputIsBGRAPixelBufferOpt = NO;
    }

    if (tout <= 0 || toutH <= 0 || tout != toutH) {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:4 userInfo:@{ NSLocalizedDescriptionKey: @"Could not determine neural output tile size" }];
        return NO;
    }

    *inNameOut = inKey;
    *outNameOut = outKey;
    *tinOut = tin;
    *toutOut = tout;
    return YES;
}

- (BOOL)loadModelIfNeededUnlocked:(NSError **)error
{
    BOOL live = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_live" defaultValue:NO];
    BOOL texArt = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_texture_art" defaultValue:NO];
    if (!live && !texArt)
        return NO;

    NSString *sel = [SakuraBridge getINIString:@"EmuCore/GS" key:@"neural_upscale_model" defaultValue:@"bundle"];

    if (__model && __loadedKey && [__loadedKey isEqualToString:sel])
        return YES;

    __model = nil;
    __loadedKey = nil;
    __inputName = nil;
    __outputName = nil;
    __inW = __inH = __outW = __outH = __scaleNum = __scaleDen = 0;
    __outputIsBGRACVPixelBuffer = NO;

    NSURL *url = [self resolvedModelURL:sel];
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:1 userInfo:@{ NSLocalizedDescriptionKey : @"Neural model file missing" }];
        __loadBlockedSel = [sel copy];
        SakuraLogUnified(@"Neural", @"Warning",
            [NSString stringWithFormat:@"neural_upscale_model '%@': file missing at %@", sel, url.path ?: @"(nil)"]);
        return NO;
    }

    MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
    cfg.computeUnits = MLComputeUnitsAll;

    NSURL *loadURL = url;
    NSString *lext = url.pathExtension.lowercaseString;
    if ([lext isEqualToString:@"mlmodel"] || [lext isEqualToString:@"mlpackage"]) {
        NSError *cerr = nil;
        NSURL *compiled = [MLModel compileModelAtURL:url error:&cerr];
        if (compiled)
            loadURL = compiled;
        else if (cerr)
            SakuraLogUnified(@"Neural", @"Warning",
                [NSString stringWithFormat:@"neural compile failed for '%@': %@", url.lastPathComponent, cerr.localizedDescription]);
    }

    NSError *err = nil;
    MLModel *m = [MLModel modelWithContentsOfURL:loadURL configuration:cfg error:&err];
    if (!m) {
        if (error)
            *error = err;
        __loadBlockedSel = [sel copy];
        SakuraLogUnified(@"Neural", @"Warning",
            [NSString stringWithFormat:@"CoreML could not load '%@': %@", sel, err.localizedDescription ?: @"unknown error"]);
        return NO;
    }

    NSString *inKey = nil;
    NSString *outKey = nil;
    NSInteger tin = 0;
    NSInteger tout = 0;
    BOOL outIsPB = NO;
    if (!SakuraProbeNeuralDims(m, &inKey, &outKey, &tin, &tout, &outIsPB, error)) {
        __loadBlockedSel = [sel copy];
        SakuraLogUnified(@"Neural", @"Warning",
            [NSString stringWithFormat:@"Neural model '%@' failed validation (fixed square image in/out required)", sel]);
        return NO;
    }

    NSInteger g = SakuraIntGCD(tout, tin);

    __scaleNum = tout / g;
    __scaleDen = tin / g;
    __inW = tin;
    __inH = tin;
    __outW = tout;
    __outH = tout;
    __inputName = inKey;
    __outputName = outKey;
    __model = m;
    __loadedKey = sel;
    __loadBlockedSel = nil;
    __outputIsBGRACVPixelBuffer = outIsPB;
    SakuraLogUnified(@"Neural", @"Info",
        [NSString stringWithFormat:@"Loaded neural model '%@' tile %ld→%ld", sel, (long)tin, (long)tout]);
    static std::atomic<int> s_mlCfgLogged{0};
    if (s_mlCfgLogged.fetch_add(1) == 0)
        SakuraLogUnified(@"Neural", @"Info",
            [NSString stringWithFormat:@"CoreML MLModelConfiguration.computeUnits=%ld (device selection is per-model load, not per-prediction)",
                                      (long)cfg.computeUnits]);
    return YES;
}

- (BOOL)loadModelIfNeeded:(NSError **)error
{
    @synchronized (self) {
        return [self loadModelIfNeededUnlocked:error];
    }
}

static BOOL SakuraMakeBGRACVPixelBuffer(NSInteger w, NSInteger h, CVPixelBufferRef *outPB)
{
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, outPB);
    return r == kCVReturnSuccess && *outPB;
}

static void SakuraCopyBGRATileToPixelBuffer(const uint8_t *src, NSInteger srcPadRowBytes, NSInteger srcX, NSInteger srcY, NSInteger tile, CVPixelBufferRef dst)
{
    CVPixelBufferLockBaseAddress(dst, 0);
    uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
    size_t dpr = CVPixelBufferGetBytesPerRow(dst);
    for (NSInteger y = 0; y < tile; y++) {
        const uint8_t *srow = src + (srcY + y) * srcPadRowBytes + srcX * 4;
        uint8_t *drow = db + y * dpr;
        memcpy(drow, srow, (size_t)tile * 4);
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
}

static void SakuraCopyPixelBufferTileToBuffer(CVPixelBufferRef src, uint8_t *dst, NSInteger dstPadRowBytes, NSInteger dstX, NSInteger dstY, NSInteger tw, NSInteger th)
{
    CVPixelBufferLockBaseAddress(src, 0);
    const uint8_t *sb = (const uint8_t *)CVPixelBufferGetBaseAddress(src);
    size_t spr = CVPixelBufferGetBytesPerRow(src);
    for (NSInteger y = 0; y < th; y++) {
        const uint8_t *srow = sb + y * spr;
        uint8_t *drow = dst + (dstY + y) * dstPadRowBytes + dstX * 4;
        memcpy(drow, srow, (size_t)tw * 4);
    }
    CVPixelBufferUnlockBaseAddress(src, 0);
}

static void SakuraMultiArrayCHWFloatToBGRATile(MLMultiArray *arr, uint8_t *dst, NSInteger dstPadRowBytes, NSInteger dstX, NSInteger dstY, NSInteger tw, NSInteger th)
{
    if (arr.shape.count != 4 || arr.dataType != MLMultiArrayDataTypeFloat32)
        return;
    NSInteger n = arr.shape[0].integerValue;
    NSInteger c = arr.shape[1].integerValue;
    NSInteger hh = arr.shape[2].integerValue;
    NSInteger ww = arr.shape[3].integerValue;
    if (n != 1 || c != 3 || hh != th || ww != tw)
        return;
    float *base = (float *)arr.dataPointer;
    for (NSInteger y = 0; y < th; y++) {
        uint8_t *drow = dst + (dstY + y) * dstPadRowBytes + dstX * 4;
        for (NSInteger x = 0; x < tw; x++) {
            size_t idx0 = (size_t)(0 * hh * ww + y * ww + x);
            size_t idx1 = (size_t)(1 * hh * ww + y * ww + x);
            size_t idx2 = (size_t)(2 * hh * ww + y * ww + x);
            float rf = base[idx0];
            float gf = base[idx1];
            float bf = base[idx2];
            int ri = (int)lroundf(SakuraNeuralClampUnitTo255(rf));
            int gi = (int)lroundf(SakuraNeuralClampUnitTo255(gf));
            int bi = (int)lroundf(SakuraNeuralClampUnitTo255(bf));
            drow[x * 4 + 0] = (uint8_t)bi;
            drow[x * 4 + 1] = (uint8_t)gi;
            drow[x * 4 + 2] = (uint8_t)ri;
            drow[x * 4 + 3] = 255;
        }
    }
}

static float SakuraNeuralHann1D(NSInteger j, NSInteger n)
{
    if (n <= 1)
        return 1.f;
    j = MAX(0, MIN(n - 1, j));
    float u = (float)j / (float)(n - 1);
    return 0.5f * (1.f - cosf(2.f * (float)M_PI * u));
}

static void SakuraFillTileStartIndices(NSMutableIndexSet *out, NSUInteger span, NSInteger tin, NSInteger strideLR)
{
    [out removeAllIndexes];
    if (span == 0 || tin <= 0)
        return;
    if (span <= (NSUInteger)tin) {
        [out addIndex:0];
        return;
    }
    for (NSInteger s = 0; s + tin <= (NSInteger)span; s += strideLR)
        [out addIndex:(NSUInteger)s];
    NSInteger last = (NSInteger)span - tin;
    if (last >= 0)
        [out addIndex:(NSUInteger)last];
}

static void SakuraAccumulateMultiArrayOntoWeightedCanvas(
    MLMultiArray *arr, float *acc4, NSInteger outPadW, NSInteger outPadH, NSInteger tout, NSInteger sx, NSInteger sy, NSInteger rl,
    const float *wtX, const float *wtY)
{
    if (arr.shape.count != 4 || arr.dataType != MLMultiArrayDataTypeFloat32)
        return;
    NSInteger n = arr.shape[0].integerValue;
    NSInteger c = arr.shape[1].integerValue;
    NSInteger hh = arr.shape[2].integerValue;
    NSInteger ww = arr.shape[3].integerValue;
    if (n != 1 || c != 3 || hh != tout || ww != tout)
        return;
    float *base = (float *)arr.dataPointer;
    for (NSInteger ly = 0; ly < tout; ly++) {
        for (NSInteger lx = 0; lx < tout; lx++) {
            size_t i0 = (size_t)(0 * hh * ww + ly * ww + lx);
            size_t i1 = (size_t)(1 * hh * ww + ly * ww + lx);
            size_t i2 = (size_t)(2 * hh * ww + ly * ww + lx);

            NSInteger gx = sx * rl + lx;
            NSInteger gy = sy * rl + ly;

            float wTile = wtY[ly] * wtX[lx];
            if (wTile <= 1e-8f)
                continue;

            float rf = base[i0], gf = base[i1], bf = base[i2];
            if (gx < 0 || gy < 0 || gx >= (NSInteger)outPadW || gy >= (NSInteger)outPadH)
                continue;
            NSUInteger gi = (NSUInteger)gx + (NSUInteger)gy * (NSUInteger)outPadW;
            size_t ii = (size_t)gi * 4ull;
            acc4[ii + 0] += rf * wTile;
            acc4[ii + 1] += gf * wTile;
            acc4[ii + 2] += bf * wTile;
            acc4[ii + 3] += wTile;
        }
    }
}

static void SakuraAccumulatePixelBufferOntoWeightedCanvas(CVPixelBufferRef pb, float *acc4, NSInteger outPadW, NSInteger outPadH, NSInteger tout, NSInteger sx, NSInteger sy,
    NSInteger rl, const float *wtX, const float *wtY)
{
    if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA)
        return;
    size_t gw = CVPixelBufferGetWidth(pb);
    size_t gh = CVPixelBufferGetHeight(pb);
    if (gw < (size_t)tout || gh < (size_t)tout)
        return;
    CVPixelBufferLockBaseAddress(pb, 0);
    const uint8_t *sb = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t spr = CVPixelBufferGetBytesPerRow(pb);
    for (NSInteger ly = 0; ly < tout; ly++) {
        const uint8_t *row = sb + ly * spr;
        for (NSInteger lx = 0; lx < tout; lx++) {
            const uint8_t *p = row + lx * 4;

            NSInteger gx = sx * rl + lx;
            NSInteger gy = sy * rl + ly;

            float wTile = wtY[ly] * wtX[lx];
            if (wTile <= 1e-8f)
                continue;

            if (gx < 0 || gy < 0 || gx >= (NSInteger)outPadW || gy >= (NSInteger)outPadH)
                continue;

            float rf = (float)p[2] * (1.f / 255.f);
            float gf = (float)p[1] * (1.f / 255.f);
            float bf = (float)p[0] * (1.f / 255.f);
            NSUInteger gi = (NSUInteger)gx + (NSUInteger)gy * (NSUInteger)outPadW;
            size_t ii = (size_t)gi * 4ull;
            acc4[ii + 0] += rf * wTile;
            acc4[ii + 1] += gf * wTile;
            acc4[ii + 2] += bf * wTile;
            acc4[ii + 3] += wTile;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static NSData *SakuraDownsampleBGRABox(const uint8_t *src, size_t srcRowBytes, NSUInteger sw, NSUInteger sh, NSUInteger dw, NSUInteger dh)
{
    if (!src || sw < 2 || sh < 2 || dw < 2 || dh < 2)
        return nil;
    NSMutableData *md = [NSMutableData dataWithLength:dw * dh * 4];
    if (!md.length)
        return nil;
    uint8_t *dst = (uint8_t *)md.mutableBytes;
    const size_t dstRB = (size_t)dw * 4;

    for (NSUInteger dy = 0; dy < dh; dy++) {
        double y0 = (double)dy * (double)sh / (double)dh;
        double y1 = (double)(dy + 1) * (double)sh / (double)dh;
        NSUInteger iy0 = (NSUInteger)floor(y0);
        NSUInteger iy1 = (NSUInteger)ceil(y1);
        if (iy0 >= sh)
            iy0 = sh - 1;
        if (iy1 > sh)
            iy1 = sh;
        if (iy1 <= iy0)
            iy1 = (iy0 + 1 < sh) ? iy0 + 1 : sh;

        for (NSUInteger dx = 0; dx < dw; dx++) {
            double x0 = (double)dx * (double)sw / (double)dw;
            double x1 = (double)(dx + 1) * (double)sw / (double)dw;
            NSUInteger ix0 = (NSUInteger)floor(x0);
            NSUInteger ix1 = (NSUInteger)ceil(x1);
            if (ix0 >= sw)
                ix0 = sw - 1;
            if (ix1 > sw)
                ix1 = sw;
            if (ix1 <= ix0)
                ix1 = (ix0 + 1 < sw) ? ix0 + 1 : sw;

            unsigned acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;
            NSUInteger count = 0;
            for (NSUInteger yy = iy0; yy < iy1; yy++) {
                const uint8_t *row = src + yy * srcRowBytes;
                for (NSUInteger xx = ix0; xx < ix1; xx++) {
                    const uint8_t *p = row + xx * 4;
                    acc0 += p[0];
                    acc1 += p[1];
                    acc2 += p[2];
                    acc3 += p[3];
                    count++;
                }
            }
            if (count == 0)
                count = 1;
            uint8_t *outp = dst + dy * dstRB + dx * 4;
            outp[0] = (uint8_t)(acc0 / count);
            outp[1] = (uint8_t)(acc1 / count);
            outp[2] = (uint8_t)(acc2 / count);
            outp[3] = (uint8_t)(acc3 / count);
        }
    }
    return md;
}

- (NSData *)sakuraNeuralUpscaleInferFromBGRABase:(const uint8_t *)inferBase
                                        rowBytes:(size_t)inferRow
                                             workW:(NSUInteger)workW
                                             workH:(NSUInteger)workH
                                             snapNum:(NSUInteger)snapNum
                                             snapDen:(NSUInteger)snapDen
                                                   tin:(NSInteger)tin tout:(NSInteger)tout
                                                   runModel:(MLModel *)runModel runIn:(NSString *)runIn runOut:(NSString *)runOut
                                    compositeDevice:(nullable id<MTLDevice>)compositeDev
                                             texCache:(nullable CVMetalTextureCacheRef)texCache
                                           predOptions:(nullable MLPredictionOptions *)predOpts
                                                  error:(NSError **)error
                                       usedScaleNumOut:(NSUInteger *)snumOpt
                                       usedScaleDenOut:(NSUInteger *)sdenOpt
                                    usedOutputWidthOut:(NSUInteger *)oWOpt
                                   usedOutputHeightOut:(NSUInteger *)oHOpt
                                                outTex:(id<MTLTexture> __autoreleasing _Nullable *__nullable)outTexOpt
{
    (void)predOpts;
    if (!inferBase || inferRow < (size_t)workW * 4u || workW < 2 || workH < 2)
        return nil;
    if (!runModel || !runIn.length || !runOut.length)
        return nil;
    if (snapDen < 1)
        snapDen = 1;
    if (tin <= 0 || tout <= 0 || (tout % tin) != 0) {
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:10 userInfo:@{ NSLocalizedDescriptionKey: @"Neural model tile scale mismatch" }];
        return nil;
    }
    const NSInteger rl = tout / tin;

    const NSUInteger padW = ((workW + (NSUInteger)tin - 1) / (NSUInteger)tin) * (NSUInteger)tin;
    const NSUInteger padH = ((workH + (NSUInteger)tin - 1) / (NSUInteger)tin) * (NSUInteger)tin;

    const size_t padRowBytes = (size_t)padW * 4;
    size_t padBufLen = 0;
    size_t outRowBytes = 0;
    size_t outBufLen = 0;
    const NSUInteger outPadW = padW * snapNum / snapDen;
    const NSUInteger outPadH = padH * snapNum / snapDen;
    if (__builtin_mul_overflow(padRowBytes, padH, &padBufLen) || __builtin_mul_overflow((size_t)outPadW, 4, &outRowBytes)
        || __builtin_mul_overflow(outRowBytes, outPadH, &outBufLen))
        return nil;

    NSMutableData *padBuf = [NSMutableData dataWithLength:padBufLen];
    NSMutableData *outBuf = [NSMutableData dataWithLength:outBufLen];
    if (!padBuf.length || !outBuf.length)
        return nil;
    uint8_t *pd = (uint8_t *)padBuf.mutableBytes;
    uint8_t *od = (uint8_t *)outBuf.mutableBytes;

    const size_t srcRow = inferRow;
    for (NSUInteger y = 0; y < padH; y++) {
        NSUInteger syIdx = std::min(y, workH - 1);
        uint8_t *drow = pd + y * padRowBytes;
        const uint8_t *srow = inferBase + syIdx * srcRow;
        for (NSUInteger x = 0; x < padW; x++) {
            NSUInteger sxIdx = std::min(x, workW - 1);
            memcpy(drow + x * 4, srow + sxIdx * 4, 4);
        }
    }

    const NSUInteger outW = (NSUInteger)((double)workW * (double)snapNum / (double)snapDen + 0.5);
    const NSUInteger outH = (NSUInteger)((double)workH * (double)snapNum / (double)snapDen + 0.5);
    if (outW < 2 || outH < 2 || outW > outPadW || outH > outPadH)
        return nil;

    BOOL wantGpu = !!(outTexOpt && compositeDev != nil && texCache != NULL);
    if (wantGpu) {
        @synchronized (self) {
            wantGpu = __outputIsBGRACVPixelBuffer;
            if (wantGpu)
                [self sakuraEnsureNeuralCompositePipelinesLockedForDevice:compositeDev];
            wantGpu = wantGpu && __neuralClearPso != nil && __neuralAccumPso != nil && __neuralFinalPso != nil && __neuralMetalQueue != nil;
        }
    }

    typedef struct __attribute__((packed)) {
        uint32_t gx0;
        uint32_t gy0;
        uint32_t toutU;
        uint32_t tinU;
        uint32_t rlU;
        uint32_t opw;
        uint32_t oph;
        uint32_t useFlatWeights;
    } SkAccumUb;
    typedef struct __attribute__((packed)) {
        uint32_t outWU;
        uint32_t outHU;
        uint32_t outPadWU;
        uint32_t outPadHU;
        uint32_t padInWU;
        uint32_t padInHU;
        uint32_t rlU;
        uint32_t _pad;
    } SkFinUb;

    id<MTLComputeCommandEncoder> gpuCe = nil;
    NSMutableArray *cvtStack = wantGpu ? [NSMutableArray array] : nil;
    id<MTLCommandBuffer> gpuCb = nil;
    __strong id<MTLTexture> gAcc = nil;
    __strong id<MTLTexture> gPad = nil;
    __strong id<MTLTexture> gTile = nil;
    __strong id<MTLTexture> gOut = nil;

    if (wantGpu) {
        MTLTextureDescriptor *tAcc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:outPadW height:outPadH mipmapped:NO];
        tAcc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        tAcc.storageMode = MTLStorageModeShared;
        MTLTextureDescriptor *tPd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:padW height:padH mipmapped:NO];
        tPd.usage = MTLTextureUsageShaderRead;
        tPd.storageMode = MTLStorageModeShared;
        MTLTextureDescriptor *tTl =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)tout height:(NSUInteger)tout mipmapped:NO];
        tTl.usage = MTLTextureUsageShaderRead;
        tTl.storageMode = MTLStorageModeShared;
        MTLTextureDescriptor *tOu = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:outW height:outH mipmapped:NO];
        tOu.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        tOu.storageMode = MTLStorageModeShared;
        gAcc = [compositeDev newTextureWithDescriptor:tAcc];
        gPad = [compositeDev newTextureWithDescriptor:tPd];
        gTile = [compositeDev newTextureWithDescriptor:tTl];
        gOut = [compositeDev newTextureWithDescriptor:tOu];
        gpuCb = [__neuralMetalQueue commandBuffer];
        if (!gAcc || !gPad || !gTile || !gOut || !gpuCb) {
            wantGpu = NO;
            gAcc = gPad = gTile = gOut = nil;
            gpuCe = nil;
            gpuCb = nil;
            cvtStack = nil;
        } else {
            gpuCe = [gpuCb computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
            if (!gpuCe) {
                wantGpu = NO;
                gAcc = gPad = gTile = gOut = nil;
                gpuCb = nil;
            } else {
                [gpuCe setLabel:@"neural.gpu"];
                [gpuCe setComputePipelineState:__neuralClearPso];
                [gpuCe setTexture:gAcc atIndex:0];
                SakuraMetalDispatchCompute2D(gpuCe, outPadW, outPadH);
                [gPad replaceRegion:MTLRegionMake2D(0, 0, padW, padH) mipmapLevel:0 withBytes:pd bytesPerRow:(NSUInteger)padRowBytes];
            }
        }
    }

    float *acc = nullptr;
    if (!wantGpu) {
        acc = (float *)calloc((size_t)outPadW * (size_t)outPadH * 4ull, sizeof(float));
        if (!acc)
            return nil;
    }

    size_t twoTout = 0;
    size_t lutN = 0;
    if (__builtin_mul_overflow((size_t)tout, 2ull, &twoTout) || __builtin_add_overflow((size_t)tin, twoTout, &lutN)) {
        if (acc)
            free(acc);
        return nil;
    }

    CVPixelBufferRef inPB = NULL;
    float *weightLuts = (float *)malloc(lutN * sizeof(float));
    if (!weightLuts) {
        if (acc)
            free(acc);
        return nil;
    }
    float *lutHann = weightLuts;
    float *wtX = weightLuts + tin;
    float *wtY = weightLuts + tin + tout;
    for (NSInteger hi = 0; hi < tin; hi++)
        lutHann[hi] = SakuraNeuralHann1D(hi, tin);

    if (!SakuraMakeBGRACVPixelBuffer(tin, tin, &inPB)) {
        free(weightLuts);
        if (acc)
            free(acc);
        if (error)
            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:11 userInfo:@{ NSLocalizedDescriptionKey: @"CVPixelBuffer create failed" }];
        return nil;
    }

    NSString *const outKey = runOut;

    BOOL neuralGpuDone = NO;

    @try {
        NSMutableIndexSet *xStarts = [NSMutableIndexSet indexSet];
        NSMutableIndexSet *yStarts = [NSMutableIndexSet indexSet];
        NSInteger strideLR = MAX(1, tin - MAX(8, tin / 4));

        auto countXY = ^NSUInteger(NSInteger stride) {
            NSMutableIndexSet *xs = [NSMutableIndexSet indexSet];
            NSMutableIndexSet *ys = [NSMutableIndexSet indexSet];
            SakuraFillTileStartIndices(xs, padW, tin, stride);
            SakuraFillTileStartIndices(ys, padH, tin, stride);
            return xs.count * ys.count;
        };

        while (strideLR > 0) {
            NSUInteger nPlan = countXY(strideLR);
            if (nPlan <= (NSUInteger)kMaxTiles)
                break;
            NSInteger nextStride = strideLR + MAX(1, tin / 8);
            if (nextStride >= tin) {
                strideLR = tin;
                break;
            }
            strideLR = MIN(tin, nextStride);
        }

        SakuraFillTileStartIndices(xStarts, padW, tin, strideLR);
        SakuraFillTileStartIndices(yStarts, padH, tin, strideLR);

        // hann tapers to 0 at tile borders — that produces zero-weight seams when there is no overlap.
        // use flat weights when stride >= tin so accum coverage is uniform across the canvas.
        const BOOL hasOverlap = strideLR < tin;
        if (hasOverlap) {
            for (NSInteger lx = 0; lx < tout; lx++)
                wtX[lx] = lutHann[lx / rl];
            for (NSInteger ly = 0; ly < tout; ly++)
                wtY[ly] = lutHann[ly / rl];
        } else {
            for (NSInteger lx = 0; lx < tout; lx++)
                wtX[lx] = 1.f;
            for (NSInteger ly = 0; ly < tout; ly++)
                wtY[ly] = 1.f;
        }

        if (xStarts.count * yStarts.count > (NSUInteger)kMaxTiles) {
            if (error)
                *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:10 userInfo:@{ NSLocalizedDescriptionKey: @"Frame too large for neural tiles" }];
            return nil;
        }

        MLModel *tileModel = runModel;
        NSString *const inKey = runIn;

        Class batchCls = NSClassFromString(@"MLArrayBatchProvider");
        const BOOL respondsBatch = !!(batchCls && [tileModel respondsToSelector:@selector(predictionsFromBatch:error:)]);
        NSMutableArray<id<MLFeatureProvider>> *bat = nil;
        NSMutableArray<NSNumber *> *bTX = nil;
        NSMutableArray<NSNumber *> *bTY = nil;
        if (respondsBatch && batchCls != nil) {
            bat = [NSMutableArray array];
            bTX = [NSMutableArray array];
            bTY = [NSMutableArray array];
        }

        void (^accumOneOv)(NSUInteger, NSUInteger, MLFeatureValue *) =
            ^(NSUInteger tx0x, NSUInteger ty0x, MLFeatureValue *ov) {
                BOOL didGpu = NO;
                if (wantGpu && gpuCe && ov.type == MLFeatureTypeImage && gTile && gAcc != nil && texCache) {
                    CVPixelBufferRef ob = ov.imageBufferValue;
                    if (ob && CVPixelBufferGetPixelFormatType(ob) == kCVPixelFormatType_32BGRA
                        && CVPixelBufferGetWidth(ob) >= (size_t)tout && CVPixelBufferGetHeight(ob) >= (size_t)tout) {
                        CVMetalTextureRef cvt = NULL;
                        CVReturn cr = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, ob, NULL,
                            MTLPixelFormatBGRA8Unorm, (size_t)tout, (size_t)tout, 0, &cvt);
                        if (cr == kCVReturnSuccess && cvt != NULL) {
                            id<MTLTexture> tiled = CVMetalTextureGetTexture(cvt);
                            if (tiled) {
                                NSInteger gxi = (NSInteger)tx0x * rl;
                                NSInteger gyi = (NSInteger)ty0x * rl;
                                if (gxi < 0)
                                    gxi = 0;
                                if (gyi < 0)
                                    gyi = 0;
                                SkAccumUb u{};
                                u.gx0 = (uint32_t)gxi;
                                u.gy0 = (uint32_t)gyi;
                                u.toutU = (uint32_t)tout;
                                u.tinU = (uint32_t)tin;
                                u.rlU = (uint32_t)rl;
                                u.opw = (uint32_t)outPadW;
                                u.oph = (uint32_t)outPadH;
                                u.useFlatWeights = hasOverlap ? 0u : 1u;

                                [gpuCe setComputePipelineState:__neuralAccumPso];
                                [gpuCe setTexture:tiled atIndex:0];
                                [gpuCe setTexture:gAcc atIndex:1];
                                [gpuCe setBytes:&u length:sizeof(u) atIndex:0];
                                SakuraMetalDispatchCompute2D(gpuCe, (NSUInteger)tout, (NSUInteger)tout);
                                [cvtStack addObject:[NSValue valueWithPointer:(void *)cvt]];
                                didGpu = YES;
                            } else
                                CFRelease(cvt);
                        }
                    }
                }
                if (didGpu)
                    return;
                if (!acc)
                    return;
                if (ov.type == MLFeatureTypeImage) {
                    CVPixelBufferRef pb = ov.imageBufferValue;
                    if (pb && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
                        && CVPixelBufferGetWidth(pb) >= (size_t)tout && CVPixelBufferGetHeight(pb) >= (size_t)tout)
                        SakuraAccumulatePixelBufferOntoWeightedCanvas(pb, acc, outPadW, outPadH, tout, (NSInteger)tx0x,
                            (NSInteger)ty0x, rl, wtX, wtY);
                } else if (ov.type == MLFeatureTypeMultiArray)
                    SakuraAccumulateMultiArrayOntoWeightedCanvas(
                        ov.multiArrayValue, acc, outPadW, outPadH, tout, (NSInteger)tx0x, (NSInteger)ty0x, rl, wtX, wtY);
            };

        void (^consumePredProv)(NSUInteger, NSUInteger, id<MLFeatureProvider>) =
            ^(NSUInteger tx0x, NSUInteger ty0x, id<MLFeatureProvider> pf) {
                if (!pf)
                    return;
                MLFeatureValue *ov = [pf featureValueForName:outKey];
                if (!ov)
                    return;
                accumOneOv(tx0x, ty0x, ov);
            };

        void (^flushBat)(BOOL) = ^(BOOL force __unused) {
            if (!bat.count)
                return;
            if (batchCls && bat.count >= 2) {
                id bp = [(MLArrayBatchProvider *)[batchCls alloc] initWithFeatureProviderArray:bat];
                if (bp) {
                    NSError *__autoreleasing be2 = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
                    id batchPred =
                        [(MLModel *)tileModel predictionsFromBatch:(id<MLBatchProvider>)bp error:&be2];
#pragma clang diagnostic pop
                    NSArray *outs = nil;
                    if ([batchPred isKindOfClass:[NSArray class]])
                        outs = (NSArray *)batchPred;
                    else if ([batchPred respondsToSelector:@selector(array)])
                        outs = [(MLArrayBatchProvider *)batchPred array];
                    if (!be2 && outs.count == bat.count) {
                        for (NSUInteger ii = 0; ii < outs.count; ii++)
                            consumePredProv([bTX[ii] unsignedIntegerValue], [bTY[ii] unsignedIntegerValue],
                                (id<MLFeatureProvider>)outs[ii]);
                        [bat removeAllObjects];
                        [bTX removeAllObjects];
                        [bTY removeAllObjects];
                        return;
                    }
                }
            }
            for (NSUInteger ii = 0; ii < bat.count; ii++) {
                NSError *__autoreleasing se = nil;
                id lone = [(MLModel *)tileModel predictionFromFeatures:bat[ii] error:&se];
                if (lone)
                    consumePredProv([bTX[ii] unsignedIntegerValue], [bTY[ii] unsignedIntegerValue], lone);
            }
            [bat removeAllObjects];
            [bTX removeAllObjects];
            [bTY removeAllObjects];
        };

        NSMutableArray<id<MLFeatureProvider>> *__strong batchLocal = bat;
        void (^enqueueFP)(NSUInteger, NSUInteger, MLDictionaryFeatureProvider *) = ^(
            NSUInteger rtx, NSUInteger rty, MLDictionaryFeatureProvider *fpx) {
            if (!batchLocal) {
                NSError *__autoreleasing se = nil;
                id lone = [(MLModel *)tileModel predictionFromFeatures:fpx error:&se];
                if (lone)
                    consumePredProv(rtx, rty, lone);
                return;
            }
            [batchLocal addObject:fpx];
            [bTX addObject:@(rtx)];
            [bTY addObject:@(rty)];
            if (batchLocal.count >= kNeuralBatchFlush)
                flushBat(NO);
        };

        const BOOL batching = (batchLocal != nil);
        [yStarts enumerateIndexesUsingBlock:^(NSUInteger ty0, BOOL *stopY __unused) {
            [xStarts enumerateIndexesUsingBlock:^(NSUInteger tx0, BOOL *stopX __unused) {
                // when batching, MLFeatureValue retains the pixel buffer without copying — so reusing inPB
                // would make every batch entry see only the last tile's pixels. allocate fresh per tile here.
                CVPixelBufferRef tilePB = NULL;
                if (batching) {
                    tilePB = [self sakuraBorrowBatchedTilePixelBufferForTin:tin];
                    if (!tilePB && (!SakuraMakeBGRACVPixelBuffer(tin, tin, &tilePB) || !tilePB))
                        return;
                    SakuraCopyBGRATileToPixelBuffer(pd, (NSInteger)padRowBytes, (NSInteger)tx0, (NSInteger)ty0, tin, tilePB);
                } else {
                    SakuraCopyBGRATileToPixelBuffer(pd, (NSInteger)padRowBytes, (NSInteger)tx0, (NSInteger)ty0, tin, inPB);
                    tilePB = inPB;
                }

                NSError *__autoreleasing fe = nil;
                NSMutableDictionary *feDic = [NSMutableDictionary dictionary];
                feDic[inKey] = [MLFeatureValue featureValueWithPixelBuffer:tilePB];
                MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:feDic error:&fe];
                if (batching && tilePB)
                    CFRelease(tilePB);
                if (!fp)
                    return;
                enqueueFP(tx0, ty0, fp);
            }];
        }];
        flushBat(YES);

        if (wantGpu && gpuCe && gpuCb && gAcc && gPad && gOut != nil) {
            SkFinUb fu{};
            fu.outWU = (uint32_t)outW;
            fu.outHU = (uint32_t)outH;
            fu.outPadWU = (uint32_t)outPadW;
            fu.outPadHU = (uint32_t)outPadH;
            fu.padInWU = (uint32_t)padW;
            fu.padInHU = (uint32_t)padH;
            fu.rlU = (uint32_t)rl;

            [gpuCe setComputePipelineState:__neuralFinalPso];
            [gpuCe setTexture:gAcc atIndex:0];
            [gpuCe setTexture:gPad atIndex:1];
            [gpuCe setTexture:gOut atIndex:2];
            [gpuCe setBytes:&fu length:sizeof(fu) atIndex:0];
            SakuraMetalDispatchCompute2D(gpuCe, outW, outH);
            [gpuCe endEncoding];
            gpuCe = nil;
            [gpuCb commit];
            [gpuCb waitUntilCompleted];
            gpuCb = nil;

            for (NSValue *v in cvtStack) {
                CVMetalTextureRef rr = reinterpret_cast<CVMetalTextureRef>(v.pointerValue);
                if (rr)
                    CFRelease(rr);
            }
            [cvtStack removeAllObjects];

            if (outTexOpt)
                *outTexOpt = gOut;

            neuralGpuDone = YES;
        }

        if (!neuralGpuDone) {

        for (NSUInteger gy = 0; gy < outPadH; gy++) {
            uint8_t *drow = od + gy * outRowBytes;
            for (NSUInteger gx = 0; gx < outPadW; gx++) {
                size_t ii = ((size_t)gy * (size_t)outPadW + gx) * 4ull;
                float wsum = acc[ii + 3];
                if (wsum > 1e-5f) {
                    int ri = (int)lroundf(SakuraNeuralClampUnitTo255(acc[ii + 0] / wsum));
                    int gi = (int)lroundf(SakuraNeuralClampUnitTo255(acc[ii + 1] / wsum));
                    int bi = (int)lroundf(SakuraNeuralClampUnitTo255(acc[ii + 2] / wsum));
                    drow[gx * 4 + 0] = (uint8_t)bi;
                    drow[gx * 4 + 1] = (uint8_t)gi;
                    drow[gx * 4 + 2] = (uint8_t)ri;
                    drow[gx * 4 + 3] = 255;
                } else {
                    NSUInteger lrx = gx / (NSUInteger)rl;
                    NSUInteger lry = gy / (NSUInteger)rl;
                    if (lrx >= padW)
                        lrx = padW - 1;
                    if (lry >= padH)
                        lry = padH - 1;
                    memcpy(drow + gx * 4, pd + lry * padRowBytes + lrx * 4, 4);
                }
            }
        }

        }

    } @finally {
        free(weightLuts);
        weightLuts = NULL;
        if (acc)
            free(acc);
        acc = nullptr;
        if (inPB) {
            CFRelease(inPB);
            inPB = NULL;
        }
        for (NSValue *v in cvtStack) {
            CVMetalTextureRef rr = reinterpret_cast<CVMetalTextureRef>(v.pointerValue);
            if (rr)
                CFRelease(rr);
        }
    }

    if (neuralGpuDone) {
        if (snumOpt)
            *snumOpt = snapNum;
        if (sdenOpt)
            *sdenOpt = snapDen;
        if (oWOpt)
            *oWOpt = outW;
        if (oHOpt)
            *oHOpt = outH;
        return [NSData data];
    }

    const size_t trimRow = (size_t)outW * 4;
    size_t trimLen = 0;
    if (__builtin_mul_overflow(trimRow, outH, &trimLen))
        return nil;
    NSMutableData *trim = [NSMutableData dataWithLength:trimLen];
    if (!trim.length)
        return nil;
    uint8_t *td = (uint8_t *)trim.mutableBytes;
    for (NSUInteger y = 0; y < outH; y++)
        memcpy(td + y * trimRow, od + y * outRowBytes, trimRow);

    if (snumOpt)
        *snumOpt = snapNum;
    if (sdenOpt)
        *sdenOpt = snapDen;
    if (oWOpt)
        *oWOpt = outW;
    if (oHOpt)
        *oHOpt = outH;

    NSData *__autoreleasing resultTrim = trim;
    return resultTrim.length ? resultTrim : nil;
}

- (NSData *)upscaleBGRAData:(NSData *)pixels
                     width:(NSUInteger)w
                    height:(NSUInteger)h
              usedScaleNum:(NSUInteger *)scaleNumOut
              usedScaleDen:(NSUInteger *)scaleDenOut
           usedOutputWidth:(NSUInteger *)outWOpt
          usedOutputHeight:(NSUInteger *)outHOpt
           compositeDevice:(nullable id<MTLDevice>)compositeDev
                  texCache:(nullable CVMetalTextureCacheRef)texCache
                    outTex:(out id<MTLTexture> _Nullable __autoreleasing *_Nullable)outTexPtr
                     error:(NSError **)error
{
    NSData *workPixels = pixels;
    NSUInteger workW = w;
    NSUInteger workH = h;
    NSInteger tin = 0;
    NSInteger tout = 0;
    NSUInteger snapNum = 1;
    NSUInteger snapDen = 1;
    MLModel *__strong runModel = nil;
    NSString *__strong runIn = nil;
    NSString *__strong runOut = nil;

    @synchronized (self) {
        if (!pixels.length || w < 2 || h < 2)
            return nil;
        NSError *le = nil;
        if (![self loadModelIfNeededUnlocked:&le]) {
            if (error)
                *error = le;
            return nil;
        }

        workW = w;
        workH = h;
        workPixels = pixels;

        const BOOL liveUpscale = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_live" defaultValue:NO];
        if (liveUpscale) {
            const double ratio = (double)__scaleNum / (double)__scaleDen;
            auto fitsProjDims = ^BOOL(NSUInteger ww, NSUInteger hh) {
                if (ww < 2 || hh < 2)
                    return NO;
                NSUInteger pjW = (NSUInteger)((double)ww * ratio + 0.5);
                NSUInteger pjH = (NSUInteger)((double)hh * ratio + 0.5);
                if (pjW > kNeuralLiveMaxSide || pjH > kNeuralLiveMaxSide)
                    return NO;
                return (double)pjW * (double)pjH <= (double)kNeuralLiveMaxPixels;
            };

            if (!fitsProjDims(workW, workH)) {
                double lo = 0.02, hi = 1.0;
                for (int iter = 0; iter < 28; iter++) {
                    double mid = (lo + hi) * 0.5;
                    NSUInteger ww = MAX((NSUInteger)2, (NSUInteger)floor((double)w * mid));
                    NSUInteger hh = MAX((NSUInteger)2, (NSUInteger)floor((double)h * mid));
                    if (fitsProjDims(ww, hh))
                        lo = mid;
                    else
                        hi = mid;
                }
                workW = MAX((NSUInteger)2, (NSUInteger)floor((double)w * lo));
                workH = MAX((NSUInteger)2, (NSUInteger)floor((double)h * lo));
                while (!fitsProjDims(workW, workH)) {
                    if (workW >= workH && workW > 2)
                        workW--;
                    else if (workH > 2)
                        workH--;
                    else {
                        if (error)
                            *error = [NSError errorWithDomain:@"SakuraNeuralUpscale" code:12 userInfo:@{ NSLocalizedDescriptionKey: @"Output exceeds live neural cap" }];
                        return nil;
                    }
                }
                if (workW != w || workH != h) {
                    NSData *ds = SakuraDownsampleBGRABox((const uint8_t *)pixels.bytes, (size_t)w * 4, w, h, workW, workH);
                    if (!ds.length)
                        return nil;
                    workPixels = ds;
                    static std::atomic<int> s_budgetLog{0};
                    if (s_budgetLog.fetch_add(1) < 4)
                        SakuraLogUnified(@"Neural", @"Info",
                            [NSString stringWithFormat:@"live neural input downsample %lux%lu→%lux%lu (SR output budget)", (unsigned long)w, (unsigned long)h, (unsigned long)workW,
                                                       (unsigned long)workH]);
                }
            }
        }

        tin = __inW;
        tout = __outW;
        snapNum = (NSUInteger)__scaleNum;
        snapDen = (NSUInteger)__scaleDen;
        runModel = __model;
        runIn = [__inputName copy];
        runOut = [__outputName copy];
    }

    if (snapDen < 1)
        snapDen = 1;

    if (!runModel || runIn.length == 0 || runOut.length == 0)
        return nil;

    const size_t rowB = (size_t)workW * 4u;
    size_t need = 0;
    if (__builtin_mul_overflow(rowB, workH, &need) || workPixels.length < need)
        return nil;

    return [self sakuraNeuralUpscaleInferFromBGRABase:(const uint8_t *)workPixels.bytes
                                             rowBytes:rowB
                                                workW:workW
                                                workH:workH
                                              snapNum:snapNum
                                              snapDen:snapDen
                                                   tin:tin
                                                  tout:tout
                                             runModel:runModel
                                                runIn:runIn
                                               runOut:runOut
                                     compositeDevice:compositeDev
                                             texCache:texCache
                                           predOptions:nil
                                                 error:error
                                     usedScaleNumOut:scaleNumOut
                                     usedScaleDenOut:scaleDenOut
                                  usedOutputWidthOut:outWOpt
                                 usedOutputHeightOut:outHOpt
                                             outTex:outTexPtr];
}

- (NSData *)copyTextureBGRA:(id<MTLTexture>)tex device:(id<MTLDevice>)device queue:(id<MTLCommandQueue>)queue
{
    if (!tex || !device || !queue)
        return nil;
    NSUInteger w = tex.width;
    NSUInteger h = tex.height;
    if (w < 2 || h < 2)
        return nil;
    size_t bytesPerRow = w * 4;
    size_t len = bytesPerRow * h;
    id<MTLBuffer> buf = [device newBufferWithLength:len options:MTLResourceStorageModeShared];
    if (!buf)
        return nil;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!cb)
        return nil;
    id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
    if (!enc)
        return nil;
    [enc copyFromTexture:tex
             sourceSlice:0
             sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf
     destinationOffset:0
destinationBytesPerRow:bytesPerRow
destinationBytesPerImage:len];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return [NSData dataWithBytes:buf.contents length:len];
}

- (id<MTLTexture>)textureFromBGRA:(NSData *)data width:(NSUInteger)w height:(NSUInteger)h device:(id<MTLDevice>)device
{
    if (!data.length || !device || w < 2 || h < 2)
        return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:w
                                                                                   height:h
                                                                                mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [device newTextureWithDescriptor:td];
    if (!t)
        return nil;
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data.bytes bytesPerRow:w * 4];
    return t;
}

- (id<MTLTexture>)upscaleBGRATextureIfEnabled:(id<MTLTexture>)src
                                 prebuiltBGRA:(NSData *)prebuiltBGRA
                   volatilePackedBGRABase:(const void *)volatilePackedBGRABase
                 volatilePackedBGRALength:(NSUInteger)volatilePackedBGRALength
                                       device:(id<MTLDevice>)device
                                        queue:(id<MTLCommandQueue>)queue
                                coreBaseWidth:(NSUInteger)coreBaseWidth
                               coreBaseHeight:(NSUInteger)coreBaseHeight
{
    if (![SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_live" defaultValue:NO])
        return src;
    if (!src || !device || !queue)
        return src;

    NSString *sel = [SakuraBridge getINIString:@"EmuCore/GS" key:@"neural_upscale_model" defaultValue:@"bundle"];
    @synchronized (self) {
        if (sel.length && __loadBlockedSel.length && [__loadBlockedSel isEqualToString:sel])
            return src;
        if (__prewarmRequested)
            __prewarmRequested = NO;
    }

    [self beginNeuralLiveSession:device];

    NSError *le = nil;
    if (![self loadModelIfNeeded:&le]) {
        [self warmUpAsync];
        return src;
    }

    (void)coreBaseWidth;
    (void)coreBaseHeight;
    const NSUInteger surfW = src.width;
    const NSUInteger surfH = src.height;
    const size_t expectBytes = (size_t)surfW * (size_t)surfH * 4u;
    NSData *preSnap = nil;
    if (prebuiltBGRA.length == expectBytes)
        preSnap = prebuiltBGRA;

    id<MTLTexture> cachedTex = nil;
    @synchronized (self) {
        if (__neuralLatestTex && __neuralLatestSurfW == surfW && __neuralLatestSurfH == surfH && (id)__neuralLatestDev == (id)device
            && __neuralLatestModelKey.length && sel.length && [__neuralLatestModelKey isEqualToString:sel])
            cachedTex = __neuralLatestTex;
    }

    int flightExpected = 0;
    if (__neuralInferFlight.compare_exchange_strong(flightExpected, 1, std::memory_order_acq_rel)) {
        NSData *ownedCpuBGRA = nil;
        if (volatilePackedBGRABase && volatilePackedBGRALength == (NSUInteger)expectBytes) {
            NSMutableData *m = [NSMutableData dataWithLength:(NSUInteger)expectBytes];
            memcpy(m.mutableBytes, volatilePackedBGRABase, (NSUInteger)expectBytes);
            ownedCpuBGRA = m;
        }
        NSData *preCapture = ownedCpuBGRA ? ownedCpuBGRA : preSnap;
        id<MTLTexture> srcCapture = src;
        id<MTLDevice> devCapture = device;
        id<MTLCommandQueue> qCapture = queue;
        NSString *jobSel = [sel copy];
        const NSUInteger sw = surfW;
        const NSUInteger sh = surfH;
        const size_t expectCapture = expectBytes;
        const uint64_t jobGen = __neuralLiveGeneration.load(std::memory_order_acquire);
        dispatch_async(__neuralInferQueue, ^{
            SakuraNeuralUpscale *me = [SakuraNeuralUpscale shared];
            @try {
                [me beginNeuralLiveSession:devCapture];
                NSData *bgra = preCapture;
                if (!bgra.length || bgra.length != expectCapture)
                    bgra = [me copyTextureBGRA:srcCapture device:devCapture queue:qCapture];
                if (!bgra.length)
                    return;

                CVMetalTextureCacheRef cacheRet = NULL;
                @synchronized (me) {
                    [me sakuraEnsureMetalTexCacheLockedForDevice:devCapture];
                    if (me->__metalTexCache)
                        cacheRet = (CVMetalTextureCacheRef)CFRetain(me->__metalTexCache);
                }

                NSUInteger scaleDen = 0;
                NSUInteger ow = 0;
                NSUInteger oh = 0;
                id<MTLTexture> gpuTex = nil;
                NSError *inferErr = nil;
                NSData *cpuOut = [me upscaleBGRAData:bgra
                                                width:sw
                                               height:sh
                                         usedScaleNum:nil
                                         usedScaleDen:&scaleDen
                                      usedOutputWidth:&ow
                                     usedOutputHeight:&oh
                                      compositeDevice:devCapture
                                             texCache:cacheRet
                                               outTex:&gpuTex
                                                error:&inferErr];
                if (cacheRet)
                    CFRelease(cacheRet);

                id<MTLTexture> out = gpuTex;
                if (!out && cpuOut.length && scaleDen > 0 && ow >= 2 && oh >= 2)
                    out = [me textureFromBGRA:cpuOut width:ow height:oh device:devCapture];

                @synchronized (me) {
                    if (jobGen != me->__neuralLiveGeneration.load(std::memory_order_acquire))
                        return;
                    if (!me->__model)
                        return;
                    NSString *nowSel = [SakuraBridge getINIString:@"EmuCore/GS" key:@"neural_upscale_model" defaultValue:@"bundle"];
                    if (!jobSel.length || !nowSel.length || ![jobSel isEqualToString:nowSel] || !out)
                        return;
                    id<MTLTexture> oldTex = me->__neuralLatestTex;
                    me->__neuralLatestTex = out;
                    me->__neuralLatestSurfW = sw;
                    me->__neuralLatestSurfH = sh;
                    me->__neuralLatestDev = devCapture;
                    me->__neuralLatestModelKey = jobSel;
                    me->__neuralCommitCount.fetch_add(1, std::memory_order_relaxed);
                    (void)oldTex;
                }
            } @finally {
                me->__neuralInferFlight.store(0, std::memory_order_release);
            }
        });
    }

    if (cachedTex)
        return cachedTex;
    return src;
}

- (id<MTLTexture>)upscaleBGRATextureIfEnabled:(id<MTLTexture>)src
                                       device:(id<MTLDevice>)device
                                        queue:(id<MTLCommandQueue>)queue
                                coreBaseWidth:(NSUInteger)coreBaseWidth
                               coreBaseHeight:(NSUInteger)coreBaseHeight
{
    return [self upscaleBGRATextureIfEnabled:src
                                prebuiltBGRA:nil
                  volatilePackedBGRABase:NULL
                volatilePackedBGRALength:0
                                      device:device
                                       queue:queue
                               coreBaseWidth:coreBaseWidth
                              coreBaseHeight:coreBaseHeight];
}

- (UIImage *)upscaleUIImageForTextureArtIfEnabled:(UIImage *)image
{
    if (![SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_texture_art" defaultValue:NO])
        return image;
    if (!image)
        return nil;
    if (!image.CGImage)
        return image;
    CGSize sz = image.size;
    NSInteger iw = (NSInteger)lround(sz.width * image.scale);
    NSInteger ih = (NSInteger)lround(sz.height * image.scale);
    if (iw < 2 || ih < 2)
        return image;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)(iw * ih * 4)];
    CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, (size_t)iw, (size_t)ih, 8, (size_t)iw * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx)
        return image;
    CGContextDrawImage(ctx, CGRectMake(0, 0, iw, ih), image.CGImage);
    CGContextRelease(ctx);

    NSError *err = nil;
    NSUInteger sn = 0, sd = 0, ow = 0, oh = 0;
    NSData *up = [self upscaleBGRAData:buf
                                 width:(NSUInteger)iw
                                height:(NSUInteger)ih
                          usedScaleNum:&sn
                          usedScaleDen:&sd
                       usedOutputWidth:&ow
                      usedOutputHeight:&oh
                       compositeDevice:nil
                              texCache:NULL
                                outTex:nil
                                 error:&err];
    if (!up || sd == 0 || ow < 2 || oh < 2)
        return image;

    CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
    CGContextRef octx = CGBitmapContextCreate((void *)up.bytes, ow, oh, 8, ow * 4, cs2, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs2);
    if (!octx)
        return image;
    CGImageRef cg = CGBitmapContextCreateImage(octx);
    CGContextRelease(octx);
    if (!cg)
        return image;
    UIImage *out = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return out ?: image;
}

@end

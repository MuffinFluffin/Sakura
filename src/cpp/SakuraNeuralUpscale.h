// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@class UIImage;

@interface SakuraNeuralUpscale : NSObject

+ (nonnull instancetype)shared;

/// Pins \p device for the live upscale session (Metal texture cache IOSurface bridging can extend this later).
- (void)beginNeuralLiveSession:(nonnull id<MTLDevice>)device;
/// Releases textures cache resources (staging slots are unchanged).
- (void)endNeuralLiveSession;
/// Marks the next live upscale call to eagerly create session/cache on the arriving device (settings off→live).
- (void)prewarmLiveSessionForLastKnownSurface;

/// Reload cached compiled model when INI selection changes (called from applyEmulatorSettings).
- (void)invalidateCompiledModelCache;

/// Load the currently-selected model on a background queue so the first inference
/// doesn't stall the render/UI thread. No-op when upscale toggles are off.
- (void)warmUpAsync;

/// When \p prebuiltBGRA length equals \p src width×height×4 (packed BGRA), the infer queue uses it and skips GPU readback of \p src.
/// When a job is actually queued, \p volatilePackedBGRABase length \p volatilePackedBGRALength is copied (PS1 scratch); pass NULL/0 if unused.
- (nullable id<MTLTexture>)upscaleBGRATextureIfEnabled:(nullable id<MTLTexture>)src
                                          prebuiltBGRA:(nullable NSData *)prebuiltBGRA
                           volatilePackedBGRABase:(nullable const void *)volatilePackedBGRABase
                         volatilePackedBGRALength:(NSUInteger)volatilePackedBGRALength
                                                device:(nullable id<MTLDevice>)device
                                                 queue:(nullable id<MTLCommandQueue>)queue
                                       coreBaseWidth:(NSUInteger)coreBaseWidth
                                      coreBaseHeight:(NSUInteger)coreBaseHeight;

- (nullable id<MTLTexture>)upscaleBGRATextureIfEnabled:(nullable id<MTLTexture>)src
                                                device:(nullable id<MTLDevice>)device
                                                 queue:(nullable id<MTLCommandQueue>)queue
                                       coreBaseWidth:(NSUInteger)coreBaseWidth
                                      coreBaseHeight:(NSUInteger)coreBaseHeight;

/// Hook for HD replacement textures before GPU upload (returns nil if disabled / unchanged).
- (nullable UIImage *)upscaleUIImageForTextureArtIfEnabled:(nullable UIImage *)image;

- (uint64_t)neuralOutputCommitCount;

@end

NS_ASSUME_NONNULL_END

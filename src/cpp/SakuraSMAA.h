// SPDX-License-Identifier: GPL-3.0+
// Sakura SMAA driver. owns the AreaTex/SearchTex GPU lookups, the 3 SMAA pipeline objects,
// and the per-frame intermediate render targets (edges, weights). inserted between the
// presentation shader (filter+CAS+grade) and final drawable when SMAA is on.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SakuraSMAAQuality) {
    SakuraSMAAQualityOff = 0,
    SakuraSMAAQualityLow = 1,
    SakuraSMAAQualityMedium = 2,
    SakuraSMAAQualityHigh = 3,
    SakuraSMAAQualityUltra = 4,
};

@interface SakuraSMAA : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                library:(id<MTLLibrary>)library
                            outputFormat:(MTLPixelFormat)outputFormat;

@property(nonatomic, readonly) BOOL ready;

// encode the 3 SMAA passes (edge, weights, blend) reading sourceColor and writing outputTexture.
// internal edge/weight textures are recycled per drawable size.
// predicateTex: optional raw PSX raster for predicated edge detection. pass nil to disable.
- (void)applyToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  sourceColor:(id<MTLTexture>)sourceColor
                outputTexture:(id<MTLTexture>)outputTexture
               predicateTex:(nullable id<MTLTexture>)predicateTex
                       quality:(SakuraSMAAQuality)quality
                  linearSpace:(BOOL)linearSpace
            adaptiveThreshold:(BOOL)adaptiveThreshold
                pixelArtMode:(BOOL)pixelArtMode
                thresholdScale:(float)thresholdScale
            pixelArtTolerance:(float)pixelArtTolerance;

@end

NS_ASSUME_NONNULL_END

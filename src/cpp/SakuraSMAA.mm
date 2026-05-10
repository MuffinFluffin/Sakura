// SPDX-License-Identifier: GPL-3.0+
#import "SakuraSMAA.h"
#import <simd/simd.h>
#import "third_party/SMAA/AreaTex.h"
#import "third_party/SMAA/SearchTex.h"

#include <algorithm>

static inline float sak_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Match shader UBO struct layout exactly (4 float4s, 64 bytes).
typedef struct {
    simd_float4 rtMetrics;
    simd_float4 sakuraFlags;
    simd_float4 sakuraTuning;
    simd_float4 sakuraQuality;
} SakuraSMAAUbo;

@implementation SakuraSMAA {
    id<MTLDevice> _device;
    id<MTLLibrary> _library;
    MTLPixelFormat _outputFormat;

    id<MTLRenderPipelineState> _edgePipeline;
    id<MTLRenderPipelineState> _weightsPipeline;
    id<MTLRenderPipelineState> _blendPipeline;

    id<MTLTexture> _areaTex;
    id<MTLTexture> _searchTex;
    id<MTLSamplerState> _samplerLinear;
    id<MTLSamplerState> _samplerNearest;

    id<MTLTexture> _edgesTex;
    id<MTLTexture> _weightsTex;
    NSUInteger _intermediateWidth;
    NSUInteger _intermediateHeight;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                library:(id<MTLLibrary>)library
                            outputFormat:(MTLPixelFormat)outputFormat
{
    if (!device || !library) return nil;
    self = [super init];
    if (!self) return nil;
    _device = device;
    _library = library;
    _outputFormat = outputFormat;
    if (![self buildPipelines]) return nil;
    if (![self buildLookupTextures]) return nil;
    if (![self buildSamplers]) return nil;
    return self;
}

- (BOOL)ready { return _edgePipeline && _weightsPipeline && _blendPipeline && _areaTex && _searchTex; }

- (BOOL)buildPipelines
{
    NSError *err = nil;

    id<MTLFunction> edgeVS = [_library newFunctionWithName:@"sakura_smaa_edge_vs"];
    id<MTLFunction> edgeFS = [_library newFunctionWithName:@"sakura_smaa_edge_detect_ps"];
    if (!edgeVS || !edgeFS) {
        NSLog(@"[SakuraSMAA] missing edge functions");
        return NO;
    }
    {
        MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction = edgeVS;
        d.fragmentFunction = edgeFS;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRG8Unorm;
        _edgePipeline = [_device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_edgePipeline) {
            NSLog(@"[SakuraSMAA] edge pipeline failed: %@", err.localizedDescription);
            return NO;
        }
    }

    id<MTLFunction> wVS = [_library newFunctionWithName:@"sakura_smaa_weights_vs"];
    id<MTLFunction> wFS = [_library newFunctionWithName:@"sakura_smaa_blend_weights_ps"];
    if (!wVS || !wFS) {
        NSLog(@"[SakuraSMAA] missing weights functions");
        return NO;
    }
    {
        MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction = wVS;
        d.fragmentFunction = wFS;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        _weightsPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_weightsPipeline) {
            NSLog(@"[SakuraSMAA] weights pipeline failed: %@", err.localizedDescription);
            return NO;
        }
    }

    id<MTLFunction> nVS = [_library newFunctionWithName:@"sakura_smaa_neighborhood_vs"];
    id<MTLFunction> nFS = [_library newFunctionWithName:@"sakura_smaa_neighborhood_ps"];
    if (!nVS || !nFS) {
        NSLog(@"[SakuraSMAA] missing neighborhood functions");
        return NO;
    }
    {
        MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction = nVS;
        d.fragmentFunction = nFS;
        d.colorAttachments[0].pixelFormat = _outputFormat;
        _blendPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_blendPipeline) {
            NSLog(@"[SakuraSMAA] neighborhood pipeline failed: %@", err.localizedDescription);
            return NO;
        }
    }
    return YES;
}

- (BOOL)buildLookupTextures
{
    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatRG8Unorm;
        d.width = AREATEX_WIDTH;
        d.height = AREATEX_HEIGHT;
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        _areaTex = [_device newTextureWithDescriptor:d];
        if (!_areaTex) return NO;
        MTLRegion r = MTLRegionMake2D(0, 0, AREATEX_WIDTH, AREATEX_HEIGHT);
        [_areaTex replaceRegion:r mipmapLevel:0 withBytes:areaTexBytes bytesPerRow:AREATEX_PITCH];
    }
    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatR8Unorm;
        d.width = SEARCHTEX_WIDTH;
        d.height = SEARCHTEX_HEIGHT;
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        _searchTex = [_device newTextureWithDescriptor:d];
        if (!_searchTex) return NO;
        MTLRegion r = MTLRegionMake2D(0, 0, SEARCHTEX_WIDTH, SEARCHTEX_HEIGHT);
        [_searchTex replaceRegion:r mipmapLevel:0 withBytes:searchTexBytes bytesPerRow:SEARCHTEX_PITCH];
    }
    return YES;
}

- (BOOL)buildSamplers
{
    {
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = MTLSamplerMinMagFilterLinear;
        d.magFilter = MTLSamplerMinMagFilterLinear;
        d.mipFilter = MTLSamplerMipFilterNotMipmapped;
        d.sAddressMode = MTLSamplerAddressModeClampToEdge;
        d.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _samplerLinear = [_device newSamplerStateWithDescriptor:d];
    }
    {
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = MTLSamplerMinMagFilterNearest;
        d.magFilter = MTLSamplerMinMagFilterNearest;
        d.mipFilter = MTLSamplerMipFilterNotMipmapped;
        d.sAddressMode = MTLSamplerAddressModeClampToEdge;
        d.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _samplerNearest = [_device newSamplerStateWithDescriptor:d];
    }
    return _samplerLinear != nil && _samplerNearest != nil;
}

- (BOOL)ensureIntermediatesForWidth:(NSUInteger)w height:(NSUInteger)h
{
    if (w == 0 || h == 0) return NO;
    if (_edgesTex && _weightsTex && _intermediateWidth == w && _intermediateHeight == h) return YES;
    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatRG8Unorm;
        d.width = w;
        d.height = h;
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        _edgesTex = [_device newTextureWithDescriptor:d];
    }
    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.width = w;
        d.height = h;
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        _weightsTex = [_device newTextureWithDescriptor:d];
    }
    _intermediateWidth = w;
    _intermediateHeight = h;
    return _edgesTex != nil && _weightsTex != nil;
}

- (void)applyToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  sourceColor:(id<MTLTexture>)sourceColor
                outputTexture:(id<MTLTexture>)outputTexture
               predicateTex:(nullable id<MTLTexture>)predicateTex
                       quality:(SakuraSMAAQuality)quality
                  linearSpace:(BOOL)linearSpace
            adaptiveThreshold:(BOOL)adaptiveThreshold
                pixelArtMode:(BOOL)pixelArtMode
                thresholdScale:(float)thresholdScale
            pixelArtTolerance:(float)pixelArtTolerance
{
    if (!self.ready || !commandBuffer || !sourceColor || !outputTexture) return;
    NSUInteger w = outputTexture.width;
    NSUInteger h = outputTexture.height;
    if (![self ensureIntermediatesForWidth:w height:h]) return;

    SakuraSMAAUbo ubo{};
    ubo.rtMetrics = simd_make_float4(1.0f / (float)w, 1.0f / (float)h, (float)w, (float)h);
    float thrMul = sak_clampf(thresholdScale, 0.1f, 4.0f);
    if (quality == SakuraSMAAQualityLow)    thrMul *= 1.6f;
    if (quality == SakuraSMAAQualityMedium) thrMul *= 1.2f;
    if (quality == SakuraSMAAQualityHigh)   thrMul *= 1.0f;
    if (quality == SakuraSMAAQualityUltra)  thrMul *= 0.85f;
    ubo.sakuraFlags = simd_make_float4(linearSpace ? 1.f : 0.f,
                                       adaptiveThreshold ? 1.f : 0.f,
                                       pixelArtMode ? 1.f : 0.f,
                                       predicateTex ? 1.f : 0.f);
    ubo.sakuraTuning = simd_make_float4(thrMul,
                                        sak_clampf(pixelArtTolerance, 0.001f, 0.2f),
                                        1.5f, 0.4f);
    ubo.sakuraQuality = simd_make_float4((float)quality, 0.f, 0.f, 0.f);

    // pass 1: edge detection
    {
        MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture = _edgesTex;
        pd.colorAttachments[0].loadAction = MTLLoadActionClear;
        pd.colorAttachments[0].storeAction = MTLStoreActionStore;
        pd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pd];
        if (!enc) return;
        [enc setRenderPipelineState:_edgePipeline];
        [enc setVertexBytes:&ubo length:sizeof(ubo) atIndex:0];
        [enc setFragmentBytes:&ubo length:sizeof(ubo) atIndex:0];
        [enc setFragmentTexture:sourceColor atIndex:0];
        if (predicateTex) [enc setFragmentTexture:predicateTex atIndex:1];
        else              [enc setFragmentTexture:sourceColor atIndex:1];
        [enc setFragmentSamplerState:_samplerLinear atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
    }

    // pass 2: blend weights (samples AreaTex + SearchTex with linear filtering)
    {
        MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture = _weightsTex;
        pd.colorAttachments[0].loadAction = MTLLoadActionClear;
        pd.colorAttachments[0].storeAction = MTLStoreActionStore;
        pd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pd];
        if (!enc) return;
        [enc setRenderPipelineState:_weightsPipeline];
        [enc setVertexBytes:&ubo length:sizeof(ubo) atIndex:0];
        [enc setFragmentBytes:&ubo length:sizeof(ubo) atIndex:0];
        [enc setFragmentTexture:_edgesTex atIndex:0];
        [enc setFragmentTexture:_areaTex atIndex:1];
        [enc setFragmentTexture:_searchTex atIndex:2];
        [enc setFragmentSamplerState:_samplerLinear atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
    }

    // pass 3: neighborhood blending
    {
        MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture = outputTexture;
        pd.colorAttachments[0].loadAction = MTLLoadActionClear;
        pd.colorAttachments[0].storeAction = MTLStoreActionStore;
        pd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pd];
        if (!enc) return;
        [enc setRenderPipelineState:_blendPipeline];
        [enc setVertexBytes:&ubo length:sizeof(ubo) atIndex:0];
        [enc setFragmentBytes:&ubo length:sizeof(ubo) atIndex:0];
        [enc setFragmentTexture:sourceColor atIndex:0];
        [enc setFragmentTexture:_weightsTex atIndex:1];
        [enc setFragmentSamplerState:_samplerLinear atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
    }
}

@end

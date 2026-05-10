#import "SakuraPS1Core.h"
#import "SakuraBridge.h"
#import "SakuraNeuralUpscale.h"
#import "SakuraSMAA.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define SAKURA_HAS_METALFX 1
#else
#define SAKURA_HAS_METALFX 0
#endif
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <mutex>
#include <condition_variable>
#include <sys/stat.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <vector>

#include "IOSNativeFileIO.h"
#include "SakuraLibretro.h"

#if TARGET_OS_IPHONE
extern "C" void Sakura_IOS_ConfigureGameAudioSession(double coreSampleRate);
#endif

static NSString *SakuraUppercaseSHA1Hex(const unsigned char digest[CC_SHA1_DIGEST_LENGTH])
{
    static const char *hex = "0123456789ABCDEF";
    char buf[CC_SHA1_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; ++i) {
        buf[i * 2] = hex[digest[i] >> 4];
        buf[i * 2 + 1] = hex[digest[i] & 0xF];
    }
    buf[CC_SHA1_DIGEST_LENGTH * 2] = '\0';
    return @(buf);
}

static NSString *_Nullable SakuraSHA1HexOfFileAtPath(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    CC_SHA1_CTX ctx{};
    CC_SHA1_Init(&ctx);
    unsigned char buf[64 * 1024];
    ssize_t n = 0;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        CC_SHA1_Update(&ctx, buf, (CC_LONG)n);
    }
    close(fd);
    if (n < 0) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH]{};
    CC_SHA1_Final(digest, &ctx);
    return SakuraUppercaseSHA1Hex(digest);
}

static NSDictionary<NSString *, NSString *> *SakuraKnownPS1BIOSCanonicalMap(void)
{
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"343883A7B555646DA8CEE54AADD2795B6E7DD070": @"scph5500.bin",
            @"339A48F4FCF63E10B5B867B8C93CFD40945FAF6C": @"scph5500.bin",
            @"B06F4A861F74270BE819AA2A07DB8D0563A7CC4E": @"scph5500.bin",
            @"E38466A4BA8005FBA7E9E3C7B9EFEBA7205BEE3F": @"scph5500.bin",
            @"E340DB2696274DDA5FDC25E434A914DB71E8B02B": @"scph5500.bin",
            @"B05DEF971D8EC59F346F2D9AC21FB742E3EB6917": @"scph5500.bin",
            @"77B10118D21AC7FFA9B35F9C4FD814DA240EB3E9": @"scph5500.bin",
            @"FFA7F9A7FB19D773A0C3985A541C8E5623D2C30D": @"scph5500.bin",
            @"15C94DA3CC5A38A582429575AF4198C487FE893C": @"scph5500.bin",

            @"10155D8D6E6E832D6EA66DB9BC098321FB5E8EBF": @"scph5501.bin",
            @"0555C6FAE8906F3F09BAF5988F00E55F88E9F30B": @"scph5501.bin",
            @"14DF4F6C1E367CE097C11DEAE21566B4FE5647A9": @"scph5501.bin",
            @"DCFFE16BD90A723499AD46C641424981338D8378": @"scph5501.bin",
            @"BEB0AC693C0DC26DAF5665B3314DB81480FA5C7C": @"scph5501.bin",

            @"649895EFD79D14790EABB362E94EB0622093DFB9": @"scph5501.bin",
            @"CA7AF30B50D9756CBD764640126C454CFF658479": @"scph5501.bin",

            @"20B98F3D80F11CBFA7BFD0779B0E63760ECC62C": @"scph5502.bin",
            @"76CF6B1B2A7C571A6AD07F2BAC0DB6CD8F71E2CC": @"scph5502.bin",
            @"F6BC2D1F5EB6593DE7D089C425AC681D6FFFD3F0": @"scph5502.bin",
            @"8D5DE56A79954F29E9006929BA3FED9B6A418C1D": @"scph5502.bin",
            @"DBC7339E5D85827C095764FC077B41F78FD2ECAE": @"scph5502.bin",

            @"96880D1CA92A016FF054BE5159BB06FE03CB4E14": @"psxonpsp660.bin",
            @"C40146361EB8CF670B19FDC9759190257803CAB7": @"ps1_rom.bin",
        };
    });
    return map;
}

static BOOL SakuraFileLooksLikePS1BIOSCandidate(NSString *path, NSString *filename, unsigned long long size)
{
    NSString *ext = filename.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"bin"] || [ext isEqualToString:@"rom"] || [ext isEqualToString:@"scph"]) return YES;
    if ([path.lastPathComponent hasPrefix:@"."]) return NO;
    if (size == 524288ULL || size == 1048576ULL) return YES;
    return NO;
}

static NSString *_Nullable SakuraCanonicalBIOSFromFilename(NSString *filename)
{
    NSString *lower = filename.lowercaseString;
    if ([lower containsString:@"102b"] || [lower containsString:@"102c"]) return @"scph5502.bin";
    if ([lower containsString:@"102a"]) return @"scph5501.bin";

    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?i)scph(?:[_\\s-]|)(\\d{3,4})(?!\\d)"
                                                                          options:0
                                                                            error:&err];
    if (!re || err) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *digits = [filename substringWithRange:[m rangeAtIndex:1]];
    NSInteger code = digits.integerValue;
    if (code == 100) return @"scph5500.bin";
    if (code == 101) return @"scph5501.bin";
    if (code == 102) return @"scph5502.bin";

    static NSSet<NSNumber *> *jp = nil;
    static NSSet<NSNumber *> *na = nil;
    static NSSet<NSNumber *> *eu = nil;
    static dispatch_once_t onceNames;
    dispatch_once(&onceNames, ^{
        jp = [NSSet setWithArray:@[@(1000), @(3000), @(3500), @(5000), @(5500), @(5903), @(7000), @(7500), @(9000)]];
        na = [NSSet setWithArray:@[@(1001), @(3001), @(3501), @(5001), @(5003), @(5501), @(5503), @(7001), @(7003), @(7501),
                                  @(7503), @(9001), @(9003)]];
        eu = [NSSet setWithArray:@[@(1002), @(3002), @(3502), @(5002), @(5502), @(5552), @(7002), @(7502), @(9002)]];
    });
    NSNumber *n = @(code);
    if ([jp containsObject:n]) return @"scph5500.bin";
    if ([na containsObject:n]) return @"scph5501.bin";
    if ([eu containsObject:n]) return @"scph5502.bin";
    return nil;
}

static BOOL SakuraTryInstallBIOS(NSFileManager *fm, NSString *biosDir, NSString *canonicalName, NSString *srcPath)
{
    NSString *dst = [biosDir stringByAppendingPathComponent:canonicalName];
    if ([fm fileExistsAtPath:dst]) return NO;
    NSError *copyErr = nil;
    if ([fm copyItemAtPath:srcPath toPath:dst error:&copyErr]) return YES;
    NSLog(@"[SakuraPS1Core] BIOS staging failed %@ -> %@ (%@)", srcPath.lastPathComponent, canonicalName, copyErr.localizedDescription);
    return NO;
}

namespace {
constexpr double kSakuraPi = 3.14159265358979323846;
static uint32_t SakuraAudioDithState = 0xC001D00Du;

static inline uint32_t SakuraBitsFloat(float f)
{
    union {
        float f;
        uint32_t u;
    } b;
    b.f = f;
    return b.u;
}

static void SakuraEasuCon(simd_uint4 *__restrict con0, simd_uint4 *__restrict con1, simd_uint4 *__restrict con2,
    simd_uint4 *__restrict con3, float inVpX, float inVpY, float inSzX, float inSzY, float outPx, float outPy)
{
    const float rcpOutX = 1.0f / std::max(outPx, 1.0f);
    const float rcpOutY = 1.0f / std::max(outPy, 1.0f);
    const float rcpSzX = 1.0f / std::max(inSzX, 1.0f);
    const float rcpSzY = 1.0f / std::max(inSzY, 1.0f);
    uint32_t c0[4];
    c0[0] = SakuraBitsFloat(inVpX * rcpOutX);
    c0[1] = SakuraBitsFloat(inVpY * rcpOutY);
    c0[2] = SakuraBitsFloat(0.5f * inVpX * rcpOutX - 0.5f);
    c0[3] = SakuraBitsFloat(0.5f * inVpY * rcpOutY - 0.5f);
    uint32_t c1[4];
    c1[0] = SakuraBitsFloat(rcpSzX);
    c1[1] = SakuraBitsFloat(rcpSzY);
    c1[2] = SakuraBitsFloat(rcpSzX);
    c1[3] = SakuraBitsFloat(-rcpSzY);
    uint32_t c2[4];
    c2[0] = SakuraBitsFloat(-rcpSzX);
    c2[1] = SakuraBitsFloat(2.0f * rcpSzY);
    c2[2] = SakuraBitsFloat(rcpSzX);
    c2[3] = SakuraBitsFloat(2.0f * rcpSzY);
    uint32_t c3[4];
    c3[0] = SakuraBitsFloat(0.0f);
    c3[1] = SakuraBitsFloat(4.0f * rcpSzY);
    c3[2] = 0;
    c3[3] = 0;
    *con0 = simd_make_uint4(c0[0], c0[1], c0[2], c0[3]);
    *con1 = simd_make_uint4(c1[0], c1[1], c1[2], c1[3]);
    *con2 = simd_make_uint4(c2[0], c2[1], c2[2], c2[3]);
    *con3 = simd_make_uint4(c3[0], c3[1], c3[2], c3[3]);
}

typedef struct {
    simd_int4 packed;
    simd_float4 ts;
    simd_uint4 easuCon0;
    simd_uint4 easuCon1;
    simd_uint4 easuCon2;
    simd_uint4 easuCon3;
    simd_float4 dims;
    simd_float4 uvRect;
    simd_float4 color0;
    simd_float4 color1;
    simd_float4 color2;
    simd_float4 hdr0;
    simd_float4 hdr1;
} SakuraPresentUBO;

static inline double SakuraAudioTpdfHalfLSB(void)
{
    SakuraAudioDithState ^= SakuraAudioDithState << 13;
    SakuraAudioDithState ^= SakuraAudioDithState >> 17;
    SakuraAudioDithState ^= SakuraAudioDithState << 5;
    const double u1 = static_cast<double>(SakuraAudioDithState & 0xFFFFFFu) / 16777216.0;
    const double u2 = static_cast<double>((SakuraAudioDithState >> 9) & 0xFFFFFFu) / 16777216.0;
    return (u1 + u2 - 1.0) * 0.42;
}
}

#ifndef SAKURA_ENABLE_LIBRETRO_PSX
#define SAKURA_ENABLE_LIBRETRO_PSX 0
#endif

#if SAKURA_ENABLE_LIBRETRO_PSX
extern "C" {
void retro_set_environment(retro_environment_t cb);
void retro_set_video_refresh(retro_video_refresh_t cb);
void retro_set_audio_sample(retro_audio_sample_t cb);
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb);
void retro_set_input_poll(retro_input_poll_t cb);
void retro_set_input_state(retro_input_state_t cb);
void retro_init(void);
void retro_deinit(void);
unsigned retro_api_version(void);
void retro_get_system_info(struct retro_system_info *info);
void retro_get_system_av_info(struct retro_system_av_info *info);
bool retro_load_game(const struct retro_game_info *game);
void retro_unload_game(void);
void retro_run(void);
void retro_reset(void);
size_t retro_serialize_size(void);
bool retro_serialize(void *data, size_t size);
bool retro_unserialize(const void *data, size_t size);
void retro_set_controller_port_device(unsigned port, unsigned device);
void *retro_get_memory_data(unsigned id);
size_t retro_get_memory_size(unsigned id);
}
#endif

#ifndef RETRO_MEMORY_SAVE_RAM
#define RETRO_MEMORY_SAVE_RAM 0
#endif

static std::atomic<bool> g_sakuraScreenIsCaptured{false};

extern "C" void Sakura_IOS_SetScreenIsCaptured(bool captured) {
    g_sakuraScreenIsCaptured.store(captured, std::memory_order_relaxed);
}

static NSString * const SakuraPS1ErrorDomain = @"SakuraPS1Core";
static NSString * const SakuraGeometryChangedNotification = @"SakuraUpscaleMultiplierChanged";
static SakuraPS1Core *g_sakuraPS1Core = nil;

static void SakuraAudioQueueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer);
static int SakuraAxisToRetro(float value);
static int SakuraRetroIDForSakuraButton(NSInteger button);
static void SakuraPostGeometryChanged(void);

#if SAKURA_ENABLE_LIBRETRO_PSX
static bool SakuraRetroEnvironment(unsigned cmd, void *data);
static const char *SakuraRetroVariableValueForKey(const char *key);
static void SakuraRetroVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch);
static void SakuraRetroAudioSample(int16_t left, int16_t right);
static size_t SakuraRetroAudioSampleBatch(const int16_t *data, size_t frames);
static void SakuraRetroInputPoll(void);
static int16_t SakuraRetroInputState(unsigned port, unsigned device, unsigned index, unsigned id);
static const char *SakuraVFSGetPath(struct retro_vfs_file_handle *stream);
static struct retro_vfs_file_handle *SakuraVFSOpen(const char *path, unsigned mode, unsigned hints);
static int SakuraVFSClose(struct retro_vfs_file_handle *stream);
static int64_t SakuraVFSSize(struct retro_vfs_file_handle *stream);
static int64_t SakuraVFSTell(struct retro_vfs_file_handle *stream);
static int64_t SakuraVFSSeek(struct retro_vfs_file_handle *stream, int64_t offset, int seekPosition);
static int64_t SakuraVFSRead(struct retro_vfs_file_handle *stream, void *s, uint64_t len);
static int64_t SakuraVFSWrite(struct retro_vfs_file_handle *stream, const void *s, uint64_t len);
static int SakuraVFSFlush(struct retro_vfs_file_handle *stream);
static int SakuraVFSRemove(const char *path);
static int SakuraVFSRename(const char *oldPath, const char *newPath);
static int64_t SakuraVFSTruncate(struct retro_vfs_file_handle *stream, int64_t length);
static bool SakuraWriteFileAtomic(NSString *path, const void *data, size_t size);
#endif
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if SAKURA_ENABLE_LIBRETRO_PSX
static NSString *SakuraPS1SanitizeFolderName(NSString *name);
static NSString *SakuraPS1SaveStatesRoot(void);
static NSString *SakuraPS1SaveStatesLegacyRoot(void);
static uint32_t SakuraPS1PathTagUTF8(const char *utf8);
static NSString *SakuraPS1SubfolderForLibraryEntry(NSString *entry);
static NSString *SakuraPS1LegacyFlatStem(NSString *entry);
static NSString *SakuraPS1CanonicalSlotStatePath(NSString *libraryEntry, int slot);
static NSString *SakuraPS1LegacySubfolderSlotStatePath(NSString *libraryEntry, int slot);
static NSString *SakuraPS1LegacySlotStatePath(NSString *libraryEntry, int slot);
static NSString *SakuraPS1ResolveSlotStatePath(NSString *libraryEntry, int slot);
static NSString *SakuraPS1PreviewPNGAdjacentToResolvedState(NSString *resolvedOrCanonicalStatePath);
static BOOL SakuraPS1WritePNGFromBGRAPremultiplied(NSData *tightBGRA, unsigned width, unsigned height, NSString *path);
#endif

@interface SakuraPS1Core () {
    __weak UIView *_renderView;
    UIImageView *_imageView;
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalCommandQueue;
    id<MTLRenderPipelineState> _metalPipeline;
    id<MTLRenderPipelineState> _metalBlendPipeline;
    id<MTLLibrary> _presentationLibrary;
    id<MTLRenderPipelineState> _metalPresentPipeline;
    // SMAA pre-final-blit pipeline. Existing present shader runs into _smaaInputTex,
    // SMAA driver does 3 passes, final neighborhood-blend pass writes the drawable.
    SakuraSMAA* _smaa;
    id<MTLTexture> _smaaInputTex;
    NSUInteger _smaaInputW;
    NSUInteger _smaaInputH;
    MTLPixelFormat _smaaInputFmt;
    std::mutex _presColorMutex;
    bool _presColorAdjEnabled;
    float _presColorSaturation;
    float _presBright;
    float _presContr;
    float _presVibr;
    float _presExpo;
    float _presGamma;
    float _presCT;
    float _presSharp;
    float _presBloom;
    float _presBloomRad;
    float _presVign;
    float _presVignRad;
    bool _presHdrGrade;
    bool _presHdrDrawable;
    float _presHdrExpo;
    float _presHdrSat;
    float _presHdrContr;
    float _presHdrBloom;
    float _presShadow;
    float _presHi;
    id<MTLSamplerState> _samplerNearest;
    id<MTLSamplerState> _samplerLinear;
    MTLPixelFormat _metalDrawablePipelineFormat;
    id<MTLTexture> _frameTexture;
    id<MTLTexture> _previousFrameTexture;
    id<MTLTexture> _interpolatedFrameTexture;
    NSUInteger _previousFrameWidth;
    NSUInteger _previousFrameHeight;
#if SAKURA_HAS_METALFX
    id<MTLFXSpatialScaler> _displayScaler;
    id<MTLFXSpatialScaler> _textureScaler;
    id<MTLTexture> _textureScalerOut;
    id<MTLTexture> _displayScalerIn;
    id<MTLTexture> _displayScalerOut;
    id<MTLFXTemporalScaler> _displayTemporalScaler;
    id<MTLTexture> _displayTemporalOut;
    id<MTLTexture> _displayTemporalDepth;
    id<MTLTexture> _displayTemporalMotion;
    id<MTLTexture> _displayTemporalExposure;
    NSUInteger _displayTemporalLastInW;
    NSUInteger _displayTemporalLastInH;
    NSUInteger _displayTemporalLastOutW;
    NSUInteger _displayTemporalLastOutH;
    MTLPixelFormat _scalerColorFormat;
    NSUInteger _textureScalerInWidth;
    NSUInteger _textureScalerInHeight;
    NSUInteger _textureScalerOutWidth;
    NSUInteger _textureScalerOutHeight;
    NSUInteger _displayScalerInWidth;
    NSUInteger _displayScalerInHeight;
    NSUInteger _displayScalerOutWidth;
    NSUInteger _displayScalerOutHeight;
    id _metalFXFrameInterpolator;
    id<MTLTexture> _metalFXFIOutputTexture;
    id<MTLTexture> _metalFXFIDepthTexture;
    id<MTLTexture> _metalFXFIMotionTexture;
    NSUInteger _metalFXFIWidth;
    NSUInteger _metalFXFIHeight;
    BOOL _metalFXFINeedHistoryReset;
#endif
    AudioQueueRef _audioQueue;
    AudioStreamBasicDescription _audioStreamDescription;
    std::vector<AudioQueueBufferRef> _audioBuffers;
    UInt32 _audioBufferByteSize;

    std::atomic<bool> _running;
    std::atomic<bool> _paused;
    // Per-port (0 = PS1 player 1, 1 = PS1 player 2) virtual / physical pad state.
    std::atomic<int> _buttons[2][16];
    std::atomic<int> _physicalPadButtons[2][16];
    std::atomic<int> _leftX[2];
    std::atomic<int> _leftY[2];
    std::atomic<int> _rightX[2];
    std::atomic<int> _rightY[2];
    std::atomic<int> _physLeftX[2];
    std::atomic<int> _physLeftY[2];
    std::atomic<int> _physRightX[2];
    std::atomic<int> _physRightY[2];
    std::atomic<uint64_t> _framesRendered;
    std::atomic<uint64_t> _metalDrawablePresentCount;
    std::atomic<double> _fps;
    std::atomic<double> _vps;
    std::atomic<double> _targetFPS;
    std::atomic<double> _hostEmulationSpeed;
    std::atomic<int> _aspectRatio;
    std::atomic<bool> _integerScaling;
    std::atomic<float> _upscaleMultiplier;
    std::atomic<bool> _metalFXDisplay;
    std::atomic<bool> _metalFXTemporalDisplayEnabled;
    std::atomic<bool> _metalFXTexture;
    std::atomic<bool> _metalFXFrameInterpolation;
    std::atomic<bool> _gpuCpuDecouple;
    std::atomic<bool> _videoToolboxIOS26FrameFeatures;
    std::atomic<int> _textureFilter;
    std::atomic<bool> _autoSwitchControllerMode;
    std::atomic<bool> _sawAnalogPoll[2];
    std::atomic<unsigned> _baseWidth;
    std::atomic<unsigned> _baseHeight;
    std::atomic<float> _coreAspectRatio;
    std::atomic<bool> _fastBoot;
    std::atomic<bool> _variablesDirty;
    std::mutex _varOverrideMutex;
    std::unordered_map<std::string, std::string> _varOverrides;

    std::mutex _coreMutex;
    std::thread _runThread;
    std::mutex _renderMutex;
    std::vector<uint8_t> _frameScratch;
    unsigned _textureWidth;
    unsigned _textureHeight;

    std::mutex _mailboxMutex;
    NSData *_mailboxCurr;
    unsigned _mailboxW;
    unsigned _mailboxH;
    bool _mailboxFlushScheduled;
    NSData *_lastDisplayedCpuFrame;

    std::mutex _cadenceMutex;
    NSData *_cadenceDupCurr;
    NSData *_cadenceDupPrev;
    unsigned _cadenceDupW;
    unsigned _cadenceDupH;

    std::mutex _audioMutex;
    std::condition_variable _audioCond;
    size_t _audioSampleLimit;
    std::vector<int16_t> _audioRing;
    size_t _audioReadIndex;
    size_t _audioWriteIndex;
    size_t _audioSampleCount;

    std::atomic<int32_t> _audioLatencyMs;
    std::atomic<bool> _audioSyncEnabled;
    std::atomic<bool> _audioMuteWhenTurbo;
    std::atomic<bool> _audioTimeStretchEnabled;
    std::atomic<double> _audioCoreSampleRate;
    double _audioStretchAcc;
    int16_t _audioStretchPrevL;
    int16_t _audioStretchPrevR;
    int16_t _audioStretchCurrL;
    int16_t _audioStretchCurrR;
    bool _audioStretchPrimed;

    enum retro_pixel_format _pixelFormat;
    std::string _systemDirectory;
    std::string _saveDirectory;
    NSString *_loadedGamePath;
    NSString *_loadedLibraryISOEntry;

    std::mutex _saveThumbMutex;
    NSData *_saveThumbBGRA;
    unsigned _saveThumbW;
    unsigned _saveThumbH;

    // SRAM (memory-card) persistence. Beetle-PSX exposes both memory cards
    // serialized as one contiguous block via RETRO_MEMORY_SAVE_RAM; the
    // frontend is responsible for reading that on boot and flushing to disk
    // periodically + on shutdown. Without this, every game boots with empty
    // cards and every in-game save is lost on quit.
    std::mutex _sramMutex;
    uint64_t _sramLastHash;
    NSString *_sramPathForLoadedGame;
    std::atomic<uint64_t> _sramFlushTickCounter;

    NSString *_lastError;
    std::atomic<int> _storedControllerMode[2];
    std::atomic<bool> _retroPortDeviceDirty;
    std::atomic<bool> _textureMetalFXResourcesDirty;
    std::atomic<bool> _displayMetalFXResourcesDirty;
    std::atomic<bool> _frameInterpResourcesDirty;
    std::atomic<bool> _videoToolboxResourcesDirty;
}

#if SAKURA_ENABLE_LIBRETRO_PSX
- (void)runLoopWithTargetFPS:(double)targetFPS;
#endif
- (void)configureMetalLayerOnMainThread;
- (BOOL)ensureMetalPipelineLocked;
- (BOOL)renderTextureLocked:(id<MTLTexture>)source
                  toTexture:(id<MTLTexture>)target
              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   viewport:(MTLViewport)viewport
                      clear:(BOOL)clear;
- (BOOL)renderBlendLocked:(id<MTLTexture>)prevTexture
                  current:(id<MTLTexture>)currTexture
                toTexture:(id<MTLTexture>)target
            commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                 viewport:(MTLViewport)viewport;
#if SAKURA_HAS_METALFX
- (void)dropMetalFXLocked;
- (void)synchronizeDeferredMetalFXResourceTearsLocked;
- (void)dropDisplayMetalFXLocked;
- (void)dropTextureMetalFXLocked;
- (id<MTLTexture>)textureMetalFXSourceLocked:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (id<MTLTexture>)displayMetalFXSourceLocked:(id<MTLTexture>)source
                                commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                  outputWidth:(NSUInteger)outputWidth
                                 outputHeight:(NSUInteger)outputHeight;
- (void)dropMetalFXFrameInterpolatorLocked;
- (BOOL)ensureMetalFXFrameInterpolatorLocked:(NSUInteger)frameWidth frameHeight:(NSUInteger)frameHeight;
- (BOOL)clearDepth32TextureLocked:(id<MTLTexture>)depthTexture commandBuffer:(id<MTLCommandBuffer>)commandBuffer clearDepth:(double)clearDepth;
- (BOOL)clearRG16MotionTextureLocked:(id<MTLTexture>)motionTexture commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (id<MTLTexture>)sakuraNeuralUpscaleSourceIfEnabledLocked:(id<MTLTexture>)src prebuiltBGRA:(nullable NSData *)prebuiltBGRA volatilePackedBGRABase:(nullable const void *)volatilePackedBGRABase volatilePackedBGRALength:(NSUInteger)volatilePackedBGRALength;
- (BOOL)presentMetalFXInterpolatedFrameLocked:(id<MTLTexture>)drawableTexture
                                     viewport:(MTLViewport)viewport
                           viewportPixelWidth:(NSUInteger)viewportPixelWidth
                          viewportPixelHeight:(NSUInteger)viewportPixelHeight
                                commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
#endif
- (NSData *)copyBGRATightFrame:(const void *)data pitch:(size_t)pitch width:(unsigned)width height:(unsigned)height;
- (void)presentFramebufferGPUChainLockedPrevCPU:(NSData *)prev
                                       currCPU:(NSData *)curr
                                         width:(unsigned)width
                                        height:(unsigned)height
                               incrementRendered:(BOOL)incrementRendered;
- (void)enqueueMailboxGpuPresentCurrCPU:(NSData *)curr width:(unsigned)width height:(unsigned)height;
- (void)flushMailboxGpuPresentsOnMain;
- (void)clearGpuPresentMailbox;
- (void)fillAudioQueueBuffer:(AudioQueueBufferRef)buffer;

#if SAKURA_ENABLE_LIBRETRO_PSX
- (void)cacheLatestSaveThumbnailFromBGRA:(NSData *)pix width:(unsigned)width height:(unsigned)height;
- (NSData *)copyLatestSaveThumbnailWidth:(unsigned *)outW height:(unsigned *)outH;
#endif

@end

#if SAKURA_ENABLE_LIBRETRO_PSX

static uint32_t SakuraPS1PathTagUTF8(const char *utf8)
{
    if (!utf8) return 2166136261u;
    uint32_t h = 2166136261u;
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(utf8); *p; p++) {
        h ^= static_cast<uint32_t>(*p);
        h *= 16777619u;
    }
    return h;
}

static NSString *SakuraPS1SanitizeFolderName(NSString *name)
{
    if (!name.length) return @"";
    NSString *repl = @"_";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\*?\"<>|%"];
    NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:bad];
    NSMutableString *m = [NSMutableString stringWithString:parts.firstObject ?: @""];
    for (NSUInteger i = 1; i < parts.count; i++)
        [m appendFormat:@"%@%@", repl, parts[i]];
    NSString *out = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableString *t = out.mutableCopy;
    while (t.length > 0 && [t characterAtIndex:0] == ' ')
        [t deleteCharactersInRange:NSMakeRange(0, 1)];
    while (t.length > 0 && [t characterAtIndex:t.length - 1] == ' ')
        [t deleteCharactersInRange:NSMakeRange(t.length - 1, 1)];
    out = t.length <= 120 ? t : [t substringToIndex:120];
    return out.length ? out : @"nogame";
}

static NSString *SakuraPS1SaveStatesRoot(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"SaveStates"];
}

static NSString *SakuraPS1SaveStatesLegacyRoot(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"SaveStates/PS1"];
}

static NSString *SakuraPS1SubfolderForLibraryEntry(NSString *entry)
{
    if (!entry.length) return @"nogame";

    // Callers are wildly inconsistent: the save path passes BootISO (full
    // path or relative; whatever the launcher stuffed into INI), the read
    // path passes GameItem.fileName (bare leaf). Different inputs → different
    // `SakuraPS1PathTagUTF8` in the no-serial fallback → different subfolders
    // → saved .state + .preview.png land under one folder while the reader
    // hunts in another. Normalize to the leaf basename BEFORE doing anything
    // so both sides agree.
    NSString *norm = entry.lastPathComponent.length ? entry.lastPathComponent : entry;

    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t once;
    static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionaryWithCapacity:64];
    });

    os_unfair_lock_lock(&cacheLock);
    NSString *cached = cache[norm];
    os_unfair_lock_unlock(&cacheLock);
    if (cached.length) return cached;

    NSString *abs = [SakuraBridge resolvedAbsolutePathForLibraryISO:norm];
    NSString *serial = abs.length ? [SakuraBridge isoSerialForPath:abs] : @"";
    NSString *titleRaw = abs.length ? [SakuraBridge isoTitleForPath:abs] : @"";
    NSString *title = [titleRaw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *fallbackStem = SakuraPS1SanitizeFolderName(norm.stringByDeletingPathExtension);
    if (!title.length) title = fallbackStem;
    NSString *folder = @"";
    if (serial.length > 0 && title.length > 0) {
        NSString *sanT = SakuraPS1SanitizeFolderName(title);
        folder = [NSString stringWithFormat:@"%@ [%@]", sanT, serial];
    } else if (serial.length > 0) {
        folder = SakuraPS1SanitizeFolderName(serial);
    } else {
        NSString *stem = fallbackStem.length ? fallbackStem : @"nogame";
        // Hash the normalized leaf, not the raw input. Save/read now both
        // feed the same bytes in, so both sides land on the same folder.
        uint32_t tag = SakuraPS1PathTagUTF8(norm.UTF8String ?: "");
        folder = [NSString stringWithFormat:@"%@_%08X", stem, (unsigned int)tag];
    }
    NSString *result = folder.length ? folder : @"nogame";

    os_unfair_lock_lock(&cacheLock);
    cache[norm] = result;
    os_unfair_lock_unlock(&cacheLock);
    return result;
}

static NSString *SakuraPS1LegacyFlatStem(NSString *entry)
{
    NSString *base = entry.lastPathComponent.length ? entry.lastPathComponent : @"nogame";
    return [[base componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"]]
             componentsJoinedByString:@"_"];
}

static NSString *SakuraPS1CanonicalSlotStatePath(NSString *libraryEntry, int slot)
{
    NSString *sub = SakuraPS1SubfolderForLibraryEntry(libraryEntry);
    NSString *gameDir = [SakuraPS1SaveStatesRoot() stringByAppendingPathComponent:sub];
    NSString *fn = [NSString stringWithFormat:@"slot%d.state", slot];
    return [gameDir stringByAppendingPathComponent:fn];
}

static NSString *SakuraPS1LegacySubfolderSlotStatePath(NSString *libraryEntry, int slot)
{
    NSString *sub = SakuraPS1SubfolderForLibraryEntry(libraryEntry);
    NSString *gameDir = [SakuraPS1SaveStatesLegacyRoot() stringByAppendingPathComponent:sub];
    NSString *fn = [NSString stringWithFormat:@"slot%d.state", slot];
    return [gameDir stringByAppendingPathComponent:fn];
}

static NSString *SakuraPS1LegacySlotStatePath(NSString *libraryEntry, int slot)
{
    NSString *safe = SakuraPS1LegacyFlatStem(libraryEntry);
    return [[SakuraPS1SaveStatesLegacyRoot() stringByAppendingPathComponent:safe]
             stringByAppendingPathExtension:[NSString stringWithFormat:@"slot%d.state", slot]];
}

static NSString *SakuraPS1ResolveSlotStatePath(NSString *libraryEntry, int slot)
{
    NSString *can = SakuraPS1CanonicalSlotStatePath(libraryEntry, slot);
    NSString *legSub = SakuraPS1LegacySubfolderSlotStatePath(libraryEntry, slot);
    NSString *legFlat = SakuraPS1LegacySlotStatePath(libraryEntry, slot);
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:can]) return can;
    if ([fm fileExistsAtPath:legSub]) return legSub;
    if ([fm fileExistsAtPath:legFlat]) return legFlat;
    return can;
}

static NSString *SakuraPS1PreviewPNGAdjacentToResolvedState(NSString *statePath)
{
    if (!statePath.length) return @"";
    NSString *folder = statePath.stringByDeletingLastPathComponent;
    NSString *stem = statePath.lastPathComponent.stringByDeletingPathExtension;
    NSString *fname = [stem stringByAppendingPathExtension:@"preview.png"];
    return [folder stringByAppendingPathComponent:fname];
}

static BOOL SakuraPS1WritePNGFromBGRAPremultiplied(NSData *tightBGRA, unsigned width, unsigned height, NSString *path)
{
    if (!path.length || width == 0 || height == 0 || !tightBGRA.length)
        return NO;
    const size_t need = (size_t)width * (size_t)height * 4u;
    if (tightBGRA.length < need)
        return NO;
    NSString *folder = path.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)tightBGRA);
    if (!prov || !cs) {
        if (prov) CGDataProviderRelease(prov);
        if (cs) CGColorSpaceRelease(cs);
        return NO;
    }
    CGBitmapInfo bi =
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img =
        CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)width * 4u, cs, bi, prov, nullptr, NO, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    if (!img) return NO;

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    if (!dest) {
        CGImageRelease(img);
        return NO;
    }
    CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef) @{});
    const bool ok = CGImageDestinationFinalize(dest);
    CGImageRelease(img);
    CFRelease(dest);
    return ok;
}

static NSData *SakuraPS1ResizedBGRAPremultiplied(NSData *tightBGRA, unsigned srcW, unsigned srcH, unsigned dstW, unsigned dstH)
{
    if (!tightBGRA.length || srcW == 0 || srcH == 0 || dstW == 0 || dstH == 0)
        return nil;
    const size_t srcNeed = (size_t)srcW * (size_t)srcH * 4u;
    if (tightBGRA.length < srcNeed)
        return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)tightBGRA);
    if (!prov || !cs) {
        if (prov) CGDataProviderRelease(prov);
        if (cs) CGColorSpaceRelease(cs);
        return nil;
    }
    CGBitmapInfo bi = static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGImageCreate((size_t)srcW, (size_t)srcH, 8, 32, (size_t)srcW * 4u, cs, bi, prov, nullptr, NO, kCGRenderingIntentDefault);
    CGDataProviderRelease(prov);
    if (!img) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    NSMutableData *dstData = [NSMutableData dataWithLength:(size_t)dstW * (size_t)dstH * 4u];
    CGContextRef ctx = CGBitmapContextCreate(dstData.mutableBytes, dstW, dstH, 8, (size_t)dstW * 4u, cs, bi);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CGImageRelease(img);
        return nil;
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dstW, dstH), img);
    CGContextRelease(ctx);
    CGImageRelease(img);
    return dstData;
}

#endif

static double SakuraPresentSourceAspect(int aspectMode, float coreReported, unsigned baseW, unsigned baseH, unsigned frameW,
    unsigned frameH)
{
    if (aspectMode == 1)
        return 16.0 / 9.0;
    if (aspectMode == 2) {
        // mode 2 is the user-facing 4:3 option, always force pure 4:3 and
        // ignore whatever the frame/core reports. otherwise widescreen-hack
        // frames or non-4:3 native modes would override the user's choice.
        (void)frameW;
        (void)frameH;
        return 4.0 / 3.0;
    }
    if (coreReported > 0.5f && coreReported < 4.0f)
        return (double)coreReported;
    if (baseW > 0 && baseH > 0) {
        const double fa = (double)baseW / (double)baseH;
        if (fa >= 1.1 && fa <= 2.5)
            return fa;
    }
    return 4.0 / 3.0;
}

@implementation SakuraPS1Core

+ (instancetype)shared
{
    static SakuraPS1Core *core = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        core = [[SakuraPS1Core alloc] init];
        g_sakuraPS1Core = core;
    });
    return core;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _running.store(false);
        _paused.store(false);
        for (int p = 0; p < 2; p++) {
            _leftX[p].store(0);
            _leftY[p].store(0);
            _rightX[p].store(0);
            _rightY[p].store(0);
            _physLeftX[p].store(0);
            _physLeftY[p].store(0);
            _physRightX[p].store(0);
            _physRightY[p].store(0);
        }
        _framesRendered.store(0);
        _metalDrawablePresentCount.store(0);
        _fps.store(0.0);
        _vps.store(0.0);
        _targetFPS.store(60.0);
        _hostEmulationSpeed.store(1.0);
        _aspectRatio.store(0);
        _integerScaling.store(false);
        _upscaleMultiplier.store(1.0f);
        _metalFXDisplay.store(false);
        _metalFXTemporalDisplayEnabled.store(false);
        _metalFXTexture.store(false);
        _metalFXFrameInterpolation.store(false);
        _gpuCpuDecouple.store(false);
        _videoToolboxIOS26FrameFeatures.store(true);
        _textureFilter.store(0);
        _autoSwitchControllerMode.store(true);
        for (int p = 0; p < 2; p++) {
            _sawAnalogPoll[p].store(false);
            _storedControllerMode[p].store((int)SakuraPS1ControllerModeDigital);
        }
        _retroPortDeviceDirty.store(false);
        _textureMetalFXResourcesDirty.store(false);
        _displayMetalFXResourcesDirty.store(false);
        _frameInterpResourcesDirty.store(false);
        _videoToolboxResourcesDirty.store(false);
        _previousFrameWidth = 0;
        _previousFrameHeight = 0;
        _baseWidth.store(0);
        _baseHeight.store(0);
        _coreAspectRatio.store(0.0f);
        _fastBoot.store(false);
        _variablesDirty.store(false);
        _audioSampleLimit = 44100 * 2 / 5; // 200ms
        _audioReadIndex = 0;
        _audioWriteIndex = 0;
        _audioSampleCount = 0;
        _audioLatencyMs.store(128);
        _audioSyncEnabled.store(true);
        _audioMuteWhenTurbo.store(true);
        _audioTimeStretchEnabled.store(true);
        _audioCoreSampleRate.store(44100.0);
        _audioStretchAcc = 0.0;
        _audioStretchPrevL = 0;
        _audioStretchPrevR = 0;
        _audioStretchCurrL = 0;
        _audioStretchCurrR = 0;
        _audioStretchPrimed = false;
        _audioQueue = nullptr;
        _audioBufferByteSize = 0;
        _pixelFormat = RETRO_PIXEL_FORMAT_XRGB8888;
        _textureWidth = 0;
        _textureHeight = 0;
        _mailboxCurr = nil;
        _mailboxW = 0;
        _mailboxH = 0;
        _mailboxFlushScheduled = false;
        _lastDisplayedCpuFrame = nil;
        _cadenceDupCurr = nil;
        _cadenceDupPrev = nil;
        _cadenceDupW = 0;
        _cadenceDupH = 0;
        _loadedLibraryISOEntry = nil;
        _saveThumbBGRA = nil;
        _saveThumbW = 0;
        _saveThumbH = 0;
        _presentationLibrary = nil;
        _metalPresentPipeline = nil;
        _smaa = nil;
        _smaaInputTex = nil;
        _smaaInputW = 0;
        _smaaInputH = 0;
        _smaaInputFmt = MTLPixelFormatInvalid;
        _smaaQuality = 0;
        _smaaLinearSpace = YES;
        _smaaAdaptiveThreshold = YES;
        _smaaPixelArtMode = YES;
        _smaaThresholdScale = 1.0f;
        _smaaPixelArtTolerance = 0.04f;
        _presColorAdjEnabled = false;
        _presColorSaturation = 1.f;
        _presBright = 0.f;
        _presContr = 1.f;
        _presVibr = 0.f;
        _presExpo = 0.f;
        _presGamma = 1.f;
        _presCT = 0.f;
        _presSharp = 0.f;
        _presBloom = 0.f;
        _presBloomRad = 3.f;
        _presVign = 0.f;
        _presVignRad = 1.f;
        _presHdrGrade = false;
        _presHdrDrawable = false;
        _presHdrExpo = 0.f;
        _presHdrSat = 1.f;
        _presHdrContr = 1.f;
        _presHdrBloom = 0.f;
        _presShadow = 0.f;
        _presHi = 0.f;
        _samplerNearest = nil;
        _samplerLinear = nil;
        _metalDrawablePipelineFormat = MTLPixelFormatInvalid;
#if SAKURA_HAS_METALFX
        _scalerColorFormat = MTLPixelFormatBGRA8Unorm;
        _metalFXFIWidth = 0;
        _metalFXFIHeight = 0;
        _metalFXFINeedHistoryReset = NO;
        _displayTemporalLastInW = 0;
        _displayTemporalLastInH = 0;
        _displayTemporalLastOutW = 0;
        _displayTemporalLastOutH = 0;
#endif
        for (int p = 0; p < 2; p++) {
            for (int i = 0; i < 16; i++) {
                _buttons[p][i].store(0);
                _physicalPadButtons[p][i].store(0);
            }
        }
        _sramLastHash = 0;
        _sramPathForLoadedGame = nil;
        _sramFlushTickCounter.store(0);

        // Flush memory cards on backgrounding / termination so users who
        // quickly Cmd-H or force-quit don't lose in-game saves. The run loop
        // also does periodic flushing, but these lifecycle hooks are the
        // last-mile guarantee.
        __weak SakuraPS1Core *weakSelf = self;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull) {
                        [weakSelf flushSaveRAMToDisk];
                    }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull) {
                        [weakSelf flushSaveRAMToDisk];
                    }];
    }
    return self;
}

static inline int SakuraClampPS1Port(int port) {
    return (port < 0 || port > 1) ? 0 : port;
}

- (SakuraPS1ControllerMode)controllerMode { return [self controllerModeForPort:0]; }
- (SakuraPS1ControllerMode)controllerModeForPort:(int)port {
    return (SakuraPS1ControllerMode)_storedControllerMode[SakuraClampPS1Port(port)].load(std::memory_order_relaxed);
}
- (int)aspectRatio { return _aspectRatio.load(); }
- (void)setAspectRatio:(int)ratio { _aspectRatio.store(ratio); }
- (BOOL)integerScaling { return _integerScaling.load(); }
- (void)setIntegerScaling:(BOOL)enabled { _integerScaling.store(enabled); }
- (float)upscaleMultiplier { return _upscaleMultiplier.load(); }
- (void)setUpscaleMultiplier:(float)scale
{
    float clamped = std::max(1.0f, std::min(16.0f, scale));
    _upscaleMultiplier.store(clamped);
}
- (BOOL)metalFXDisplay { return _metalFXDisplay.load(); }
- (void)setMetalFXDisplay:(BOOL)enabled
{
    const bool next = enabled ? true : false;
    const bool old = _metalFXDisplay.exchange(next);
    if (old == next) return;
#if SAKURA_HAS_METALFX
    _displayMetalFXResourcesDirty.store(true);
#endif
}
- (BOOL)metalFXTemporalDisplay { return _metalFXTemporalDisplayEnabled.load(); }
- (void)setMetalFXTemporalDisplay:(BOOL)enabled
{
    const bool next = enabled ? true : false;
    const bool old = _metalFXTemporalDisplayEnabled.exchange(next);
    if (old == next) return;
#if SAKURA_HAS_METALFX
    _displayMetalFXResourcesDirty.store(true);
#endif
}
- (BOOL)metalFXTexture { return _metalFXTexture.load(); }
- (void)setMetalFXTexture:(BOOL)enabled
{
    const bool next = enabled ? true : false;
    const bool old = _metalFXTexture.exchange(next);
    if (old == next) return;
#if SAKURA_HAS_METALFX
    _textureMetalFXResourcesDirty.store(true);
#endif
}
- (BOOL)metalFXFrameInterpolation { return _metalFXFrameInterpolation.load(); }
- (void)setMetalFXFrameInterpolation:(BOOL)enabled
{
    const bool next = enabled ? true : false;
    const bool old = _metalFXFrameInterpolation.exchange(next);
    if (old == next) return;
#if SAKURA_HAS_METALFX
    _frameInterpResourcesDirty.store(true);
#endif
    SakuraPS1Core *ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ws clearGpuPresentMailbox];
    });
}
- (BOOL)mainThreadMetalPresentEnabled
{
    return _gpuCpuDecouple.load() ? YES : NO;
}
- (void)setMainThreadMetalPresentEnabled:(BOOL)mainThreadMetalPresentEnabled
{
    const bool next = mainThreadMetalPresentEnabled ? true : false;
    const bool old = _gpuCpuDecouple.exchange(next);
    if (old == next) return;
    if (!next) [self clearGpuPresentMailbox];
}
- (BOOL)videoToolboxIOS26FrameFeatures { return _videoToolboxIOS26FrameFeatures.load(); }
- (void)setVideoToolboxIOS26FrameFeatures:(BOOL)enabled
{
    const bool next = enabled ? true : false;
    const bool old = _videoToolboxIOS26FrameFeatures.exchange(next);
    if (old == next) return;
#if SAKURA_HAS_METALFX
    _videoToolboxResourcesDirty.store(true);
#endif
}
- (int)textureFilter { return _textureFilter.load(); }
- (void)setTextureFilter:(int)mode
{
    int clamped = mode < 0 ? 0 : (mode > 7 ? 7 : mode);
    _textureFilter.store(clamped);
}
- (BOOL)fastBoot { return _fastBoot.load(); }
- (void)setFastBoot:(BOOL)enabled
{
    const bool prev = _fastBoot.exchange(enabled ? true : false);
    if (prev != (enabled ? true : false)) {
        _variablesDirty.store(true);
    }
}

- (double)hostEmulationSpeed
{
    return _hostEmulationSpeed.load();
}

- (void)setHostEmulationSpeed:(double)speed
{
    double s = speed;
    if (!(s > 0.0) || s != s)
        s = 1.0;
    s = std::max(0.25, std::min(8.0, s));
    _hostEmulationSpeed.store(s);
}

- (void)setLibretroVariable:(NSString *)key value:(NSString *)value
{
    if (key.length == 0) return;
    std::string k = key.UTF8String;
    std::string v = value ? value.UTF8String : "";
    std::lock_guard<std::mutex> lock(_varOverrideMutex);
    auto it = _varOverrides.find(k);
    if (it == _varOverrides.end() || it->second != v) {
        _varOverrides[k] = v;
        _variablesDirty.store(true);
    }
}

- (void)applyHostAudioSettingsLatencyMs:(NSInteger)latencyMs
                              audioSync:(BOOL)audioSync
                          muteWhenTurbo:(BOOL)muteWhenTurbo
                       audioTimeStretch:(BOOL)audioTimeStretch
{
    int32_t lat = (int32_t)latencyMs;
    if (lat < 0)
        lat = 0;
    if (lat > 512)
        lat = 512;

    const int32_t prevLat = _audioLatencyMs.load();
    const bool prevStretch = _audioTimeStretchEnabled.load();
    const bool nextSync = audioSync ? true : false;
    const bool nextMute = muteWhenTurbo ? true : false;
    const bool nextStretch = audioTimeStretch ? true : false;

    _audioLatencyMs.store(lat);
    _audioSyncEnabled.store(nextSync);
    _audioMuteWhenTurbo.store(nextMute);
    _audioTimeStretchEnabled.store(nextStretch);

    const bool latChanged = lat != prevLat;
    const bool stretchToggled = nextStretch != prevStretch;

    if (stretchToggled || latChanged) {
        std::lock_guard<std::mutex> lock(_audioMutex);
        _audioStretchAcc = 0.0;
        _audioStretchPrimed = false;
    }

    if (!latChanged)
        return;

    __weak SakuraPS1Core *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SakuraPS1Core *core = weakSelf;
        if (!core || !core->_running.load())
            return;
        const double sr = core->_audioCoreSampleRate.load();
        if (sr < 1.0)
            return;
        [core stopAudio];
        [core startAudioWithSampleRate:sr];
    });
}

- (void)setPresentationColorAdjustEnabled:(BOOL)enabled
                               saturation:(float)saturation
                               brightness:(float)brightness
                                 contrast:(float)contrast
                                 vibrance:(float)vibrance
                                 exposure:(float)exposure
                                    gamma:(float)gamma
                         colorTemperature:(float)colorTemperature
                                sharpness:(float)sharpness
                           bloomIntensity:(float)bloomIntensity
                              bloomRadius:(float)bloomRadius
                        vignetteIntensity:(float)vignetteIntensity
                           vignetteRadius:(float)vignetteRadius
                          hdrGradeEnabled:(BOOL)hdrGradeEnabled
                      hdrExtendedDrawable:(BOOL)hdrExtendedDrawable
                              hdrExposure:(float)hdrExposure
                            hdrSaturation:(float)hdrSaturation
                              hdrContrast:(float)hdrContrast
                                 hdrBloom:(float)hdrBloom
                               shadowLift:(float)shadowLift
                        highlightCompress:(float)highlightCompress
{
    std::lock_guard<std::mutex> lk(_presColorMutex);
    _presColorAdjEnabled = enabled ? true : false;
    _presColorSaturation = saturation;
    _presBright = brightness;
    _presContr = contrast;
    _presVibr = vibrance;
    _presExpo = exposure;
    _presGamma = gamma;
    _presCT = colorTemperature;
    _presSharp = sharpness;
    _presBloom = bloomIntensity;
    _presBloomRad = bloomRadius;
    _presVign = vignetteIntensity;
    _presVignRad = vignetteRadius;
    _presHdrGrade = hdrGradeEnabled ? true : false;
    _presHdrDrawable = hdrExtendedDrawable ? true : false;
    _presHdrExpo = hdrExposure;
    _presHdrSat = hdrSaturation;
    _presHdrContr = hdrContrast;
    _presHdrBloom = hdrBloom;
    _presShadow = shadowLift;
    _presHi = highlightCompress;
    if ([NSThread isMainThread]) {
        [self configureMetalLayerOnMainThread];
    } else {
        __weak SakuraPS1Core *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SakuraPS1Core *s = weakSelf;
            if (s) [s configureMetalLayerOnMainThread];
        });
    }
}

- (BOOL)autoSwitchControllerMode { return _autoSwitchControllerMode.load(); }
- (void)setAutoSwitchControllerMode:(BOOL)enabled
{
    const bool next = enabled ? true : false;
    const bool old = _autoSwitchControllerMode.exchange(next);
    if (old == next) return;
    for (int p = 0; p < 2; p++) _sawAnalogPoll[p].store(false);
    // touch both ports so retroApplyStoredPortUnsafe re-applies the device class
    // (Digital vs DualShock). modes themselves are unchanged.
    [self setControllerMode:[self controllerModeForPort:0] forPort:0];
    [self setControllerMode:[self controllerModeForPort:1] forPort:1];
}

- (void)setControllerMode:(SakuraPS1ControllerMode)mode { [self setControllerMode:mode forPort:0]; }
- (void)setControllerMode:(SakuraPS1ControllerMode)mode forPort:(int)port
{
    const int p = SakuraClampPS1Port(port);
    _storedControllerMode[p].store((int)mode, std::memory_order_relaxed);
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (!_running.load())
        return;
    _retroPortDeviceDirty.store(true, std::memory_order_release);
#endif
}

- (void)pressAnalogModeToggle { [self pressAnalogModeToggleForPort:0]; }
- (void)pressAnalogModeToggleForPort:(int)port
{
    const int p = SakuraClampPS1Port(port);
    const SakuraPS1ControllerMode cur = [self controllerModeForPort:p];
    SakuraPS1ControllerMode next = (cur == SakuraPS1ControllerModeDualShock)
        ? SakuraPS1ControllerModeDigital
        : SakuraPS1ControllerModeDualShock;
    [self setControllerMode:next forPort:p];
}
- (void)dealloc
{
    [self stop];
}

- (BOOL)available
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    return retro_api_version() == RETRO_API_VERSION;
#else
    return NO;
#endif
}

- (BOOL)running
{
    return _running.load() ? YES : NO;
}

- (BOOL)isPaused
{
    return _paused.load() ? YES : NO;
}

- (void)setPaused:(BOOL)paused
{
    _paused.store(paused ? true : false);
}

- (NSString *)coreName
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    struct retro_system_info info{};
    retro_get_system_info(&info);
    NSString *name = info.library_name ? [NSString stringWithUTF8String:info.library_name] : @"Beetle PSX";
    NSString *version = info.library_version ? [NSString stringWithUTF8String:info.library_version] : @"";
    return version.length > 0 ? [NSString stringWithFormat:@"%@ %@", name, version] : name;
#else
    return @"Beetle PSX / Mednafen PSX core not linked";
#endif
}

- (NSString *)lastError
{
    return _lastError;
}

- (void)setRenderView:(UIView *)view
{
    _renderView = view;
    if (!view) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_imageView removeFromSuperview];
            self->_imageView = nil;
            std::lock_guard<std::mutex> lock(self->_renderMutex);
            self->_metalLayer = nil;
            self->_frameTexture = nil;
            self->_previousFrameTexture = nil;
            self->_interpolatedFrameTexture = nil;
            self->_previousFrameWidth = 0;
            self->_previousFrameHeight = 0;
#if SAKURA_HAS_METALFX
            [self dropMetalFXLocked];
#endif
            self->_textureWidth = 0;
            self->_textureHeight = 0;
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self configureMetalLayerOnMainThread];
    });
}

- (void)notifyDisplayResizeWithWidth:(int)width height:(int)height scale:(float)scale
{
    (void)width;
    (void)height;
    (void)scale;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self configureMetalLayerOnMainThread];
    });
}

#if SAKURA_ENABLE_LIBRETRO_PSX
- (void)retroApplyStoredPortUnsafe
{
    const bool autoSwitch = _autoSwitchControllerMode.load();
    for (int p = 0; p < 2; p++) {
        const auto mode = (SakuraPS1ControllerMode)_storedControllerMode[p].load(std::memory_order_relaxed);
        // beetle expects RETRO_DEVICE_PS_DUALSHOCK, not bare RETRO_DEVICE_ANALOG.
        const unsigned device =
            (mode == SakuraPS1ControllerModeDualShock || autoSwitch)
                ? (unsigned)RETRO_DEVICE_PS_DUALSHOCK
                : (unsigned)RETRO_DEVICE_JOYPAD;
        retro_set_controller_port_device((unsigned)p, device);
    }
}
#endif

- (BOOL)bootGameAtPath:(NSString *)gamePath biosPath:(NSString *)biosPath error:(NSError **)error
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (![self available]) {
        return [self failWithMessage:@"The linked PS1 core does not expose a compatible libretro API." error:error];
    }
    if (gamePath.length == 0) {
        return [self failWithMessage:@"No PlayStation game was selected." error:error];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:gamePath]) {
        return [self failWithMessage:@"The selected game file no longer exists." error:error];
    }
    if (biosPath.length > 0 && ![[NSFileManager defaultManager] fileExistsAtPath:biosPath]) {
        return [self failWithMessage:@"The selected PlayStation BIOS file no longer exists." error:error];
    }

    // Serialize against concurrent boot/stop on the global dispatch queue.
    // Without this, two racing bootGameAtPath: calls both skip teardown (because
    // _running is still false on first entry), both call retro_init(), and the
    // second call reassigns _runThread while the first thread is still joinable,
    // which invokes std::terminate() → libc++abi: terminating. @synchronized is
    // recursive so nested [self stop] inside this method is safe.
    @synchronized (self) {
    [self stop];
    [self prepareDirectoriesWithBIOSPath:biosPath];
    if ([NSThread isMainThread]) {
        [self configureMetalLayerOnMainThread];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self configureMetalLayerOnMainThread];
        });
    }

    std::lock_guard<std::mutex> lock(_coreMutex);
    retro_set_environment(SakuraRetroEnvironment);
    retro_set_video_refresh(SakuraRetroVideoRefresh);
    retro_set_audio_sample(SakuraRetroAudioSample);
    retro_set_audio_sample_batch(SakuraRetroAudioSampleBatch);
    retro_set_input_poll(SakuraRetroInputPoll);
    retro_set_input_state(SakuraRetroInputState);
    retro_init();

    struct retro_game_info game{};
    game.path = gamePath.fileSystemRepresentation;
    if (!retro_load_game(&game)) {
        retro_deinit();
        return [self failWithMessage:@"The PS1 core could not load this game. Use a .cue/.bin, .chd, .pbp, .m3u, .iso, or .img backup and a valid PS1 BIOS." error:error];
    }

    struct retro_system_av_info av{};
    retro_get_system_av_info(&av);
    _baseWidth.store(av.geometry.base_width);
    _baseHeight.store(av.geometry.base_height);
    _coreAspectRatio.store((float)av.geometry.aspect_ratio);
    SakuraPostGeometryChanged();
    double sampleRate = av.timing.sample_rate > 1.0 ? av.timing.sample_rate : 44100.0;
    [self startAudioWithSampleRate:sampleRate];

    _loadedGamePath = [gamePath copy];
    NSString *boot = [SakuraBridge currentISOPath];
    _loadedLibraryISOEntry = boot.length > 0 ? [boot copy] : [gamePath.lastPathComponent copy];
    // Cache the .srm path for this boot so the run-loop / flush helpers
    // don't need to recompute a stem on every tick. Must be set before we
    // read the save-RAM back in so the core comes up with real memcard
    // contents instead of the default blank pair.
    {
        std::lock_guard<std::mutex> lk(_sramMutex);
        _sramPathForLoadedGame = [self saveRAMPathForCurrentGameUnsafe];
        _sramLastHash = 0;
    }
    // boot already holds _coreMutex. use the CoreLocked variant to avoid a
    // self-deadlock on the non-recursive std::mutex.
    (void)[self loadSaveRAMFromDiskCoreLocked];
    _lastError = nil;
    _paused.store(false);
    _running.store(true);
    _framesRendered.store(0);
    _metalDrawablePresentCount.store(0);
    _fps.store(0.0);
    _vps.store(0.0);

    {
        [self retroApplyStoredPortUnsafe];
    }
    for (int p = 0; p < 2; p++) _sawAnalogPoll[p].store(false);

    double fps = av.timing.fps > 1.0 ? av.timing.fps : 60.0;
    _targetFPS.store(fps);
    SakuraPS1Core *core = self;
    // Defensive: ensure the previous thread slot is not joinable before moving
    // a new thread into it. stop() above should have joined it, but if a prior
    // call was interrupted this avoids std::terminate on move-assign.
    if (_runThread.joinable()) {
        _running.store(false);
        _runThread.join();
        _running.store(true);
    }
    _runThread = std::thread([core, fps]() {
        [core runLoopWithTargetFPS:fps];
    });
    } // @synchronized (self)
    return YES;
#else
    (void)gamePath;
    (void)biosPath;
    return [self failWithMessage:@"Sakura is wired for PS1, but the Beetle/Mednafen PSX core is not linked into this build yet." error:error];
#endif
}

- (void)stop
{
    // @synchronized(self) is recursive; safe to acquire here even when called
    // from inside bootGameAtPath: which already holds it. Also called from
    // -dealloc, from SakuraBridge requestVMStop / requestVMShutdown, and from
    // dispatch queues, all of which can race without this guard.
    @synchronized (self) {
    const bool wasRunning = _running.exchange(false);
    if (_runThread.joinable()) {
        _runThread.join();
    }
    // Pending GPU presents run on main; flush before tearing Metal down.
    // dispatch_sync(main) deadlocks when stop() runs on the main thread.
    if ([NSThread isMainThread]) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{});
    }
    [self clearGpuPresentMailbox];
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (wasRunning) {
        // Flush memory-card SRAM BEFORE retro_unload_game(); after unload the
        // core releases its save-RAM buffer and retro_get_memory_data returns
        // NULL. Skipping this is what caused every in-game save to vanish
        // when the player quit back to the library.
        [self flushSaveRAMToDisk];
        std::lock_guard<std::mutex> lock(_coreMutex);
        retro_unload_game();
        retro_deinit();
    }
#else
    (void)wasRunning;
#endif
    {
        std::lock_guard<std::mutex> lk(_sramMutex);
        _sramPathForLoadedGame = nil;
        _sramLastHash = 0;
    }
    [self stopAudio];
    _paused.store(false);
    _fps.store(0.0);
    _vps.store(0.0);
    _framesRendered.store(0);
    _metalDrawablePresentCount.store(0);
    _baseWidth.store(0);
    _baseHeight.store(0);
    _coreAspectRatio.store(0.0f);
    _loadedLibraryISOEntry = nil;
    {
        std::lock_guard<std::mutex> lk(_saveThumbMutex);
        _saveThumbBGRA = nil;
        _saveThumbW = 0;
        _saveThumbH = 0;
    }
    {
        std::lock_guard<std::mutex> lock(_renderMutex);
#if SAKURA_HAS_METALFX
        [self dropMetalFXLocked];
#endif
    }
    _loadedGamePath = nil;
    for (int p = 0; p < 2; p++) {
        for (int i = 0; i < 16; i++) {
            _buttons[p][i].store(0);
            _physicalPadButtons[p][i].store(0);
        }
        _leftX[p].store(0);
        _leftY[p].store(0);
        _rightX[p].store(0);
        _rightY[p].store(0);
        _physLeftX[p].store(0);
        _physLeftY[p].store(0);
        _physRightX[p].store(0);
        _physRightY[p].store(0);
    }
    } // @synchronized (self)
}

- (void)setPadButton:(NSInteger)button pressed:(BOOL)pressed { [self setPadButton:button pressed:pressed port:0]; }
- (void)setPadButton:(NSInteger)button pressed:(BOOL)pressed port:(int)port
{
    const int p = SakuraClampPS1Port(port);
    const int retroID = SakuraRetroIDForSakuraButton(button);
    if (retroID >= 0 && retroID < 16) {
        _buttons[p][retroID].store(pressed ? 1 : 0);
    }
}

- (void)setLeftStickX:(float)x y:(float)y { [self setLeftStickX:x y:y port:0]; }
- (void)setLeftStickX:(float)x y:(float)y port:(int)port
{
    const int p = SakuraClampPS1Port(port);
    _leftX[p].store(SakuraAxisToRetro(x));
    _leftY[p].store(SakuraAxisToRetro(y));
}

- (void)setRightStickX:(float)x y:(float)y { [self setRightStickX:x y:y port:0]; }
- (void)setRightStickX:(float)x y:(float)y port:(int)port
{
    const int p = SakuraClampPS1Port(port);
    _rightX[p].store(SakuraAxisToRetro(x));
    _rightY[p].store(SakuraAxisToRetro(y));
}

- (void)setPhysicalPadButton:(NSInteger)button pressed:(BOOL)pressed { [self setPhysicalPadButton:button pressed:pressed port:0]; }
- (void)setPhysicalPadButton:(NSInteger)button pressed:(BOOL)pressed port:(int)port
{
    const int p = SakuraClampPS1Port(port);
    const int retroID = SakuraRetroIDForSakuraButton(button);
    if (retroID >= 0 && retroID < 16) {
        _physicalPadButtons[p][retroID].store(pressed ? 1 : 0);
    }
}

- (void)setPhysicalLeftStickX:(float)x y:(float)y { [self setPhysicalLeftStickX:x y:y port:0]; }
- (void)setPhysicalLeftStickX:(float)x y:(float)y port:(int)port
{
    const int p = SakuraClampPS1Port(port);
    _physLeftX[p].store(SakuraAxisToRetro(x));
    _physLeftY[p].store(SakuraAxisToRetro(y));
}

- (void)setPhysicalRightStickX:(float)x y:(float)y { [self setPhysicalRightStickX:x y:y port:0]; }
- (void)setPhysicalRightStickX:(float)x y:(float)y port:(int)port
{
    const int p = SakuraClampPS1Port(port);
    _physRightX[p].store(SakuraAxisToRetro(x));
    _physRightY[p].store(SakuraAxisToRetro(y));
}

- (NSString *)sakuraLibraryISOForSavePaths
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (_loadedLibraryISOEntry.length)
        return _loadedLibraryISOEntry;
    NSString *leaf = _loadedGamePath.lastPathComponent ?: @"";
    return leaf.length ? leaf : @"nogame";
#else
    NSString *leaf = _loadedGamePath.lastPathComponent ?: @"";
    return leaf.length ? leaf : @"nogame";
#endif
}

- (void)cacheLatestSaveThumbnailFromBGRA:(NSData *)pix width:(unsigned)width height:(unsigned)height
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (!pix.length || width == 0 || height == 0) return;
    const size_t need = (size_t)width * (size_t)height * 4u;
    if (pix.length < need) return;
    std::lock_guard<std::mutex> lk(_saveThumbMutex);
    _saveThumbBGRA = pix;
    _saveThumbW = width;
    _saveThumbH = height;
#else
    (void)pix;
    (void)width;
    (void)height;
#endif
}

- (NSData *)copyLatestSaveThumbnailWidth:(unsigned *)outW height:(unsigned *)outH
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    std::lock_guard<std::mutex> lk(_saveThumbMutex);
    if (!_saveThumbBGRA.length || !_saveThumbW || !_saveThumbH)
        return nil;
    if (outW) *outW = _saveThumbW;
    if (outH) *outH = _saveThumbH;
    return [_saveThumbBGRA copy];
#else
    (void)outW;
    (void)outH;
    return nil;
#endif
}

// ---------------------------------------------------------------------------
// Memory-card / SRAM persistence.
//
// Beetle-PSX exposes both memory cards as one contiguous block via
// `retro_get_memory_data(RETRO_MEMORY_SAVE_RAM)` / `retro_get_memory_size`.
// The frontend is responsible for reading this back into the core on game
// load and flushing it to disk periodically + on shutdown. Prior to this
// the app never touched the interface at all, which is why every in-game
// save evaporated on quit and every boot came up with blank cards.
// ---------------------------------------------------------------------------

- (NSString *)saveRAMPathForCurrentGameUnsafe
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    NSString *leaf = _loadedGamePath.lastPathComponent;
    if (!leaf.length) return nil;
    NSString *stem = leaf.stringByDeletingPathExtension;
    if (!stem.length) stem = leaf;
    if (_saveDirectory.empty()) return nil;
    NSString *dir = [NSString stringWithUTF8String:_saveDirectory.c_str()];
    if (!dir.length) return nil;
    return [[dir stringByAppendingPathComponent:stem] stringByAppendingPathExtension:@"srm"];
#else
    return nil;
#endif
}

#if SAKURA_ENABLE_LIBRETRO_PSX
static uint64_t SakuraPS1HashBytes(const void *data, size_t size)
{
    // FNV-1a is enough to detect SRAM changes since last flush. not
    // cryptographic, just needs to catch any write to the card.
    const uint8_t *p = static_cast<const uint8_t *>(data);
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < size; i++) {
        h ^= (uint64_t)p[i];
        h *= 1099511628211ull;
    }
    return h;
}
#endif

// Caller must already hold `_coreMutex`. Used by `bootGameAtPath:` which
// holds that mutex across the whole `retro_init` / `retro_load_game` block.
- (BOOL)loadSaveRAMFromDiskCoreLocked
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    NSString *path;
    {
        std::lock_guard<std::mutex> lk(_sramMutex);
        path = _sramPathForLoadedGame;
    }
    if (!path.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return NO;
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!file.length) return NO;

    void *buf = retro_get_memory_data((unsigned)RETRO_MEMORY_SAVE_RAM);
    size_t cap = retro_get_memory_size((unsigned)RETRO_MEMORY_SAVE_RAM);
    if (!buf || cap == 0) return NO;
    const size_t useLen = MIN((size_t)file.length, cap);
    memcpy(buf, file.bytes, useLen);
    if (useLen < cap) {
        memset(static_cast<uint8_t *>(buf) + useLen, 0, cap - useLen);
    }
    {
        std::lock_guard<std::mutex> lk(_sramMutex);
        _sramLastHash = SakuraPS1HashBytes(buf, cap);
    }
    return YES;
#else
    return NO;
#endif
}

- (BOOL)loadSaveRAMFromDisk
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    std::lock_guard<std::mutex> lock(_coreMutex);
    return [self loadSaveRAMFromDiskCoreLocked];
#else
    return NO;
#endif
}

- (BOOL)flushSaveRAMToDisk
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    NSString *path;
    {
        std::lock_guard<std::mutex> lk(_sramMutex);
        path = _sramPathForLoadedGame;
    }
    if (!path.length) return NO;

    std::vector<uint8_t> snapshot;
    uint64_t hash = 0;
    {
        std::lock_guard<std::mutex> lock(_coreMutex);
        void *buf = retro_get_memory_data((unsigned)RETRO_MEMORY_SAVE_RAM);
        size_t cap = retro_get_memory_size((unsigned)RETRO_MEMORY_SAVE_RAM);
        if (!buf || cap == 0) return NO;
        snapshot.resize(cap);
        memcpy(snapshot.data(), buf, cap);
        hash = SakuraPS1HashBytes(buf, cap);
    }

    // Skip the write when the card content hasn't changed since the last
    // successful flush. Saves on SSD wear during the 30-second periodic
    // tick when the user isn't touching cards.
    {
        std::lock_guard<std::mutex> lk(_sramMutex);
        if (hash == _sramLastHash && _sramLastHash != 0) {
            return YES;
        }
    }

    NSString *dir = path.stringByDeletingLastPathComponent;
    if (dir.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    const BOOL ok = SakuraWriteFileAtomic(path, snapshot.data(), snapshot.size()) ? YES : NO;
    if (ok) {
        std::lock_guard<std::mutex> lk(_sramMutex);
        _sramLastHash = hash;
    }
    return ok;
#else
    return NO;
#endif
}

- (BOOL)saveStateToSlot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (!_running.load()) return NO;
    if (slot < 1 || slot > 10) return NO;
    std::vector<uint8_t> data;
    {
        std::lock_guard<std::mutex> lock(_coreMutex);
        const size_t size = retro_serialize_size();
        if (size == 0) return NO;
        data.resize(size);
        if (!retro_serialize(data.data(), data.size())) return NO;
    }
    NSString *library = [self sakuraLibraryISOForSavePaths];
    NSString *canonState = SakuraPS1CanonicalSlotStatePath(library, slot);
    NSString *dirState = canonState.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:dirState withIntermediateDirectories:YES attributes:nil error:nil];
    const BOOL okState = SakuraWriteFileAtomic(canonState, data.data(), data.size());
    NSString *thumbPath = SakuraPS1PreviewPNGAdjacentToResolvedState(canonState);
    const BOOL capture =
        okState && [SakuraBridge getINIBool:@"Sakura/SaveStates" key:@"ScreenCapture" defaultValue:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (capture) {
        unsigned tw = 0;
        unsigned th = 0;
        NSData *pixels = [self copyLatestSaveThumbnailWidth:&tw height:&th];
        if (pixels.length >= (NSUInteger)tw * (NSUInteger)th * 4u && tw > 0 && th > 0) {
            // Synchronous encode. A 320x240 BGRA → PNG is single-digit ms on
            // modern iOS; the previous dispatch_async caused a race where the
            // UI bumped its refresh token before the file landed on disk, so
            // every slot tile fell back to the placeholder icon.
            (void)SakuraPS1WritePNGFromBGRAPremultiplied(pixels, tw, th, thumbPath);
        }
    } else if (thumbPath.length && [fm fileExistsAtPath:thumbPath]) {
        [fm removeItemAtPath:thumbPath error:nil];
    }
    // SRAM is a first-class save from the user's perspective. keep memory
    // cards in lockstep with save-state writes so a quick-save before quit
    // does not silently lose in-game progress.
    if (okState) {
        [self flushSaveRAMToDisk];
    }
    return okState ? YES : NO;
#else
    (void)slot;
    return NO;
#endif
}

- (BOOL)loadStateFromSlot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (!_running.load()) return NO;
    if (slot < 1 || slot > 10) return NO;
    NSString *path = SakuraPS1ResolveSlotStatePath([self sakuraLibraryISOForSavePaths], slot);
    NSData *state = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!state) return NO;
    std::lock_guard<std::mutex> lock(_coreMutex);
    return retro_unserialize(state.bytes, state.length) ? YES : NO;
#else
    (void)slot;
    return NO;
#endif
}

- (BOOL)hasSaveStateInSlot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    NSString *path = SakuraPS1ResolveSlotStatePath([self sakuraLibraryISOForSavePaths], slot);
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
#else
    (void)slot;
    return NO;
#endif
}

- (NSDate *)saveStateDateForSlot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    NSString *path = SakuraPS1ResolveSlotStatePath([self sakuraLibraryISOForSavePaths], slot);
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attrs[NSFileModificationDate];
#else
    (void)slot;
    return nil;
#endif
}

- (double)fps
{
    if (!_running.load() || _paused.load()) return 0.0;
    return _fps.load();
}
- (double)vps
{
    if (!_running.load() || _paused.load()) return 0.0;
    return _vps.load();
}

- (double)speed
{
    if (!_running.load() || _paused.load()) return 0.0;
    double target = _targetFPS.load();
    if (target <= 0.0) return 1.0;
    return _vps.load() / target;
}

- (uint64_t)framesRendered
{
    return _framesRendered.load();
}

- (uint64_t)metalLayerDrawablePresentCount
{
    return _metalDrawablePresentCount.load();
}

- (unsigned)presentPixelWidth
{
    return _textureWidth;
}

- (unsigned)presentPixelHeight
{
    return _textureHeight;
}

- (void)gpuCadencePump
{
    if (![NSThread isMainThread]) return;
    if (!_running.load() || _paused.load()) return;
    if (!_gpuCpuDecouple.load()) return;
    {
        std::lock_guard<std::mutex> lk(_mailboxMutex);
        if (_mailboxCurr) return;
    }
    NSData *curr = nil;
    unsigned w = 0;
    unsigned h = 0;
    {
        std::lock_guard<std::mutex> lk(_cadenceMutex);
        if (!_cadenceDupCurr.length || _cadenceDupW == 0 || _cadenceDupH == 0) return;
        curr = _cadenceDupCurr;
        w = _cadenceDupW;
        h = _cadenceDupH;
    }
    std::lock_guard<std::mutex> lk(_renderMutex);
    [self presentFramebufferGPUChainLockedPrevCPU:nil
                                         currCPU:curr
                                           width:w
                                          height:h
                                incrementRendered:NO];
}

- (id<MTLTexture>)sakuraNeuralUpscaleSourceIfEnabledLocked:(id<MTLTexture>)src prebuiltBGRA:(nullable NSData *)prebuiltBGRA volatilePackedBGRABase:(nullable const void *)volatilePackedBGRABase volatilePackedBGRALength:(NSUInteger)volatilePackedBGRALength
{
    if (!src || !_metalDevice || !_metalCommandQueue)
        return src;
    const unsigned cw = _baseWidth.load();
    const unsigned ch = _baseHeight.load();
    id<MTLTexture> out = [[SakuraNeuralUpscale shared] upscaleBGRATextureIfEnabled:src
                                                                   prebuiltBGRA:prebuiltBGRA
                                                     volatilePackedBGRABase:volatilePackedBGRABase
                                                   volatilePackedBGRALength:volatilePackedBGRALength
                                                                         device:_metalDevice
                                                                          queue:_metalCommandQueue
                                                                  coreBaseWidth:cw
                                                                 coreBaseHeight:ch];
    return out ?: src;
}

- (unsigned)baseWidth
{
    if (!_running.load()) return 0;
    return _baseWidth.load();
}

- (unsigned)baseHeight
{
    if (!_running.load()) return 0;
    return _baseHeight.load();
}

- (BOOL)failWithMessage:(NSString *)message error:(NSError **)error
{
    _lastError = [message copy];
    if (error) {
        *error = [NSError errorWithDomain:SakuraPS1ErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    NSLog(@"[SakuraPS1Core] %@", message);
    return NO;
}

- (void)prepareDirectoriesWithBIOSPath:(NSString *)biosPath
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *biosDir = [docs stringByAppendingPathComponent:@"bios"];
    NSString *saveDir = [docs stringByAppendingPathComponent:@"Saves/PS1"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:biosDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:saveDir withIntermediateDirectories:YES attributes:nil error:nil];
    _systemDirectory = biosDir.fileSystemRepresentation;
    _saveDirectory = saveDir.fileSystemRepresentation;

    NSDictionary<NSString *, NSString *> *shaMap = SakuraKnownPS1BIOSCanonicalMap();

    void (^classifyAndStage)(NSString *, NSString *) = ^(NSString *fullPath, NSString *leafName) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) return;
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        unsigned long long size = [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
        NSString *canonical = nil;
        if (SakuraFileLooksLikePS1BIOSCandidate(fullPath, leafName, size)) {
            NSString *shaHex = SakuraSHA1HexOfFileAtPath(fullPath);
            if (shaHex.length) canonical = shaMap[shaHex];
        }
        if (!canonical.length) canonical = SakuraCanonicalBIOSFromFilename(leafName);
        if (!canonical.length) return;
        if (SakuraTryInstallBIOS(fm, biosDir, canonical, fullPath)) {
            NSLog(@"[SakuraPS1Core] BIOS staged %@ -> %@", leafName, canonical);
        }
    };

    NSError *enumErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:biosDir error:&enumErr];
    if (entries) {
        for (NSString *name in entries) {
            if ([name hasPrefix:@"."]) continue;
            classifyAndStage([biosDir stringByAppendingPathComponent:name], name);
        }
    }

    if (biosPath.length > 0 && [fm fileExistsAtPath:biosPath]) {
        classifyAndStage(biosPath, biosPath.lastPathComponent);
        NSArray<NSString *> *slots = @[ @"scph5500.bin", @"scph5501.bin", @"scph5502.bin" ];
        for (NSString *slot in slots) {
            NSString *dst = [biosDir stringByAppendingPathComponent:slot];
            if ([fm fileExistsAtPath:dst]) continue;
            NSError *copyErr = nil;
            NSLog(@"[SakuraPS1Core] BIOS mirror fallback: filling missing %@ from picked image - wrong region may glitch until real BIOS imported",
                  slot);
            if (![fm copyItemAtPath:biosPath toPath:dst error:&copyErr]) {
                NSLog(@"[SakuraPS1Core] BIOS mirror failed %@ (%@)", slot, copyErr.localizedDescription);
            }
        }
    }
}

- (void)ensureImageViewOnMainQueue
{
    if ([NSThread isMainThread]) {
        [self ensureImageViewOnMainThread];
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self ensureImageViewOnMainThread];
    });
}

- (void)ensureImageViewOnMainThread
{
    UIView *view = _renderView;
    if (!view) return;
    if (_imageView.superview != view) {
        [_imageView removeFromSuperview];
        _imageView = [[UIImageView alloc] initWithFrame:view.bounds];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.backgroundColor = UIColor.blackColor;
        _imageView.layer.magnificationFilter = kCAFilterNearest;
        _imageView.layer.minificationFilter = kCAFilterNearest;
        [view addSubview:_imageView];
    }
    _imageView.frame = view.bounds;
}

- (void)configureMetalLayerOnMainThread
{
    UIView *view = _renderView;
    if (!view) return;

    [_imageView removeFromSuperview];
    _imageView = nil;

    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    if (![layer isKindOfClass:[CAMetalLayer class]]) {
        NSLog(@"[SakuraPS1Core] Render view is not backed by CAMetalLayer");
        return;
    }

    if (!_metalDevice) {
        _metalDevice = MTLCreateSystemDefaultDevice();
    }
    if (!_metalDevice) {
        NSLog(@"[SakuraPS1Core] Metal is not available on this device");
        return;
    }
    if (!_metalCommandQueue) {
        _metalCommandQueue = [_metalDevice newCommandQueue];
    }

    std::lock_guard<std::mutex> lock(_renderMutex);
    _metalLayer = layer;
    _metalLayer.device = _metalDevice;
    bool hdrOn = false;
    {
        std::lock_guard<std::mutex> lk(_presColorMutex);
        hdrOn = _presHdrDrawable;
    }
    MTLPixelFormat targetFmt = MTLPixelFormatBGRA8Unorm;
    if (@available(iOS 16.0, *)) {
        if (hdrOn) {
            targetFmt = MTLPixelFormatRGBA16Float;
            _metalLayer.wantsExtendedDynamicRangeContent = YES;
        } else {
            _metalLayer.wantsExtendedDynamicRangeContent = NO;
        }
    }
    if (_metalLayer.pixelFormat != targetFmt) {
        _metalPipeline = nil;
        _metalBlendPipeline = nil;
        _metalPresentPipeline = nil;
        _smaa = nil;
        _smaaInputTex = nil;
        _smaaInputW = 0;
        _smaaInputH = 0;
        _smaaInputFmt = MTLPixelFormatInvalid;
        _metalDrawablePipelineFormat = MTLPixelFormatInvalid;
    }
    _metalLayer.pixelFormat = targetFmt;
#if TARGET_OS_IPHONE
    _metalLayer.framebufferOnly = NO;
#else
    _metalLayer.framebufferOnly = YES;
#endif
    _metalLayer.opaque = YES;
    _metalLayer.backgroundColor = UIColor.blackColor.CGColor;
    _metalLayer.presentsWithTransaction = NO;
    _metalLayer.maximumDrawableCount = 3;
}

- (BOOL)ensureMetalPipelineLocked
{
    if (!_metalDevice) return NO;

    MTLPixelFormat passFmt = MTLPixelFormatBGRA8Unorm;
    if (_metalLayer && _metalLayer.pixelFormat != MTLPixelFormatInvalid)
        passFmt = _metalLayer.pixelFormat;
    if (_metalPipeline && _metalDrawablePipelineFormat != passFmt) {
        _metalPipeline = nil;
        _metalBlendPipeline = nil;
        _metalPresentPipeline = nil;
        _smaa = nil;
        _smaaInputTex = nil;
        _smaaInputW = 0;
        _smaaInputH = 0;
        _smaaInputFmt = MTLPixelFormatInvalid;
    }

    if (_metalPipeline && _metalBlendPipeline && _samplerNearest && _samplerLinear) {
        _metalDrawablePipelineFormat = passFmt;
        return YES;
    }

    static NSString * const shaderSource =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VSOut { float4 position [[position]]; float2 uv; };\n"
         "vertex VSOut vertex_main(uint vid [[vertex_id]]) {\n"
         "    float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
         "    float2 uv[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };\n"
         "    VSOut out;\n"
         "    out.position = float4(pos[vid], 0.0, 1.0);\n"
         "    out.uv = uv[vid];\n"
         "    return out;\n"
         "}\n"
         "fragment float4 fragment_main(VSOut in [[stage_in]], texture2d<float> frame [[texture(0)]], sampler smp [[sampler(0)]]) {\n"
         "    return frame.sample(smp, in.uv);\n"
         "}\n"
         "fragment float4 fragment_blend(VSOut in [[stage_in]],\n"
         "                               texture2d<float> prev [[texture(0)]],\n"
         "                               texture2d<float> curr [[texture(1)]],\n"
         "                               sampler smp [[sampler(0)]]) {\n"
         "    float4 a = prev.sample(smp, in.uv);\n"
         "    float4 b = curr.sample(smp, in.uv);\n"
         "    return mix(a, b, 0.5);\n"
         "}\n";

    NSError *error = nil;
    id<MTLLibrary> library = [_metalDevice newLibraryWithSource:shaderSource options:nil error:&error];
    if (!library) {
        NSLog(@"[SakuraPS1Core] Metal shader compile failed: %@", error.localizedDescription);
        return NO;
    }

    if (!_metalPipeline) {
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:@"vertex_main"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
        descriptor.colorAttachments[0].pixelFormat = passFmt;
        _metalPipeline = [_metalDevice newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!_metalPipeline) {
            NSLog(@"[SakuraPS1Core] Metal pipeline failed: %@", error.localizedDescription);
            return NO;
        }
    }

    if (!_metalBlendPipeline) {
        MTLRenderPipelineDescriptor *blendDesc = [[MTLRenderPipelineDescriptor alloc] init];
        blendDesc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
        blendDesc.fragmentFunction = [library newFunctionWithName:@"fragment_blend"];
        blendDesc.colorAttachments[0].pixelFormat = passFmt;
        _metalBlendPipeline = [_metalDevice newRenderPipelineStateWithDescriptor:blendDesc error:&error];
        if (!_metalBlendPipeline) {
            NSLog(@"[SakuraPS1Core] Metal blend pipeline failed: %@", error.localizedDescription);
            // Non-fatal: mid-frame blend falls back to no-op.
        }
    }

    if (!_samplerNearest) {
        MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];
        desc.minFilter = MTLSamplerMinMagFilterNearest;
        desc.magFilter = MTLSamplerMinMagFilterNearest;
        desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
        desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _samplerNearest = [_metalDevice newSamplerStateWithDescriptor:desc];
    }
    if (!_samplerLinear) {
        MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];
        desc.minFilter = MTLSamplerMinMagFilterLinear;
        desc.magFilter = MTLSamplerMinMagFilterLinear;
        desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
        desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _samplerLinear = [_metalDevice newSamplerStateWithDescriptor:desc];
    }

    if (!_metalPresentPipeline) {
        NSURL *libURL = [[NSBundle mainBundle] URLForResource:@"SakuraPresentation" withExtension:@"metallib"];
        if (libURL) {
            NSError *plErr = nil;
            id<MTLLibrary> plib = [_metalDevice newLibraryWithURL:libURL error:&plErr];
            if (plib) {
                id<MTLFunction> vtx = [plib newFunctionWithName:@"vertex_main"];
                id<MTLFunction> frg = [plib newFunctionWithName:@"fragment_pres"];
                if (vtx && frg) {
                    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
                    pd.vertexFunction = vtx;
                    pd.fragmentFunction = frg;
                    pd.colorAttachments[0].pixelFormat = passFmt;
                    id<MTLRenderPipelineState> pps = [_metalDevice newRenderPipelineStateWithDescriptor:pd error:&plErr];
                    if (pps) {
                        _presentationLibrary = plib;
                        _metalPresentPipeline = pps;
                    }
                }
            }
            if (!_metalPresentPipeline)
                NSLog(@"[SakuraPS1Core] present shader pipeline missing (%@)", plErr.localizedDescription ?: @"no library");
        }
    }

    // SMAA driver: rebuild if pass format changes (sRGB ↔ HDR drawable swap).
    if (_presentationLibrary && (!_smaa || _smaaInputFmt != passFmt)) {
        _smaa = [[SakuraSMAA alloc] initWithDevice:_metalDevice
                                            library:_presentationLibrary
                                       outputFormat:passFmt];
        _smaaInputFmt = passFmt;
        _smaaInputTex = nil;
        _smaaInputW = 0;
        _smaaInputH = 0;
        if (!_smaa.ready) {
            NSLog(@"[SakuraPS1Core] SMAA driver init failed (driver path will be skipped)");
            _smaa = nil;
        }
    }

    _metalDrawablePipelineFormat = passFmt;
    return _metalPipeline && _samplerNearest && _samplerLinear;
}

// Create/recreate the offscreen colour buffer that the existing present shader writes into when
// SMAA is active. SMAA's neighborhood blend pass then reads from this buffer + the weights buffer
// and writes the final pixels straight to the drawable.
- (BOOL)ensureSMAAInputTextureLocked:(NSUInteger)width
                              height:(NSUInteger)height
                              format:(MTLPixelFormat)fmt
{
    if (width == 0 || height == 0 || !_metalDevice) return NO;
    if (_smaaInputTex && _smaaInputW == width && _smaaInputH == height && _smaaInputFmt == fmt) return YES;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.pixelFormat = fmt;
    d.width = width;
    d.height = height;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    _smaaInputTex = [_metalDevice newTextureWithDescriptor:d];
    _smaaInputW = width;
    _smaaInputH = height;
    _smaaInputFmt = fmt;
    return _smaaInputTex != nil;
}

- (BOOL)renderTextureLocked:(id<MTLTexture>)source
                  toTexture:(id<MTLTexture>)target
              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   viewport:(MTLViewport)viewport
                      clear:(BOOL)clear
{
    if (!source || !target || !commandBuffer || ![self ensureMetalPipelineLocked]) return NO;

    if (_metalPresentPipeline) {
        const NSUInteger sw = source.width;
        const NSUInteger sh = source.height;
        if (sw < 1 || sh < 1) return NO;
        const double vpw = std::max(1.0, viewport.width);
        const double vph = std::max(1.0, viewport.height);

        bool adjEn = false;
        float sat = 1.f;
        float br = 0.f;
        float co = 1.f;
        float vi = 0.f;
        float ex = 0.f;
        float ga = 1.f;
        float ct = 0.f;
        float bl = 0.f;
        float blr = 3.f;
        float vg = 0.f;
        float vgr = 1.f;
        bool hdrGr = false;
        bool hdrDr = false;
        float hEx = 0.f;
        float hSat = 1.f;
        float hCo = 1.f;
        float hBl = 0.f;
        float shLift = 0.f;
        float hiComp = 0.f;
        float shrp = 0.f;
        {
            std::lock_guard<std::mutex> lk(_presColorMutex);
            adjEn = _presColorAdjEnabled;
            sat = _presColorSaturation;
            br = _presBright;
            co = _presContr;
            vi = _presVibr;
            ex = _presExpo;
            ga = _presGamma;
            ct = _presCT;
            shrp = _presSharp;
            bl = _presBloom;
            blr = _presBloomRad;
            vg = _presVign;
            vgr = _presVignRad;
            hdrGr = _presHdrGrade;
            hdrDr = _presHdrDrawable;
            hEx = _presHdrExpo;
            hSat = _presHdrSat;
            hCo = _presHdrContr;
            hBl = _presHdrBloom;
            shLift = _presShadow;
            hiComp = _presHi;
        }

        const bool gradeOn = adjEn;
        int tf = _textureFilter.load();
        if (tf < 0)
            tf = 0;
        if (tf > 7)
            tf = 7;
        const int casM = self.casMode;
        const float casSharp = (casM != 0) ? (std::max(0, std::min(100, self.casSharpness)) / 100.0f) * 0.85f : 0.f;

        SakuraPresentUBO ubo{};
        ubo.packed = simd_make_int4(tf, self.fxaa ? 1 : 0, casM != 0 ? 1 : 0, gradeOn ? 1 : 0);
        const float rcpSw = 1.f / (float)sw;
        const float rcpSh = 1.f / (float)sh;
        const float hdrBlend = (hdrGr && hdrDr) ? 1.f : 0.f;
        ubo.ts = simd_make_float4(rcpSw, rcpSh, casSharp, hdrBlend);
        SakuraEasuCon(&ubo.easuCon0, &ubo.easuCon1, &ubo.easuCon2, &ubo.easuCon3, (float)sw, (float)sh, (float)sw, (float)sh,
            (float)vpw, (float)vph);
        ubo.dims = simd_make_float4((float)vpw, (float)vph, 0.f, 0.f);
        ubo.uvRect = simd_make_float4(0.f, 0.f, 1.f, 1.f);
        ubo.color0 = simd_make_float4(sat, br, co, vi);
        ubo.color1 = simd_make_float4(ex, ga, ct, shrp);
        ubo.color2 = simd_make_float4(bl, blr, vg, vgr);
        ubo.hdr0 = simd_make_float4(hEx, hSat, hCo, hBl);
        ubo.hdr1 = simd_make_float4(shLift, hiComp, 0.f, 0.f);

        // Decide whether SMAA runs. Quality 0 = off, 1..4 active. SMAA is independent of FXAA;
        // when both are on, FXAA runs inside the present shader (cheap pre-pass) then SMAA cleans up.
        const int smaaQ = self.smaaQuality;
        const BOOL smaaActive = (smaaQ > 0) && _smaa.ready;
        id<MTLTexture> presentTarget = target;
        if (smaaActive) {
            // Run the existing present shader into the SMAA input texture sized to the drawable.
            // SMAA then writes the final result to `target`.
            const NSUInteger tw = target.width;
            const NSUInteger th = target.height;
            if ([self ensureSMAAInputTextureLocked:tw height:th format:_metalDrawablePipelineFormat]) {
                presentTarget = _smaaInputTex;
            }
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = presentTarget;
        pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) return NO;
        // The SMAA-input texture is drawable-sized, so when routing through SMAA we use a viewport
        // covering its full extent; otherwise honor the caller-supplied viewport (letterboxing etc.).
        if (presentTarget == _smaaInputTex) {
            MTLViewport vp;
            vp.originX = 0.0;
            vp.originY = 0.0;
            vp.width = (double)_smaaInputW;
            vp.height = (double)_smaaInputH;
            vp.znear = 0.0;
            vp.zfar = 1.0;
            [encoder setViewport:vp];
        } else {
            [encoder setViewport:viewport];
        }
        [encoder setRenderPipelineState:_metalPresentPipeline];
        [encoder setFragmentBytes:&ubo length:sizeof(ubo) atIndex:0];
        [encoder setFragmentTexture:source atIndex:0];
        if (_samplerNearest) [encoder setFragmentSamplerState:_samplerNearest atIndex:0];
        if (_samplerLinear) [encoder setFragmentSamplerState:_samplerLinear atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];

        if (smaaActive && presentTarget == _smaaInputTex) {
            SakuraSMAAQuality q = SakuraSMAAQualityHigh;
            switch (smaaQ) {
                case 1: q = SakuraSMAAQualityLow; break;
                case 2: q = SakuraSMAAQualityMedium; break;
                case 3: q = SakuraSMAAQualityHigh; break;
                case 4: q = SakuraSMAAQualityUltra; break;
                default: q = SakuraSMAAQualityHigh; break;
            }
            [_smaa applyToCommandBuffer:commandBuffer
                            sourceColor:_smaaInputTex
                          outputTexture:target
                         predicateTex:nil
                                quality:q
                            linearSpace:self.smaaLinearSpace
                      adaptiveThreshold:self.smaaAdaptiveThreshold
                          pixelArtMode:self.smaaPixelArtMode
                          thresholdScale:self.smaaThresholdScale
                      pixelArtTolerance:self.smaaPixelArtTolerance];
        }
        return YES;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return NO;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:_metalPipeline];
    [encoder setFragmentTexture:source atIndex:0];
    id<MTLSamplerState> sampler = (_textureFilter.load() == 0) ? _samplerNearest : _samplerLinear;
    if (sampler) [encoder setFragmentSamplerState:sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return YES;
}

- (BOOL)renderBlendLocked:(id<MTLTexture>)prevTexture
                  current:(id<MTLTexture>)currTexture
                toTexture:(id<MTLTexture>)target
            commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                 viewport:(MTLViewport)viewport
{
    if (!prevTexture || !currTexture || !target || !commandBuffer) return NO;
    if (![self ensureMetalPipelineLocked]) return NO;
    if (!_metalBlendPipeline) return NO;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return NO;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:_metalBlendPipeline];
    [encoder setFragmentTexture:prevTexture atIndex:0];
    [encoder setFragmentTexture:currTexture atIndex:1];
    id<MTLSamplerState> sampler = (_textureFilter.load() == 0) ? _samplerNearest : _samplerLinear;
    if (sampler) [encoder setFragmentSamplerState:sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return YES;
}

#if SAKURA_HAS_METALFX
- (void)dropTextureMetalFXLocked
{
    _textureScaler = nil;
    _textureScalerOut = nil;
    _textureScalerInWidth = 0;
    _textureScalerInHeight = 0;
    _textureScalerOutWidth = 0;
    _textureScalerOutHeight = 0;
}

- (void)dropDisplayMetalFXLocked
{
    _displayScaler = nil;
    _displayScalerIn = nil;
    _displayScalerOut = nil;
    _displayTemporalScaler = nil;
    _displayTemporalOut = nil;
    _displayTemporalDepth = nil;
    _displayTemporalMotion = nil;
    _displayTemporalExposure = nil;
    _displayTemporalLastInW = 0;
    _displayTemporalLastInH = 0;
    _displayTemporalLastOutW = 0;
    _displayTemporalLastOutH = 0;
    _displayScalerInWidth = 0;
    _displayScalerInHeight = 0;
    _displayScalerOutWidth = 0;
    _displayScalerOutHeight = 0;
}

- (void)dropMetalFXLocked
{
    [self dropTextureMetalFXLocked];
    [self dropDisplayMetalFXLocked];
    [self dropMetalFXFrameInterpolatorLocked];
}

- (void)synchronizeDeferredMetalFXResourceTearsLocked
{
#if SAKURA_HAS_METALFX
    if (_textureMetalFXResourcesDirty.exchange(false))
        [self dropTextureMetalFXLocked];
    if (_displayMetalFXResourcesDirty.exchange(false))
        [self dropDisplayMetalFXLocked];
    if (_frameInterpResourcesDirty.exchange(false)) {
        [self dropMetalFXFrameInterpolatorLocked];
        _previousFrameTexture = nil;
        _interpolatedFrameTexture = nil;
        _previousFrameWidth = 0;
        _previousFrameHeight = 0;
    }
    if (_videoToolboxResourcesDirty.exchange(false))
        [self dropMetalFXFrameInterpolatorLocked];
#endif
}

- (BOOL)writeSaveStateBytesToPath:(nonnull NSString *)path {
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (!_running.load()) return NO;
    std::vector<uint8_t> buf;
    {
        std::lock_guard<std::mutex> lock(_coreMutex);
        const size_t sz = retro_serialize_size();
        if (sz == 0) return NO;
        buf.resize(sz);
        if (!retro_serialize(buf.data(), sz)) return NO;
    }
    NSString *dir = path.stringByDeletingLastPathComponent;
    if (dir.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    return SakuraWriteFileAtomic(path, buf.data(), buf.size());
#else
    (void)path;
    return NO;
#endif
}

- (BOOL)loadSaveStateBytesFromPath:(nonnull NSString *)path {
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (!_running.load()) return NO;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length == 0) return NO;
    const size_t coreBlob = retro_serialize_size();
    if (coreBlob == 0) return NO;
    if (data.length < coreBlob) return NO;
    const size_t useLen = std::min((size_t)data.length, coreBlob);
    std::lock_guard<std::mutex> lock(_coreMutex);
    const BOOL ok = retro_unserialize(data.bytes, useLen) ? YES : NO;
    if (ok) {
        std::lock_guard<std::mutex> audioLock(_audioMutex);
        _audioStretchAcc = 0.0;
        _audioStretchPrimed = false;
        _audioSampleCount = 0;
        _audioReadIndex = 0;
        _audioWriteIndex = 0;
        if (!_audioRing.empty())
            memset(_audioRing.data(), 0, _audioRing.size() * sizeof(int16_t));
    }
    return ok;
#else
    (void)path;
    return NO;
#endif
}

- (void)dropMetalFXFrameInterpolatorLocked
{
    _metalFXFrameInterpolator = nil;
    _metalFXFIOutputTexture = nil;
    _metalFXFIDepthTexture = nil;
    _metalFXFIMotionTexture = nil;
    _metalFXFIWidth = 0;
    _metalFXFIHeight = 0;
    _metalFXFINeedHistoryReset = NO;
}

- (BOOL)ensureMetalFXFrameInterpolatorLocked:(NSUInteger)frameWidth frameHeight:(NSUInteger)frameHeight
{
    if (!frameWidth || !frameHeight || !_metalDevice) return NO;
    if (@available(iOS 26.0, *)) {
        if (![MTLFXFrameInterpolatorDescriptor supportsDevice:_metalDevice]) return NO;
        if (_metalFXFrameInterpolator && _metalFXFIWidth == frameWidth && _metalFXFIHeight == frameHeight && _metalFXFIOutputTexture && _metalFXFIDepthTexture && _metalFXFIMotionTexture)
            return YES;

        _metalFXFrameInterpolator = nil;
        _metalFXFIOutputTexture = nil;
        _metalFXFIDepthTexture = nil;
        _metalFXFIMotionTexture = nil;
        _metalFXFINeedHistoryReset = NO;

        MTLFXFrameInterpolatorDescriptor *desc = [[MTLFXFrameInterpolatorDescriptor alloc] init];
        desc.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.depthTextureFormat = MTLPixelFormatDepth32Float;
        desc.motionTextureFormat = MTLPixelFormatRG16Float;
        desc.inputWidth = frameWidth;
        desc.inputHeight = frameHeight;
        desc.outputWidth = frameWidth;
        desc.outputHeight = frameHeight;

        id fi = [desc newFrameInterpolatorWithDevice:_metalDevice];
        if (!fi) return NO;

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:frameWidth
                                                                                       height:frameHeight
                                                                                    mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead | [(id<MTLFXFrameInterpolator>)fi outputTextureUsage];
        id<MTLTexture> outTex = [_metalDevice newTextureWithDescriptor:td];
        if (!outTex) return NO;

        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                             width:frameWidth
                                                                                            height:frameHeight
                                                                                         mipmapped:NO];
        depthDesc.storageMode = MTLStorageModePrivate;
        depthDesc.usage = [(id<MTLFXFrameInterpolator>)fi depthTextureUsage] | MTLTextureUsageRenderTarget;
        id<MTLTexture> depthTex = [_metalDevice newTextureWithDescriptor:depthDesc];
        if (!depthTex) return NO;

        MTLTextureDescriptor *motDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                             width:frameWidth
                                                                                            height:frameHeight
                                                                                         mipmapped:NO];
        motDesc.storageMode = MTLStorageModePrivate;
        motDesc.usage = [(id<MTLFXFrameInterpolator>)fi motionTextureUsage] | MTLTextureUsageRenderTarget;
        id<MTLTexture> motTex = [_metalDevice newTextureWithDescriptor:motDesc];
        if (!motTex) return NO;

        _metalFXFrameInterpolator = fi;
        _metalFXFIOutputTexture = outTex;
        _metalFXFIDepthTexture = depthTex;
        _metalFXFIMotionTexture = motTex;
        _metalFXFIWidth = frameWidth;
        _metalFXFIHeight = frameHeight;
        _metalFXFINeedHistoryReset = YES;
        return YES;
    }
    return NO;
}

- (BOOL)presentMetalFXInterpolatedFrameLocked:(id<MTLTexture>)drawableTexture
                                     viewport:(MTLViewport)viewport
                           viewportPixelWidth:(NSUInteger)viewportPixelWidth
                          viewportPixelHeight:(NSUInteger)viewportPixelHeight
                                commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    if (!drawableTexture || !commandBuffer || !_frameTexture || !_previousFrameTexture || !_metalFXFIDepthTexture || !_metalFXFIMotionTexture)
        return NO;
    if (@available(iOS 26.0, *)) {
        if (![MTLFXFrameInterpolatorDescriptor supportsDevice:_metalDevice]) return NO;

        const NSUInteger tw = _frameTexture.width;
        const NSUInteger th = _frameTexture.height;
        if (tw == 0 || th == 0 || _previousFrameTexture.width != tw || _previousFrameTexture.height != th)
            return NO;
        if (![self ensureMetalFXFrameInterpolatorLocked:tw frameHeight:th] || !_metalFXFIOutputTexture || !_metalFXFrameInterpolator || !_metalFXFIDepthTexture
            || !_metalFXFIMotionTexture)
            return NO;

        if (![self clearDepth32TextureLocked:_metalFXFIDepthTexture commandBuffer:commandBuffer clearDepth:1.0])
            return NO;
        if (![self clearRG16MotionTextureLocked:_metalFXFIMotionTexture commandBuffer:commandBuffer])
            return NO;

        id<MTLFXFrameInterpolator> fi = _metalFXFrameInterpolator;
        fi.colorTexture = _frameTexture;
        fi.prevColorTexture = _previousFrameTexture;
        fi.depthTexture = _metalFXFIDepthTexture;
        fi.motionTexture = _metalFXFIMotionTexture;
        fi.uiTexture = nil;
        fi.outputTexture = _metalFXFIOutputTexture;
        const double fps = std::max(1.0, _targetFPS.load());
        fi.deltaTime = (float)(1.0 / fps);
        fi.shouldResetHistory = _metalFXFINeedHistoryReset ? YES : NO;
        _metalFXFINeedHistoryReset = NO;
        fi.jitterOffsetX = 0.f;
        fi.jitterOffsetY = 0.f;
        fi.motionVectorScaleX = (float)tw;
        fi.motionVectorScaleY = (float)th;
        fi.fieldOfView = 60.f;
        fi.aspectRatio = (float)tw / (float)std::max((NSUInteger)1, th);
        fi.nearPlane = 0.1f;
        fi.farPlane = 100.f;
        fi.depthReversed = NO;
        fi.uiTextureComposited = NO;
        [fi encodeToCommandBuffer:commandBuffer];

        id<MTLTexture> drawSrc = _metalFXFIOutputTexture;
        drawSrc = [self sakuraNeuralUpscaleSourceIfEnabledLocked:drawSrc prebuiltBGRA:nil volatilePackedBGRABase:NULL volatilePackedBGRALength:0];

#if SAKURA_HAS_METALFX
        drawSrc = [self displayMetalFXSourceLocked:drawSrc
                                     commandBuffer:commandBuffer
                                       outputWidth:viewportPixelWidth
                                      outputHeight:viewportPixelHeight];
#endif

        return [self renderTextureLocked:drawSrc toTexture:drawableTexture commandBuffer:commandBuffer viewport:viewport clear:YES];
    }
    return NO;
}

- (id<MTLTexture>)textureMetalFXSourceLocked:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    if (!_metalFXTexture.load() || !source || !commandBuffer || !_metalDevice) return source;
    if (@available(iOS 16.0, *)) {
        if (![MTLFXSpatialScalerDescriptor supportsDevice:_metalDevice]) return source;

        const NSUInteger inW = source.width;
        const NSUInteger inH = source.height;
        // Internal-res upscale from emulator resolution (MetalFX Texture toggle only).
        const float scale = std::max(1.0f, std::min(5.0f, _upscaleMultiplier.load()));
        NSUInteger outW = (NSUInteger)std::round((double)inW * (double)scale);
        NSUInteger outH = (NSUInteger)std::round((double)inH * (double)scale);
        outW = MAX((NSUInteger)1, outW);
        outH = MAX((NSUInteger)1, outH);
        if (outW <= inW && outH <= inH) return source;

        const BOOL needsScaler = !_textureScaler ||
            _textureScalerInWidth != inW ||
            _textureScalerInHeight != inH ||
            _textureScalerOutWidth != outW ||
            _textureScalerOutHeight != outH;
        if (needsScaler) {
            [self dropTextureMetalFXLocked];
            MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
            descriptor.colorTextureFormat = _scalerColorFormat;
            descriptor.outputTextureFormat = _scalerColorFormat;
            descriptor.inputWidth = inW;
            descriptor.inputHeight = inH;
            descriptor.outputWidth = outW;
            descriptor.outputHeight = outH;
            descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
            _textureScaler = [descriptor newSpatialScalerWithDevice:_metalDevice];
            if (!_textureScaler) return source;

            MTLTextureDescriptor *outDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_scalerColorFormat
                                                                                               width:outW
                                                                                              height:outH
                                                                                           mipmapped:NO];
            outDesc.storageMode = MTLStorageModePrivate;
            outDesc.usage = MTLTextureUsageShaderRead | _textureScaler.outputTextureUsage;
            _textureScalerOut = [_metalDevice newTextureWithDescriptor:outDesc];
            if (!_textureScalerOut) {
                [self dropTextureMetalFXLocked];
                return source;
            }

            _textureScalerInWidth = inW;
            _textureScalerInHeight = inH;
            _textureScalerOutWidth = outW;
            _textureScalerOutHeight = outH;
        }

        _textureScaler.colorTexture = source;
        _textureScaler.inputContentWidth = inW;
        _textureScaler.inputContentHeight = inH;
        _textureScaler.outputTexture = _textureScalerOut;
        [_textureScaler encodeToCommandBuffer:commandBuffer];
        return _textureScalerOut ?: source;
    }
    return source;
}

- (BOOL)clearDepth32TextureLocked:(id<MTLTexture>)depthTexture commandBuffer:(id<MTLCommandBuffer>)commandBuffer clearDepth:(double)clearDepth
{
    if (!depthTexture || !commandBuffer) return NO;
    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.depthAttachment.texture = depthTexture;
    pd.depthAttachment.loadAction = MTLLoadActionClear;
    pd.depthAttachment.storeAction = MTLStoreActionStore;
    pd.depthAttachment.clearDepth = clearDepth;
    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pd];
    if (!enc) return NO;
    [enc endEncoding];
    return YES;
}

- (BOOL)clearRG16MotionTextureLocked:(id<MTLTexture>)motionTexture commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    if (!motionTexture || !commandBuffer) return NO;
    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = motionTexture;
    pd.colorAttachments[0].loadAction = MTLLoadActionClear;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    pd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pd];
    if (!enc) return NO;
    [enc endEncoding];
    return YES;
}

- (id<MTLTexture>)displayMetalFXSourceLocked:(id<MTLTexture>)source
                                commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                  outputWidth:(NSUInteger)outputWidth
                                 outputHeight:(NSUInteger)outputHeight
{
    const BOOL wantMetalFxPresentation = _metalFXDisplay.load() || _metalFXTemporalDisplayEnabled.load();
    if (!wantMetalFxPresentation || !source || !commandBuffer || !_metalDevice || outputWidth == 0 || outputHeight == 0)
        return source;
    if (@available(iOS 16.0, *)) {
        const double outAspect = std::max(0.01, (double)outputWidth / (double)outputHeight);
        double inW = (double)source.width;
        double inH = inW / outAspect;
        if (inH > (double)source.height) {
            inH = (double)source.height;
            inW = inH * outAspect;
        }
        if (inW > (double)outputWidth || inH > (double)outputHeight) {
            const double shrink = std::min((double)outputWidth / inW, (double)outputHeight / inH);
            inW *= shrink;
            inH *= shrink;
        }

        const NSUInteger inputW = MAX((NSUInteger)1, (NSUInteger)std::floor(inW));
        const NSUInteger inputH = MAX((NSUInteger)1, (NSUInteger)std::floor(inH));
        if (outputWidth <= inputW && outputHeight <= inputH)
            return source;

        if (!_displayScalerIn || _displayScalerInWidth != inputW || _displayScalerInHeight != inputH) {
            _displayScalerIn = nil;
            MTLTextureDescriptor *inDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_scalerColorFormat
                                                                                              width:inputW
                                                                                             height:inputH
                                                                                          mipmapped:NO];
            inDesc.storageMode = MTLStorageModePrivate;
            inDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            _displayScalerIn = [_metalDevice newTextureWithDescriptor:inDesc];
            _displayScalerInWidth = _displayScalerIn ? inputW : 0;
            _displayScalerInHeight = _displayScalerIn ? inputH : 0;
            if (!_displayScalerIn)
                return source;
        }

        MTLViewport inputViewport = {0.0, 0.0, (double)inputW, (double)inputH, 0.0, 1.0};
        if (![self renderTextureLocked:source toTexture:_displayScalerIn commandBuffer:commandBuffer viewport:inputViewport clear:YES])
            return source;

        const BOOL wantTemporal = _metalFXTemporalDisplayEnabled.load();
        if (wantTemporal && [MTLFXTemporalScalerDescriptor supportsDevice:_metalDevice]) {
            const BOOL needNewTemporal = !_displayTemporalScaler || _displayTemporalLastInW != inputW || _displayTemporalLastInH != inputH
                || _displayTemporalLastOutW != outputWidth || _displayTemporalLastOutH != outputHeight;

            if (needNewTemporal) {
                _displayTemporalScaler = nil;
                _displayTemporalOut = nil;
                _displayTemporalDepth = nil;
                _displayTemporalMotion = nil;
                _displayTemporalExposure = nil;

                MTLFXTemporalScalerDescriptor *tdesc = [[MTLFXTemporalScalerDescriptor alloc] init];
                tdesc.colorTextureFormat = _scalerColorFormat;
                tdesc.depthTextureFormat = MTLPixelFormatDepth32Float;
                tdesc.motionTextureFormat = MTLPixelFormatRG16Float;
                tdesc.outputTextureFormat = _scalerColorFormat;
                tdesc.inputWidth = inputW;
                tdesc.inputHeight = inputH;
                tdesc.outputWidth = outputWidth;
                tdesc.outputHeight = outputHeight;
                tdesc.autoExposureEnabled = NO;

                id<MTLFXTemporalScaler> ts = [tdesc newTemporalScalerWithDevice:_metalDevice];
                if (!ts) {
                    static std::atomic<int> s_temporalCreateLogged{0};
                    if (s_temporalCreateLogged.fetch_add(1) == 0)
                        SakuraLogUnified(@"Present", @"Warning",
                            @"MetalFX temporal display scaler could not be created for this device or resolution. falling back to spatial scaler if available.");
                } else {
                    _displayTemporalScaler = ts;

                    MTLTextureDescriptor *outDesc =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_scalerColorFormat
                                                                             width:outputWidth
                                                                            height:outputHeight
                                                                         mipmapped:NO];
                    outDesc.storageMode = MTLStorageModePrivate;
                    outDesc.usage = MTLTextureUsageShaderRead | ts.outputTextureUsage;
                    _displayTemporalOut = [_metalDevice newTextureWithDescriptor:outDesc];

                    MTLTextureDescriptor *depthDesc =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                             width:inputW
                                                                            height:inputH
                                                                         mipmapped:NO];
                    depthDesc.storageMode = MTLStorageModePrivate;
                    depthDesc.usage = ts.depthTextureUsage | MTLTextureUsageRenderTarget;
                    _displayTemporalDepth = [_metalDevice newTextureWithDescriptor:depthDesc];

                    MTLTextureDescriptor *motionDesc =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                             width:inputW
                                                                            height:inputH
                                                                         mipmapped:NO];
                    motionDesc.storageMode = MTLStorageModePrivate;
                    motionDesc.usage = ts.motionTextureUsage | MTLTextureUsageRenderTarget;
                    _displayTemporalMotion = [_metalDevice newTextureWithDescriptor:motionDesc];

                    MTLTextureDescriptor *expDesc =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                                                             width:1
                                                                            height:1
                                                                         mipmapped:NO];
                    expDesc.storageMode = MTLStorageModeShared;
                    expDesc.usage = MTLTextureUsageShaderRead;
                    _displayTemporalExposure = [_metalDevice newTextureWithDescriptor:expDesc];
                    if (_displayTemporalExposure) {
                        static const uint16_t kR16FOneBits = 0x3c00;
                        [_displayTemporalExposure replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                                                    mipmapLevel:0
                                                      withBytes:&kR16FOneBits
                                                    bytesPerRow:2];
                    }

                    if (!_displayTemporalOut || !_displayTemporalDepth || !_displayTemporalMotion || !_displayTemporalExposure) {
                        _displayTemporalScaler = nil;
                        _displayTemporalOut = nil;
                        _displayTemporalDepth = nil;
                        _displayTemporalMotion = nil;
                        _displayTemporalExposure = nil;
                    } else {
                        _displayTemporalLastInW = inputW;
                        _displayTemporalLastInH = inputH;
                        _displayTemporalLastOutW = outputWidth;
                        _displayTemporalLastOutH = outputHeight;
                    }
                }
            }

            if (_displayTemporalScaler && _displayTemporalOut && _displayTemporalDepth && _displayTemporalMotion && _displayTemporalExposure
                && [self clearDepth32TextureLocked:_displayTemporalDepth commandBuffer:commandBuffer clearDepth:1.0]
                && [self clearRG16MotionTextureLocked:_displayTemporalMotion commandBuffer:commandBuffer]) {
                id<MTLFXTemporalScaler> ts = _displayTemporalScaler;
                ts.colorTexture = _displayScalerIn;
                ts.depthTexture = _displayTemporalDepth;
                ts.motionTexture = _displayTemporalMotion;
                ts.outputTexture = _displayTemporalOut;
                ts.inputContentWidth = inputW;
                ts.inputContentHeight = inputH;
                ts.exposureTexture = _displayTemporalExposure;
                ts.reactiveMaskTexture = nil;
                ts.preExposure = 1.f;
                ts.jitterOffsetX = 0.f;
                ts.jitterOffsetY = 0.f;
                ts.motionVectorScaleX = (float)inputW;
                ts.motionVectorScaleY = (float)inputH;
                ts.reset = needNewTemporal ? YES : NO;
                ts.depthReversed = NO;
                ts.fence = nil;
                [ts encodeToCommandBuffer:commandBuffer];
                return _displayTemporalOut ?: source;
            }
        }

        if (![MTLFXSpatialScalerDescriptor supportsDevice:_metalDevice])
            return source;

        const BOOL needsScaler = !_displayScaler || _displayScalerInWidth != inputW || _displayScalerInHeight != inputH
            || _displayScalerOutWidth != outputWidth || _displayScalerOutHeight != outputHeight;
        if (needsScaler) {
            _displayScaler = nil;
            _displayScalerOut = nil;

            MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
            descriptor.colorTextureFormat = _scalerColorFormat;
            descriptor.outputTextureFormat = _scalerColorFormat;
            descriptor.inputWidth = inputW;
            descriptor.inputHeight = inputH;
            descriptor.outputWidth = outputWidth;
            descriptor.outputHeight = outputHeight;
            descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
            _displayScaler = [descriptor newSpatialScalerWithDevice:_metalDevice];
            if (!_displayScaler)
                return source;

            MTLTextureDescriptor *outDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_scalerColorFormat
                                                                                                 width:outputWidth
                                                                                                height:outputHeight
                                                                                             mipmapped:NO];
            outDesc.storageMode = MTLStorageModePrivate;
            outDesc.usage = MTLTextureUsageShaderRead | _displayScaler.outputTextureUsage;
            _displayScalerOut = [_metalDevice newTextureWithDescriptor:outDesc];
            if (!_displayScalerOut) {
                [self dropDisplayMetalFXLocked];
                return source;
            }

            _displayScalerOutWidth = outputWidth;
            _displayScalerOutHeight = outputHeight;
        }

        _displayScaler.colorTexture = _displayScalerIn;
        _displayScaler.inputContentWidth = inputW;
        _displayScaler.inputContentHeight = inputH;
        _displayScaler.outputTexture = _displayScalerOut;
        [_displayScaler encodeToCommandBuffer:commandBuffer];
        return _displayScalerOut ?: source;
    }
    return source;
}
#endif

- (NSData *)copyBGRATightFrame:(const void *)data pitch:(size_t)pitch width:(unsigned)width height:(unsigned)height
{
    if (!data || width == 0 || height == 0) return nil;
    const size_t tightPitch = (size_t)width * 4;
    NSMutableData *out = [NSMutableData dataWithLength:tightPitch * (size_t)height];
    uint8_t *dstRows = static_cast<uint8_t *>(out.mutableBytes);
    const uint8_t *srcRows = static_cast<const uint8_t *>(data);

    if (_pixelFormat == RETRO_PIXEL_FORMAT_RGB565 || _pixelFormat == RETRO_PIXEL_FORMAT_0RGB1555 || pitch != tightPitch) {
        if (_pixelFormat == RETRO_PIXEL_FORMAT_RGB565) {
            for (unsigned y = 0; y < height; y++) {
                const uint16_t *src = reinterpret_cast<const uint16_t *>(srcRows + y * pitch);
                uint8_t *dst = dstRows + (size_t)y * tightPitch;
                for (unsigned x = 0; x < width; x++) {
                    const uint16_t p = src[x];
                    dst[x * 4 + 0] = (uint8_t)((p & 0x1f) * 255 / 31);
                    dst[x * 4 + 1] = (uint8_t)(((p >> 5) & 0x3f) * 255 / 63);
                    dst[x * 4 + 2] = (uint8_t)(((p >> 11) & 0x1f) * 255 / 31);
                    dst[x * 4 + 3] = 0xff;
                }
            }
        } else if (_pixelFormat == RETRO_PIXEL_FORMAT_0RGB1555) {
            for (unsigned y = 0; y < height; y++) {
                const uint16_t *src = reinterpret_cast<const uint16_t *>(srcRows + y * pitch);
                uint8_t *dst = dstRows + (size_t)y * tightPitch;
                for (unsigned x = 0; x < width; x++) {
                    const uint16_t p = src[x];
                    dst[x * 4 + 0] = (uint8_t)((p & 0x1f) * 255 / 31);
                    dst[x * 4 + 1] = (uint8_t)(((p >> 5) & 0x1f) * 255 / 31);
                    dst[x * 4 + 2] = (uint8_t)(((p >> 10) & 0x1f) * 255 / 31);
                    dst[x * 4 + 3] = 0xff;
                }
            }
        } else {
            for (unsigned y = 0; y < height; y++) {
                memcpy(dstRows + (size_t)y * tightPitch, srcRows + (size_t)y * pitch, tightPitch);
            }
        }
    } else {
        memcpy(dstRows, srcRows, tightPitch * (size_t)height);
    }
    return out;
}

- (void)clearGpuPresentMailbox
{
    {
        std::lock_guard<std::mutex> lk(_mailboxMutex);
        _mailboxCurr = nil;
        _mailboxFlushScheduled = false;
        _lastDisplayedCpuFrame = nil;
    }
    {
        std::lock_guard<std::mutex> lk(_cadenceMutex);
        _cadenceDupCurr = nil;
        _cadenceDupPrev = nil;
        _cadenceDupW = 0;
        _cadenceDupH = 0;
    }
    {
        std::lock_guard<std::mutex> lk(_saveThumbMutex);
        _saveThumbBGRA = nil;
        _saveThumbW = 0;
        _saveThumbH = 0;
    }
}

- (void)enqueueMailboxGpuPresentCurrCPU:(NSData *)curr width:(unsigned)width height:(unsigned)height
{
    if (!curr.length || width == 0 || height == 0) return;
    BOOL kick = NO;
    {
        std::lock_guard<std::mutex> lk(_mailboxMutex);
        _mailboxCurr = curr;
        _mailboxW = width;
        _mailboxH = height;
        if (!_mailboxFlushScheduled) {
            _mailboxFlushScheduled = true;
            kick = YES;
        }
    }
    if (kick) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self flushMailboxGpuPresentsOnMain];
        });
    }
}

- (void)flushMailboxGpuPresentsOnMain
{
    NSData *curr = nil;
    unsigned width = 0;
    unsigned height = 0;
    {
        std::lock_guard<std::mutex> lk(_mailboxMutex);
        if (!_mailboxCurr) {
            _mailboxFlushScheduled = false;
            return;
        }
        curr = _mailboxCurr;
        _mailboxCurr = nil;
        width = _mailboxW;
        height = _mailboxH;
    }

    NSData *prevSnap = nil;
    if (_metalFXFrameInterpolation.load())
        prevSnap = _lastDisplayedCpuFrame;

    BOOL presented = NO;
    {
        std::lock_guard<std::mutex> lk(_renderMutex);
        if (_metalLayer && _metalCommandQueue && [self ensureMetalPipelineLocked]) {
            [self presentFramebufferGPUChainLockedPrevCPU:prevSnap
                                                  currCPU:curr
                                                    width:width
                                                   height:height
                                        incrementRendered:YES];
            presented = YES;
        }
    }
    if (!presented) {
        std::lock_guard<std::mutex> mb(_mailboxMutex);
        _mailboxFlushScheduled = false;
        return;
    }

    if (_metalFXFrameInterpolation.load())
        _lastDisplayedCpuFrame = curr;

    BOOL more = NO;
    {
        std::lock_guard<std::mutex> mb(_mailboxMutex);
        more = (_mailboxCurr != nil);
        if (!more)
            _mailboxFlushScheduled = false;
    }
    if (more) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self flushMailboxGpuPresentsOnMain];
        });
    }
}

- (void)presentFramebufferGPUChainLockedPrevCPU:(NSData *)prev currCPU:(NSData *)curr width:(unsigned)width height:(unsigned)height incrementRendered:(BOOL)incrementRendered
{
    if (!curr.length || !_metalLayer || !_metalCommandQueue || ![self ensureMetalPipelineLocked]) return;
#if SAKURA_HAS_METALFX
    [self synchronizeDeferredMetalFXResourceTearsLocked];
#endif
    UIView *rv = _renderView;
    if (!rv.window) return;

    CGSize laySize = _metalLayer.drawableSize;
    if (laySize.width < 1.0 || laySize.height < 1.0) return;

    const size_t expectedLen = (size_t)width * (size_t)height * 4;
    if (curr.length != expectedLen) return;

    if (!_frameTexture || _textureWidth != width || _textureHeight != height) {
#if SAKURA_HAS_METALFX
        [self dropMetalFXFrameInterpolatorLocked];
#endif
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        _frameTexture = [_metalDevice newTextureWithDescriptor:descriptor];
        _textureWidth = width;
        _textureHeight = height;
    }
    if (!_frameTexture) return;

    const BOOL doInterp = _metalFXFrameInterpolation.load();
    const size_t tightPitch = (size_t)width * 4;
    BOOL havePrev = NO;

    if (doInterp && prev.length == expectedLen && _metalDevice) {
        if (!_previousFrameTexture || _previousFrameWidth != width || _previousFrameHeight != height) {
            MTLTextureDescriptor *pd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
            pd.usage = MTLTextureUsageShaderRead;
            pd.storageMode = MTLStorageModeShared;
            _previousFrameTexture = [_metalDevice newTextureWithDescriptor:pd];
            _previousFrameWidth = width;
            _previousFrameHeight = height;
        }
        if (_previousFrameTexture) {
            [ _previousFrameTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                                       mipmapLevel:0
                                         withBytes:prev.bytes
                                       bytesPerRow:tightPitch];
            havePrev = YES;
        }
    } else if (!doInterp && _previousFrameTexture) {
        _previousFrameTexture = nil;
        _previousFrameWidth = 0;
        _previousFrameHeight = 0;
    }

    [_frameTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                     mipmapLevel:0
                       withBytes:curr.bytes
                     bytesPerRow:tightPitch];

    CGSize drawableSize = _metalLayer.drawableSize;
    const double dw = MAX(1.0, (double)drawableSize.width);
    const double dh = MAX(1.0, (double)drawableSize.height);
    const double drawableAspect = dw / dh;

    double viewportWidth = dw;
    double viewportHeight = dh;

    const int mode = _aspectRatio.load();
    if (mode != 3) { // 3 = Stretch
        const float coreReported = _coreAspectRatio.load();
        const unsigned bw = _baseWidth.load();
        const unsigned bh = _baseHeight.load();
        double sourceAspect = SakuraPresentSourceAspect(mode, coreReported, bw, bh, width, height);

        if (sourceAspect > drawableAspect) {
            viewportHeight = dw / sourceAspect;
        } else {
            viewportWidth = dh * sourceAspect;
        }

        if (_integerScaling.load()) {
            const unsigned srcW = bw > 0 ? bw : width;
            const unsigned srcH = bh > 0 ? bh : height;
            double scaleX = std::floor(dw / (double)srcW);
            double scaleY = std::floor(dh / (double)srcH);
            double scale = std::max(1.0, std::min(scaleX, scaleY));
            viewportWidth = (double)srcW * scale;
            viewportHeight = (double)srcH * scale;
        }
    }

    MTLViewport viewport = {
        (dw - viewportWidth) * 0.5,
        (dh - viewportHeight) * 0.5,
        viewportWidth,
        viewportHeight,
        0.0,
        1.0
    };

    {
        using sc = std::chrono::steady_clock;
        static std::atomic<uint64_t> sLastLogNs{0};
        const uint64_t nowNs = (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(sc::now().time_since_epoch()).count();
        const uint64_t prev = sLastLogNs.load(std::memory_order_relaxed);
        if (nowNs - prev > 1000000000ULL) {
            sLastLogNs.store(nowNs, std::memory_order_relaxed);
            CGRect lf = _metalLayer.frame;
            NSLog(@"[Sakura.aspect] path=mailbox mode=%d drawable=%.0fx%.0f viewport=(%.1f,%.1f %.0fx%.0f) layerFrame=(%.0f,%.0f %.0fx%.0f) frame=%ux%u core=%.3f",
                mode, dw, dh, viewport.originX, viewport.originY, viewport.width, viewport.height,
                lf.origin.x, lf.origin.y, lf.size.width, lf.size.height,
                width, height, _coreAspectRatio.load());
        }
    }

#if SAKURA_HAS_METALFX
    const NSUInteger viewportPixelWidth = MAX((NSUInteger)1, (NSUInteger)std::round(viewportWidth));
    const NSUInteger viewportPixelHeight = MAX((NSUInteger)1, (NSUInteger)std::round(viewportHeight));
#endif
    BOOL metalFXInterpReady = NO;
#if SAKURA_HAS_METALFX
    if (@available(iOS 26.0, *)) {
        metalFXInterpReady = [MTLFXFrameInterpolatorDescriptor supportsDevice:_metalDevice]
            && [self ensureMetalFXFrameInterpolatorLocked:_textureWidth frameHeight:_textureHeight];
    }
#endif

    // Skip the interpolated-frame drawable while the screen is being captured
    // (iOS Control Center screen recording / AirPlay). The system compositor
    // holds extra drawables, and our pool of 3 is already tight; doubling the
    // demand causes nextDrawable to block until its 1s timeout, producing the
    // "one frame every few seconds" stall.
    BOOL screenIsCaptured = g_sakuraScreenIsCaptured.load(std::memory_order_relaxed);

    if (!screenIsCaptured && doInterp && havePrev && _previousFrameTexture && (metalFXInterpReady || _metalBlendPipeline)) {
        id<MTLCommandBuffer> interpCb = [_metalCommandQueue commandBuffer];
        if (interpCb) {
            id<CAMetalDrawable> interpDrawable = [_metalLayer nextDrawable];
            id<MTLTexture> interpTex = interpDrawable.texture;
            if (interpDrawable && interpTex) {
                BOOL drewInterp = NO;
#if SAKURA_HAS_METALFX
                if (metalFXInterpReady) {
                    drewInterp = [self presentMetalFXInterpolatedFrameLocked:interpTex
                                                                     viewport:viewport
                                                           viewportPixelWidth:viewportPixelWidth
                                                          viewportPixelHeight:viewportPixelHeight
                                                                commandBuffer:interpCb];
                }
#endif
                if (!drewInterp && _metalBlendPipeline
                    && [self renderBlendLocked:_previousFrameTexture
                                       current:_frameTexture
                                     toTexture:interpTex
                                 commandBuffer:interpCb
                                      viewport:viewport]) {
                    drewInterp = YES;
                }
                if (!drewInterp) {
                    drewInterp = [self renderTextureLocked:_frameTexture toTexture:interpTex commandBuffer:interpCb viewport:viewport clear:YES];
                }
                if (drewInterp) {
                    [interpCb presentDrawable:interpDrawable];
                    [interpCb commit];
                    [interpCb waitUntilScheduled];
                    _metalDrawablePresentCount.fetch_add(1);
                }
            }
        }
    }

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    id<MTLTexture> drawableTex = drawable ? drawable.texture : nil;
    if (!drawable || !drawableTex)
        return;

    id<MTLCommandBuffer> commandBuffer = [_metalCommandQueue commandBuffer];
    if (!commandBuffer) return;

    id<MTLTexture> sourceTexture = _frameTexture;
    sourceTexture = [self sakuraNeuralUpscaleSourceIfEnabledLocked:sourceTexture prebuiltBGRA:curr volatilePackedBGRABase:NULL volatilePackedBGRALength:0];

#if SAKURA_HAS_METALFX
    sourceTexture = [self textureMetalFXSourceLocked:sourceTexture commandBuffer:commandBuffer];
#endif
#if SAKURA_HAS_METALFX
    sourceTexture = [self displayMetalFXSourceLocked:sourceTexture
                                        commandBuffer:commandBuffer
                                          outputWidth:viewportPixelWidth
                                         outputHeight:viewportPixelHeight];
#endif

    if (![self renderTextureLocked:sourceTexture toTexture:drawableTex commandBuffer:commandBuffer viewport:viewport clear:YES]) {
        return;
    }
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    _metalDrawablePresentCount.fetch_add(1);

    if (incrementRendered)
        _framesRendered.fetch_add(1);
    if (incrementRendered && _gpuCpuDecouple.load()) {
        std::lock_guard<std::mutex> c(_cadenceMutex);
        _cadenceDupCurr = [curr copy];
        _cadenceDupW = width;
        _cadenceDupH = height;
        if (_metalFXFrameInterpolation.load() && prev.length == expectedLen)
            _cadenceDupPrev = [prev copy];
        else
            _cadenceDupPrev = nil;
    }
}

- (void)presentFrame:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch
{
    if (!data || width == 0 || height == 0) return;
    @autoreleasepool {
        const BOOL asyncPresent = _metalFXFrameInterpolation.load() || _gpuCpuDecouple.load();

        if (asyncPresent) {
            NSData *curr = [self copyBGRATightFrame:data pitch:pitch width:width height:height];
            if (!curr.length) return;
#if SAKURA_ENABLE_LIBRETRO_PSX
            [self cacheLatestSaveThumbnailFromBGRA:curr width:width height:height];
#endif
            [self enqueueMailboxGpuPresentCurrCPU:curr width:width height:height];
            return;
        }

        std::lock_guard<std::mutex> lock(_renderMutex);
        if (!_metalLayer || !_metalCommandQueue || ![self ensureMetalPipelineLocked]) return;
#if SAKURA_HAS_METALFX
        [self synchronizeDeferredMetalFXResourceTearsLocked];
#endif

        if (!_frameTexture || _textureWidth != width || _textureHeight != height) {
#if SAKURA_HAS_METALFX
            [self dropMetalFXFrameInterpolatorLocked];
#endif
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                  width:width
                                                                                                 height:height
                                                                                              mipmapped:NO];
            descriptor.usage = MTLTextureUsageShaderRead;
            descriptor.storageMode = MTLStorageModeShared;
            _frameTexture = [_metalDevice newTextureWithDescriptor:descriptor];
            _textureWidth = width;
            _textureHeight = height;
        }
        if (!_frameTexture) return;

        const uint8_t *uploadBytes = static_cast<const uint8_t *>(data);
        size_t uploadPitch = pitch;
        const size_t tightPitch = (size_t)width * 4;

        if (_pixelFormat == RETRO_PIXEL_FORMAT_RGB565 || _pixelFormat == RETRO_PIXEL_FORMAT_0RGB1555 || pitch != tightPitch) {
            _frameScratch.resize(tightPitch * (size_t)height);
            uint8_t *dstRows = _frameScratch.data();
            const uint8_t *srcRows = static_cast<const uint8_t *>(data);

            if (_pixelFormat == RETRO_PIXEL_FORMAT_RGB565) {
                for (unsigned y = 0; y < height; y++) {
                    const uint16_t *src = reinterpret_cast<const uint16_t *>(srcRows + y * pitch);
                    uint8_t *dst = dstRows + (size_t)y * tightPitch;
                    for (unsigned x = 0; x < width; x++) {
                        const uint16_t p = src[x];
                        dst[x * 4 + 0] = (uint8_t)((p & 0x1f) * 255 / 31);
                        dst[x * 4 + 1] = (uint8_t)(((p >> 5) & 0x3f) * 255 / 63);
                        dst[x * 4 + 2] = (uint8_t)(((p >> 11) & 0x1f) * 255 / 31);
                        dst[x * 4 + 3] = 0xff;
                    }
                }
            } else if (_pixelFormat == RETRO_PIXEL_FORMAT_0RGB1555) {
                for (unsigned y = 0; y < height; y++) {
                    const uint16_t *src = reinterpret_cast<const uint16_t *>(srcRows + y * pitch);
                    uint8_t *dst = dstRows + (size_t)y * tightPitch;
                    for (unsigned x = 0; x < width; x++) {
                        const uint16_t p = src[x];
                        dst[x * 4 + 0] = (uint8_t)((p & 0x1f) * 255 / 31);
                        dst[x * 4 + 1] = (uint8_t)(((p >> 5) & 0x1f) * 255 / 31);
                        dst[x * 4 + 2] = (uint8_t)(((p >> 10) & 0x1f) * 255 / 31);
                        dst[x * 4 + 3] = 0xff;
                    }
                }
            } else {
                for (unsigned y = 0; y < height; y++) {
                    memcpy(dstRows + (size_t)y * tightPitch, srcRows + (size_t)y * pitch, tightPitch);
                }
            }

            uploadBytes = _frameScratch.data();
            uploadPitch = tightPitch;
        }

        const BOOL doInterp = _metalFXFrameInterpolation.load();
        BOOL havePrev = NO;
        if (doInterp && _frameTexture && _textureWidth == width && _textureHeight == height && _metalDevice) {
            if (!_previousFrameTexture
                || _previousFrameWidth != _textureWidth
                || _previousFrameHeight != _textureHeight) {
                MTLTextureDescriptor *pd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:_textureWidth
                                                                                             height:_textureHeight
                                                                                          mipmapped:NO];
                pd.usage = MTLTextureUsageShaderRead;
                pd.storageMode = MTLStorageModeShared;
                _previousFrameTexture = [_metalDevice newTextureWithDescriptor:pd];
                _previousFrameWidth = _textureWidth;
                _previousFrameHeight = _textureHeight;
            }
            if (_previousFrameTexture) {
                id<MTLCommandBuffer> blitCb = [_metalCommandQueue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [blitCb blitCommandEncoder];
                [blit copyFromTexture:_frameTexture
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(_textureWidth, _textureHeight, 1)
                            toTexture:_previousFrameTexture
                     destinationSlice:0
                     destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit endEncoding];
                [blitCb commit];
                havePrev = YES;
            }
        } else if (!doInterp && _previousFrameTexture) {
            _previousFrameTexture = nil;
            _previousFrameWidth = 0;
            _previousFrameHeight = 0;
        }

        [_frameTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                          mipmapLevel:0
                            withBytes:uploadBytes
                          bytesPerRow:uploadPitch];
#if SAKURA_ENABLE_LIBRETRO_PSX
        {
            NSData *snap =
                [[NSData alloc] initWithBytes:uploadBytes length:tightPitch * (NSUInteger)height];
            [self cacheLatestSaveThumbnailFromBGRA:snap width:width height:height];
        }
#endif

        CGSize drawableSize = _metalLayer.drawableSize;
        const double dw = MAX(1.0, (double)drawableSize.width);
        const double dh = MAX(1.0, (double)drawableSize.height);
        const double drawableAspect = dw / dh;

        double viewportWidth = dw;
        double viewportHeight = dh;

        const int mode = _aspectRatio.load();
        if (mode != 3) { // 3 = Stretch
            const float coreReported = _coreAspectRatio.load();
            const unsigned bw = _baseWidth.load();
            const unsigned bh = _baseHeight.load();
            double sourceAspect = SakuraPresentSourceAspect(mode, coreReported, bw, bh, width, height);

            if (sourceAspect > drawableAspect) {
                viewportHeight = dw / sourceAspect;
            } else {
                viewportWidth = dh * sourceAspect;
            }

            if (_integerScaling.load()) {
                const unsigned srcW = bw > 0 ? bw : width;
                const unsigned srcH = bh > 0 ? bh : height;
                double scaleX = std::floor(dw / (double)srcW);
                double scaleY = std::floor(dh / (double)srcH);
                double scale = std::max(1.0, std::min(scaleX, scaleY));
                viewportWidth = (double)srcW * scale;
                viewportHeight = (double)srcH * scale;
            }
        }

        MTLViewport viewport = {
            (dw - viewportWidth) * 0.5,
            (dh - viewportHeight) * 0.5,
            viewportWidth,
            viewportHeight,
            0.0,
            1.0
        };

        {
            using sc = std::chrono::steady_clock;
            static std::atomic<uint64_t> sLastLogNs{0};
            const uint64_t nowNs = (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(sc::now().time_since_epoch()).count();
            const uint64_t prev = sLastLogNs.load(std::memory_order_relaxed);
            if (nowNs - prev > 1000000000ULL) {
                sLastLogNs.store(nowNs, std::memory_order_relaxed);
                CGRect lf = _metalLayer.frame;
                NSLog(@"[Sakura.aspect] path=direct mode=%d drawable=%.0fx%.0f viewport=(%.1f,%.1f %.0fx%.0f) layerFrame=(%.0f,%.0f %.0fx%.0f) frame=%ux%u core=%.3f",
                    mode, dw, dh, viewport.originX, viewport.originY, viewport.width, viewport.height,
                    lf.origin.x, lf.origin.y, lf.size.width, lf.size.height,
                    width, height, _coreAspectRatio.load());
            }
        }

#if SAKURA_HAS_METALFX
        const NSUInteger viewportPixelWidth = MAX((NSUInteger)1, (NSUInteger)std::round(viewportWidth));
        const NSUInteger viewportPixelHeight = MAX((NSUInteger)1, (NSUInteger)std::round(viewportHeight));
#endif
        BOOL metalFXInterpReady = NO;
#if SAKURA_HAS_METALFX
        if (@available(iOS 26.0, *)) {
            metalFXInterpReady = [MTLFXFrameInterpolatorDescriptor supportsDevice:_metalDevice]
                && [self ensureMetalFXFrameInterpolatorLocked:_textureWidth frameHeight:_textureHeight];
        }
#endif

        BOOL screenIsCaptured = g_sakuraScreenIsCaptured.load(std::memory_order_relaxed);

        if (!screenIsCaptured && doInterp && havePrev && _previousFrameTexture && (metalFXInterpReady || _metalBlendPipeline)) {
            id<MTLCommandBuffer> interpCb = [_metalCommandQueue commandBuffer];
            if (interpCb) {
                id<CAMetalDrawable> interpDrawable = [_metalLayer nextDrawable];
                id<MTLTexture> interpTex = interpDrawable.texture;
                if (interpDrawable && interpTex) {
                    BOOL drewInterp = NO;
#if SAKURA_HAS_METALFX
                    if (metalFXInterpReady) {
                        drewInterp = [self presentMetalFXInterpolatedFrameLocked:interpTex
                                                                         viewport:viewport
                                                               viewportPixelWidth:viewportPixelWidth
                                                              viewportPixelHeight:viewportPixelHeight
                                                                    commandBuffer:interpCb];
                    }
#endif
                    if (!drewInterp && _metalBlendPipeline
                        && [self renderBlendLocked:_previousFrameTexture
                                           current:_frameTexture
                                         toTexture:interpTex
                                     commandBuffer:interpCb
                                          viewport:viewport]) {
                        drewInterp = YES;
                    }
                    if (!drewInterp) {
                        drewInterp =
                            [self renderTextureLocked:_frameTexture toTexture:interpTex commandBuffer:interpCb viewport:viewport clear:YES];
                    }
                    if (drewInterp) {
                        [interpCb presentDrawable:interpDrawable];
                        [interpCb commit];
                        [interpCb waitUntilScheduled];
                        _metalDrawablePresentCount.fetch_add(1);
                    }
                }
            }
        }

        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        id<MTLTexture> drawableTex = drawable ? drawable.texture : nil;
        if (!drawable || !drawableTex)
            return;

        id<MTLCommandBuffer> commandBuffer = [_metalCommandQueue commandBuffer];
        if (!commandBuffer) return;

        const void *neuralCpuBase = NULL;
        NSUInteger neuralCpuLen = 0;
        if ([SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_live" defaultValue:NO]) {
            neuralCpuBase = uploadBytes;
            neuralCpuLen = tightPitch * (NSUInteger)height;
        }

        id<MTLTexture> sourceTexture = _frameTexture;
        sourceTexture = [self sakuraNeuralUpscaleSourceIfEnabledLocked:sourceTexture
                                                          prebuiltBGRA:nil
                                            volatilePackedBGRABase:neuralCpuBase
                                          volatilePackedBGRALength:neuralCpuLen];

#if SAKURA_HAS_METALFX
        sourceTexture = [self textureMetalFXSourceLocked:sourceTexture commandBuffer:commandBuffer];
#endif
#if SAKURA_HAS_METALFX
        sourceTexture = [self displayMetalFXSourceLocked:sourceTexture
                                            commandBuffer:commandBuffer
                                              outputWidth:viewportPixelWidth
                                             outputHeight:viewportPixelHeight];
#endif

        if (![self renderTextureLocked:sourceTexture toTexture:drawableTex commandBuffer:commandBuffer viewport:viewport clear:YES]) {
            return;
        }
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        _metalDrawablePresentCount.fetch_add(1);

        _framesRendered.fetch_add(1);
    }
}

- (void)pushAudioSamples:(const int16_t *)samples frames:(size_t)frames
{
    if (!samples || frames == 0) return;
    const size_t sampleCount = frames * 2;

    std::unique_lock<std::mutex> lock(_audioMutex);

    if (!_audioRing.empty()) {
        const double sr = std::max(8000.0, _audioCoreSampleRate.load());
        const int32_t lat = std::max(0, std::min(512, _audioLatencyMs.load()));
        const size_t maxBacklog = (size_t)std::max(1024.0, sr * 2.0 * (double)lat / 1000.0 * 2.5);
        while (_audioSampleCount > maxBacklog && _audioSampleCount > sampleCount + 2) {
            _audioReadIndex = (_audioReadIndex + 2) % _audioRing.size();
            _audioSampleCount -= 2;
        }
    }

    SakuraPS1Core *core = self;
    _audioCond.wait_for(lock, std::chrono::milliseconds(50), [core, sampleCount]() {
        return !core->_running.load() || core->_paused.load() ||
               (core->_audioSampleCount + sampleCount <= core->_audioRing.size());
    });

    if (!_running.load() || _paused.load() || _audioRing.empty()) return;

    if (_audioSampleCount + sampleCount > _audioRing.size()) {
        const size_t drop = (_audioSampleCount + sampleCount) - _audioRing.size();
        _audioReadIndex = (_audioReadIndex + drop) % _audioRing.size();
        _audioSampleCount -= drop;
    }

    const bool muteTurbo = _audioMuteWhenTurbo.load() && (_hostEmulationSpeed.load() > 1.01);

    for (size_t i = 0; i < sampleCount; i++) {
        _audioRing[_audioWriteIndex] = muteTurbo ? (int16_t)0 : samples[i];
        _audioWriteIndex = (_audioWriteIndex + 1) % _audioRing.size();
    }
    _audioSampleCount += (uint32_t)sampleCount;
}

- (void)startAudioWithSampleRate:(double)sampleRate
{
    [self stopAudio];
    _audioCoreSampleRate.store(sampleRate);
    int32_t lat = _audioLatencyMs.load();
    lat = std::max(32, std::min(512, lat));
    const double stereoPerSec = std::max(8000.0, sampleRate) * 2.0;
    const size_t latencyStereo = (size_t)std::max(256.0, stereoPerSec * (double)lat / 1000.0);
    size_t cap = latencyStereo * 8;
    cap = std::max(cap, (size_t)16384);
    const size_t tenSec = (size_t)std::min(stereoPerSec * 10.0, 960000.0);
    cap = std::min(cap, std::max(tenSec, (size_t)16384));
    _audioSampleLimit = cap;

    {
        std::lock_guard<std::mutex> lock(_audioMutex);
        _audioStretchAcc = 0.0;
        _audioStretchPrimed = false;
        _audioRing.assign(_audioSampleLimit, 0);
        _audioReadIndex = 0;
        _audioWriteIndex = 0;
        _audioSampleCount = 0;
    }

    memset(&_audioStreamDescription, 0, sizeof(_audioStreamDescription));
    _audioStreamDescription.mSampleRate = sampleRate;
    _audioStreamDescription.mFormatID = kAudioFormatLinearPCM;
    _audioStreamDescription.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    _audioStreamDescription.mBytesPerPacket = sizeof(int16_t) * 2;
    _audioStreamDescription.mFramesPerPacket = 1;
    _audioStreamDescription.mBytesPerFrame = sizeof(int16_t) * 2;
    _audioStreamDescription.mChannelsPerFrame = 2;
    _audioStreamDescription.mBitsPerChannel = 16;
#if TARGET_OS_IPHONE
    Sakura_IOS_ConfigureGameAudioSession(sampleRate);
#endif
    {
        const long frames = std::lround(sampleRate / 115.0);
        const long clamped = std::clamp(frames, 256L, 768L);
        _audioBufferByteSize = static_cast<UInt32>(clamped) * static_cast<UInt32>(_audioStreamDescription.mBytesPerFrame);
    }

    OSStatus status = AudioQueueNewOutput(&_audioStreamDescription,
                                          SakuraAudioQueueCallback,
                                          (__bridge void *)self,
                                          nullptr,
                                          nullptr,
                                          0,
                                          &_audioQueue);
    if (status != noErr || !_audioQueue) {
        NSLog(@"[SakuraPS1Core] Apple audio queue create failed: %d", (int)status);
        [self stopAudio];
        return;
    }

    _audioBuffers.clear();
    _audioBuffers.reserve(4);
    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef buffer = nullptr;
        status = AudioQueueAllocateBuffer(_audioQueue, _audioBufferByteSize, &buffer);
        if (status != noErr || !buffer) {
            NSLog(@"[SakuraPS1Core] Apple audio buffer allocate failed: %d", (int)status);
            [self stopAudio];
            return;
        }
        _audioBuffers.push_back(buffer);
        [self fillAudioQueueBuffer:buffer];
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, nullptr);
        if (status != noErr) {
            NSLog(@"[SakuraPS1Core] Apple audio buffer enqueue failed: %d", (int)status);
            [self stopAudio];
            return;
        }
    }

    status = AudioQueueStart(_audioQueue, nullptr);
    if (status != noErr) {
        NSLog(@"[SakuraPS1Core] Apple audio start failed: %d", (int)status);
        [self stopAudio];
    }
}

- (void)stopAudio
{
    AudioQueueRef queue = _audioQueue;
    _audioQueue = nullptr;
    if (queue) {
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
    }
    _audioBuffers.clear();
    _audioBufferByteSize = 0;
    std::lock_guard<std::mutex> lock(_audioMutex);
    _audioRing.clear();
    _audioReadIndex = 0;
    _audioWriteIndex = 0;
    _audioSampleCount = 0;
}

- (void)fillAudioQueueBuffer:(AudioQueueBufferRef)buffer
{
    if (!buffer || _audioBufferByteSize == 0) return;

    buffer->mAudioDataByteSize = _audioBufferByteSize;
    int16_t *out = static_cast<int16_t *>(buffer->mAudioData);
    const size_t outSamples = _audioBufferByteSize / sizeof(int16_t);
    const size_t outFrames = outSamples / 2;

    double spd = _hostEmulationSpeed.load();
    if (!(spd > 0.0) || spd != spd)
        spd = 1.0;
    spd = std::max(0.25, std::min(8.0, spd));
    const bool stretch = _audioTimeStretchEnabled.load() && std::fabs(spd - 1.0) > 0.02;

    std::lock_guard<std::mutex> lock(_audioMutex);

    auto popStereo = [&]() -> bool {
        if (_audioSampleCount < 2 || _audioRing.empty())
            return false;
        _audioStretchCurrL = _audioRing[_audioReadIndex];
        _audioReadIndex = (_audioReadIndex + 1) % _audioRing.size();
        _audioStretchCurrR = _audioRing[_audioReadIndex];
        _audioReadIndex = (_audioReadIndex + 1) % _audioRing.size();
        _audioSampleCount -= 2;
        return true;
    };

    if (!stretch) {
        _audioStretchAcc = 0.0;
        _audioStretchPrimed = false;
        size_t written = 0;
        while (written + 2 <= outSamples && _audioSampleCount >= 2 && !_audioRing.empty()) {
            out[written++] = _audioRing[_audioReadIndex];
            _audioReadIndex = (_audioReadIndex + 1) % _audioRing.size();
            out[written++] = _audioRing[_audioReadIndex];
            _audioReadIndex = (_audioReadIndex + 1) % _audioRing.size();
            _audioSampleCount -= 2;
        }
        _audioCond.notify_all();
        if (written < outSamples) {
            // Underrun concealment: hold last written stereo sample so very
            // low audio latency does not click on short starves.
            const int16_t holdL = (written >= 2) ? out[written - 2] : (int16_t)0;
            const int16_t holdR = (written >= 2) ? out[written - 1] : (int16_t)0;
            while (written + 2 <= outSamples) {
                out[written++] = holdL;
                out[written++] = holdR;
            }
            while (written < outSamples) {
                out[written++] = 0;
            }
        }
        return;
    }

    if (!_audioStretchPrimed && _audioSampleCount >= 2) {
        if (popStereo()) {
            _audioStretchPrevL = _audioStretchCurrL;
            _audioStretchPrevR = _audioStretchCurrR;
            _audioStretchPrimed = true;
            _audioStretchAcc = 0.0;
        }
    }

    for (size_t o = 0; o < outFrames; o++) {
        _audioStretchAcc += spd;
        while (_audioStretchAcc >= 1.0 && _audioSampleCount >= 2) {
            _audioStretchPrevL = _audioStretchCurrL;
            _audioStretchPrevR = _audioStretchCurrR;
            if (!popStereo())
                break;
            _audioStretchAcc -= 1.0;
        }

        if (!_audioStretchPrimed || (_audioStretchAcc >= 1.0 && _audioSampleCount < 2)) {
            out[o * 2] = 0;
            out[o * 2 + 1] = 0;
            continue;
        }

        const double t = std::clamp(_audioStretchAcc, 0.0, 1.0);
        const double tSm = 0.5 - 0.5 * std::cos(kSakuraPi * t);
        const double l = (double)_audioStretchPrevL + ((double)_audioStretchCurrL - (double)_audioStretchPrevL) * tSm;
        const double r = (double)_audioStretchPrevR + ((double)_audioStretchCurrR - (double)_audioStretchPrevR) * tSm;
        out[o * 2] = (int16_t)std::clamp(std::llround(l + SakuraAudioTpdfHalfLSB()), -32768LL, 32767LL);
        out[o * 2 + 1] = (int16_t)std::clamp(std::llround(r + SakuraAudioTpdfHalfLSB()), -32768LL, 32767LL);
    }
    _audioCond.notify_all();
}

- (NSString *)saveStatePathForISOBaseName:(NSString *)isoLastComponent slot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    NSString *entry = isoLastComponent.length ? isoLastComponent : @"nogame";
    return SakuraPS1ResolveSlotStatePath(entry, slot);
#else
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"SaveStates"];
    NSString *base = (isoLastComponent.length > 0) ? isoLastComponent.lastPathComponent : @"";
    if (!base.length) base = @"nogame";
    NSString *safe = [[base componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"]] componentsJoinedByString:@"_"];
    return [[dir stringByAppendingPathComponent:safe] stringByAppendingPathExtension:[NSString stringWithFormat:@"slot%d.state", slot]];
#endif
}

- (nullable NSString *)saveStatePreviewPathForLibraryISO:(NSString *)libraryISOEntry slot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    if (slot < 1 || slot > 10) return nil;
    NSString *entry = libraryISOEntry.length ? libraryISOEntry : @"nogame";
    NSString *resolved = SakuraPS1ResolveSlotStatePath(entry, slot);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!resolved.length || ![fm fileExistsAtPath:resolved])
        return nil;
    // prefer the thumb that sits next to the .state that actually loaded
    // (legacy folder, legacy-flat stem, etc.). fall back to the canonical
    // location so older states whose thumbs were written under the new
    // path, or vice versa, still surface in the library. without the
    // canonical fallback, every TV-library tile for a legacy save came up blank.
    NSString *primary = SakuraPS1PreviewPNGAdjacentToResolvedState(resolved);
    if (primary.length && [fm fileExistsAtPath:primary]) return primary;
    NSString *canonical = SakuraPS1CanonicalSlotStatePath(entry, slot);
    if (canonical.length && ![canonical isEqualToString:resolved]) {
        NSString *fallback = SakuraPS1PreviewPNGAdjacentToResolvedState(canonical);
        if (fallback.length && [fm fileExistsAtPath:fallback]) return fallback;
    }
    return nil;
#else
    (void)libraryISOEntry;
    (void)slot;
    return nil;
#endif
}

- (NSString *)statePathForSlot:(int)slot
{
#if SAKURA_ENABLE_LIBRETRO_PSX
    return SakuraPS1ResolveSlotStatePath([self sakuraLibraryISOForSavePaths], slot);
#else
    NSString *base = _loadedGamePath.lastPathComponent ?: @"nogame";
    return [self saveStatePathForISOBaseName:base slot:slot];
#endif
}

static int16_t SakuraMergeRetroAnalogAxis(int touch, int phys)
{
    int32_t s = (int32_t)touch + (int32_t)phys;
    if (s > 32767) return 32767;
    if (s < -32768) return -32768;
    return (int16_t)s;
}

- (int16_t)inputStateForPort:(unsigned)port device:(unsigned)device index:(unsigned)index id:(unsigned)inputID
{
    if (port >= 2) return 0;
    const int pi = (int)port;
    const unsigned devClass = device & RETRO_DEVICE_MASK;
    if (devClass == RETRO_DEVICE_JOYPAD) {
        if (inputID == RETRO_DEVICE_ID_JOYPAD_MASK) {
            uint16_t bits = 0;
            for (unsigned bid = RETRO_DEVICE_ID_JOYPAD_B; bid <= RETRO_DEVICE_ID_JOYPAD_R3; bid++) {
                const int t = _buttons[pi][bid].load();
                const int p = _physicalPadButtons[pi][bid].load();
                if (t | p)
                    bits |= (uint16_t)(1u << bid);
            }
            return (int16_t)bits;
        }
        if (inputID < 16) {
            const int t = _buttons[pi][inputID].load();
            const int p = _physicalPadButtons[pi][inputID].load();
            return (t | p) ? 1 : 0;
        }
        return 0;
    }
    if (devClass == RETRO_DEVICE_ANALOG) {
        const BOOL axisQuery =
            (index == RETRO_DEVICE_INDEX_ANALOG_LEFT || index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) &&
            (inputID == RETRO_DEVICE_ID_ANALOG_X || inputID == RETRO_DEVICE_ID_ANALOG_Y);

        if (!axisQuery) {
            if (inputID == RETRO_DEVICE_ID_JOYPAD_MASK) {
                uint16_t bits = 0;
                for (unsigned bid = RETRO_DEVICE_ID_JOYPAD_B; bid <= RETRO_DEVICE_ID_JOYPAD_R3; bid++) {
                    const int t = _buttons[pi][bid].load();
                    const int p = _physicalPadButtons[pi][bid].load();
                    if (t | p)
                        bits |= (uint16_t)(1u << bid);
                }
                return (int16_t)bits;
            }
            if (inputID < 16) {
                const int t = _buttons[pi][inputID].load();
                const int p = _physicalPadButtons[pi][inputID].load();
                return (t | p) ? 1 : 0;
            }
            return 0;
        }
        if ((SakuraPS1ControllerMode)_storedControllerMode[pi].load(std::memory_order_relaxed) !=
            SakuraPS1ControllerModeDualShock &&
            _autoSwitchControllerMode.load()) {
            _sawAnalogPoll[pi].store(true);
            return 0;
        }
        if (index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
            return inputID == RETRO_DEVICE_ID_ANALOG_X
                ? SakuraMergeRetroAnalogAxis(_leftX[pi].load(), _physLeftX[pi].load())
                : SakuraMergeRetroAnalogAxis(_leftY[pi].load(), _physLeftY[pi].load());
        }
        if (index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
            return inputID == RETRO_DEVICE_ID_ANALOG_X
                ? SakuraMergeRetroAnalogAxis(_rightX[pi].load(), _physRightX[pi].load())
                : SakuraMergeRetroAnalogAxis(_rightY[pi].load(), _physRightY[pi].load());
        }
        return 0;
    }
    return 0;
}

#if SAKURA_ENABLE_LIBRETRO_PSX
- (void)runLoopWithTargetFPS:(double)targetFPS
{
    using clock = std::chrono::steady_clock;
    (void)targetFPS;
    auto next = clock::now();
    auto fpsStart = clock::now();
    uint64_t fpsFrames = 0;
    uint64_t lastFrames = _framesRendered.load();

    while (_running.load()) {
        if (!_paused.load()) {
            {
                std::lock_guard<std::mutex> lock(_coreMutex);
                if (_retroPortDeviceDirty.exchange(false, std::memory_order_acq_rel)) {
                    [self retroApplyStoredPortUnsafe];
                }
                retro_run();
            }
            fpsFrames++;

            // periodic SRAM flush, roughly every 30 s of real playtime.
            // flushSaveRAMToDisk itself hashes and early-outs if unchanged,
            // so the common case is one FNV pass and no file I/O.
            if ((_sramFlushTickCounter.fetch_add(1, std::memory_order_relaxed) % 1800u) == 1799u) {
                __weak SakuraPS1Core *weakSelf = self;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    [weakSelf flushSaveRAMToDisk];
                });
            }

            // Auto-switch: if the input callback observed a game polling
            // analog axes while the user's mode was Digital, promote the
            // persisted mode to DualShock once per port. The flag is cleared
            // in the exchange so we only fire one notification per detection.
            if (_autoSwitchControllerMode.load()) {
                for (int pIdx = 0; pIdx < 2; pIdx++) {
                    if (_sawAnalogPoll[pIdx].exchange(false) &&
                        (SakuraPS1ControllerMode)_storedControllerMode[pIdx].load(std::memory_order_relaxed)
                            != SakuraPS1ControllerModeDualShock) {
                        NSString *gameKey = [_loadedGamePath copy] ?: @"";
                        const int capturedPort = pIdx;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSNotificationCenter defaultCenter]
                                postNotificationName:@"SakuraPS1AutoSwitchToDualShockRequested"
                                              object:nil
                                            userInfo:@{ @"game": gameKey, @"port": @(capturedPort) }];
                        });
                    }
                }
            }
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(8));
        }

        auto now = clock::now();
        double elapsed = std::chrono::duration<double>(now - fpsStart).count();
        if (elapsed >= 1.0) {
            uint64_t currentFrames = _framesRendered.load();
            _fps.store((double)(currentFrames - lastFrames) / elapsed);
            _vps.store((double)fpsFrames / elapsed);
            lastFrames = currentFrames;
            fpsFrames = 0;
            fpsStart = now;
        }

        const double nominalHz = std::max(1.0, _targetFPS.load());
        double spd = _hostEmulationSpeed.load();
        if (!(spd > 0.0) || spd != spd)
            spd = 1.0;
        spd = std::max(0.25, std::min(8.0, spd));
        const double effectiveHz = nominalHz * spd;
        auto frameDuration = std::chrono::duration_cast<clock::duration>(
            std::chrono::duration<double>(1.0 / std::max(0.5, effectiveHz)));
        next += frameDuration;
        now = clock::now();
        if (next > now) {
            std::this_thread::sleep_until(next);
        } else if (now - next > std::chrono::milliseconds(250)) {
            next = now;
        }
    }
}
#endif

static void SakuraAudioQueueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    SakuraPS1Core *core = (__bridge SakuraPS1Core *)userData;
    if (!core || !buffer) return;
    [core fillAudioQueueBuffer:buffer];
    AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}

static int SakuraAxisToRetro(float value)
{
    float clamped = std::max(-1.0f, std::min(1.0f, value));
    return (int)lrintf(clamped * 32767.0f);
}

static void SakuraPostGeometryChanged(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SakuraGeometryChangedNotification object:nil];
    });
}

static int SakuraRetroIDForSakuraButton(NSInteger button)
{
    switch (button) {
        case 0: return RETRO_DEVICE_ID_JOYPAD_UP;
        case 1: return RETRO_DEVICE_ID_JOYPAD_DOWN;
        case 2: return RETRO_DEVICE_ID_JOYPAD_LEFT;
        case 3: return RETRO_DEVICE_ID_JOYPAD_RIGHT;
        case 4: return RETRO_DEVICE_ID_JOYPAD_B;
        case 5: return RETRO_DEVICE_ID_JOYPAD_A;
        case 6: return RETRO_DEVICE_ID_JOYPAD_Y;
        case 7: return RETRO_DEVICE_ID_JOYPAD_X;
        case 8: return RETRO_DEVICE_ID_JOYPAD_L;
        case 9: return RETRO_DEVICE_ID_JOYPAD_R;
        case 10: return RETRO_DEVICE_ID_JOYPAD_L2;
        case 11: return RETRO_DEVICE_ID_JOYPAD_R2;
        case 12: return RETRO_DEVICE_ID_JOYPAD_START;
        case 13: return RETRO_DEVICE_ID_JOYPAD_SELECT;
        case 14: return RETRO_DEVICE_ID_JOYPAD_L3;
        case 15: return RETRO_DEVICE_ID_JOYPAD_R3;
        default: return -1;
    }
}

#if SAKURA_ENABLE_LIBRETRO_PSX
static struct retro_vfs_interface g_sakuraVFSInterface = {
    SakuraVFSGetPath,
    SakuraVFSOpen,
    SakuraVFSClose,
    SakuraVFSSize,
    SakuraVFSTell,
    SakuraVFSSeek,
    SakuraVFSRead,
    SakuraVFSWrite,
    SakuraVFSFlush,
    SakuraVFSRemove,
    SakuraVFSRename,
    SakuraVFSTruncate,
};

static const struct retro_variable g_sakuraCoreVariables[] = {
    {"beetle_psx_cd_access_method", "precache"},
    {"beetle_psx_hw_cd_access_method", "precache"},
    {"beetle_psx_cd_fastload", "2x(native)"},
    {"beetle_psx_hw_cd_fastload", "2x(native)"},
    {"beetle_psx_cpu_freq_scale", "100%"},
    {"beetle_psx_hw_cpu_freq_scale", "100%"},
    {"beetle_psx_frame_duping", "enabled"},
    {"beetle_psx_hw_frame_duping", "enabled"},
    {"beetle_psx_deinterlacer", "bob"},
    {"beetle_psx_hw_deinterlacer", "bob"},
    {nullptr, nullptr},
};

static bool SakuraRetroEnvironment(unsigned cmd, void *data)
{
    SakuraPS1Core *core = g_sakuraPS1Core;
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_VARIABLE:
            if (data) {
                struct retro_variable *var = static_cast<struct retro_variable *>(data);
                var->value = SakuraRetroVariableValueForKey(var->key);
                return var->value != nullptr;
            }
            return false;
        case RETRO_ENVIRONMENT_SET_VARIABLES:
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            if (data) {
                const bool dirty = core ? core->_variablesDirty.exchange(false) : false;
                *static_cast<bool *>(data) = dirty;
                return true;
            }
            return false;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            if (data && core) core->_pixelFormat = *static_cast<enum retro_pixel_format *>(data);
            return true;
        case RETRO_ENVIRONMENT_SET_GEOMETRY:
            if (data && core) {
                struct retro_game_geometry *geom = static_cast<struct retro_game_geometry *>(data);
                bool changed = false;
                if (geom->base_width > 0 && core->_baseWidth.load() != geom->base_width) {
                    core->_baseWidth.store(geom->base_width);
                    changed = true;
                }
                if (geom->base_height > 0 && core->_baseHeight.load() != geom->base_height) {
                    core->_baseHeight.store(geom->base_height);
                    changed = true;
                }
                if (geom->aspect_ratio > 0.0f && std::fabs(core->_coreAspectRatio.load() - (float)geom->aspect_ratio) > 0.0001f) {
                    core->_coreAspectRatio.store((float)geom->aspect_ratio);
                    changed = true;
                }
                if (changed) SakuraPostGeometryChanged();
            }
            return true;
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
            if (data && core) {
                struct retro_system_av_info *av = static_cast<struct retro_system_av_info *>(data);
                bool changed = false;
                if (av->geometry.base_width > 0 && core->_baseWidth.load() != av->geometry.base_width) {
                    core->_baseWidth.store(av->geometry.base_width);
                    changed = true;
                }
                if (av->geometry.base_height > 0 && core->_baseHeight.load() != av->geometry.base_height) {
                    core->_baseHeight.store(av->geometry.base_height);
                    changed = true;
                }
                if (av->geometry.aspect_ratio > 0.0f && std::fabs(core->_coreAspectRatio.load() - (float)av->geometry.aspect_ratio) > 0.0001f) {
                    core->_coreAspectRatio.store((float)av->geometry.aspect_ratio);
                    changed = true;
                }
                if (av->timing.fps > 1.0) core->_targetFPS.store(av->timing.fps);
                if (changed) SakuraPostGeometryChanged();
            }
            return true;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if (data && core) {
                *static_cast<const char **>(data) = core->_systemDirectory.c_str();
                return true;
            }
            return false;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (data && core) {
                *static_cast<const char **>(data) = core->_saveDirectory.c_str();
                return true;
            }
            return false;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            if (data) {
                *static_cast<bool *>(data) = true;
                return true;
            }
            return false;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;
        case RETRO_ENVIRONMENT_GET_VFS_INTERFACE:
            if (data) {
                struct retro_vfs_interface_info *info = static_cast<struct retro_vfs_interface_info *>(data);
                if (info->required_interface_version > 2) return false;
                info->required_interface_version = 2;
                info->iface = &g_sakuraVFSInterface;
                return true;
            }
            return false;
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            return false;
        default:
            return false;
    }
}

static const char *SakuraRetroVariableValueForKey(const char *key)
{
    if (!key) return nullptr;
    if (strcmp(key, "beetle_psx_skip_bios") == 0 || strcmp(key, "beetle_psx_hw_skip_bios") == 0) {
        SakuraPS1Core *c = g_sakuraPS1Core;
        return (c && c->_fastBoot.load()) ? "enabled" : "disabled";
    }
    SakuraPS1Core *core = g_sakuraPS1Core;
    if (core) {
        std::lock_guard<std::mutex> lock(core->_varOverrideMutex);
        auto it = core->_varOverrides.find(key);
        if (it != core->_varOverrides.end() && !it->second.empty()) {
            return it->second.c_str();
        }
    }
    for (const struct retro_variable *var = g_sakuraCoreVariables; var->key; var++) {
        if (strcmp(var->key, key) == 0) return var->value;
    }
    return nullptr;
}

static void SakuraRetroVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
    [g_sakuraPS1Core presentFrame:data width:width height:height pitch:pitch];
}

static void SakuraRetroAudioSample(int16_t left, int16_t right)
{
    int16_t samples[2] = {left, right};
    [g_sakuraPS1Core pushAudioSamples:samples frames:1];
}

static size_t SakuraRetroAudioSampleBatch(const int16_t *data, size_t frames)
{
    [g_sakuraPS1Core pushAudioSamples:data frames:frames];
    return frames;
}

static void SakuraRetroInputPoll(void)
{
    [SakuraBridge pumpPhysicalGamepad];
}

static int16_t SakuraRetroInputState(unsigned port, unsigned device, unsigned index, unsigned id)
{
    return [g_sakuraPS1Core inputStateForPort:port device:device index:index id:id];
}

static const char *SakuraVFSGetPath(struct retro_vfs_file_handle *stream)
{
    return IOSNativeFileIO::GetPath(stream);
}

static struct retro_vfs_file_handle *SakuraVFSOpen(const char *path, unsigned mode, unsigned hints)
{
    unsigned flags = 0;
    if ((mode & RETRO_VFS_FILE_ACCESS_READ) != 0) flags |= IOSNativeFileIO::OpenRead;
    if ((mode & RETRO_VFS_FILE_ACCESS_WRITE) != 0) flags |= IOSNativeFileIO::OpenWrite;
    if ((mode & RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING) != 0) flags |= IOSNativeFileIO::OpenUpdateExisting;
    if ((hints & RETRO_VFS_FILE_ACCESS_HINT_FREQUENT_ACCESS) != 0) flags |= IOSNativeFileIO::OpenFrequentAccess;
    if ((flags & (IOSNativeFileIO::OpenRead | IOSNativeFileIO::OpenWrite)) == 0) flags |= IOSNativeFileIO::OpenRead;
    return reinterpret_cast<struct retro_vfs_file_handle *>(IOSNativeFileIO::OpenFile(path, flags));
}

static int SakuraVFSClose(struct retro_vfs_file_handle *stream)
{
    IOSNativeFileIO::CloseFile(stream);
    return 0;
}

static int64_t SakuraVFSSize(struct retro_vfs_file_handle *stream)
{
    return stream ? static_cast<int64_t>(IOSNativeFileIO::GetSize(stream)) : -1;
}

static int64_t SakuraVFSTell(struct retro_vfs_file_handle *stream)
{
    return IOSNativeFileIO::Tell(stream);
}

static int64_t SakuraVFSSeek(struct retro_vfs_file_handle *stream, int64_t offset, int seekPosition)
{
    return IOSNativeFileIO::Seek(stream, offset, seekPosition);
}

static int64_t SakuraVFSRead(struct retro_vfs_file_handle *stream, void *s, uint64_t len)
{
    return IOSNativeFileIO::ReadSequential(stream, s, len);
}

static int64_t SakuraVFSWrite(struct retro_vfs_file_handle *stream, const void *s, uint64_t len)
{
    return IOSNativeFileIO::WriteSequential(stream, s, len);
}

static int SakuraVFSFlush(struct retro_vfs_file_handle *stream)
{
    IOSNativeFileIO::Flush(stream);
    return 0;
}

static int SakuraVFSRemove(const char *path)
{
    return IOSNativeFileIO::RemoveFile(path) ? 0 : -1;
}

static int SakuraVFSRename(const char *oldPath, const char *newPath)
{
    return IOSNativeFileIO::RenameFile(oldPath, newPath) ? 0 : -1;
}

static int64_t SakuraVFSTruncate(struct retro_vfs_file_handle *stream, int64_t length)
{
    if (length < 0) return -1;
    return IOSNativeFileIO::Truncate(stream, static_cast<uint64_t>(length)) ? 0 : -1;
}

static bool SakuraWriteFileAtomic(NSString *path, const void *data, size_t size)
{
    if (path.length == 0 || (!data && size > 0)) return false;
    NSString *tmp = [path stringByAppendingFormat:@".tmp.%llu", (unsigned long long)mach_absolute_time()];
    void *handle = IOSNativeFileIO::OpenFile(tmp.fileSystemRepresentation, IOSNativeFileIO::OpenWrite);
    if (!handle) return false;
    const bool wrote = IOSNativeFileIO::Write(handle, 0, data, size);
    IOSNativeFileIO::CloseFile(handle);
    if (!wrote) {
        IOSNativeFileIO::RemoveFile(tmp.fileSystemRepresentation);
        return false;
    }
    if (rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        IOSNativeFileIO::RemoveFile(tmp.fileSystemRepresentation);
        return false;
    }
    return true;
}
#endif

@end

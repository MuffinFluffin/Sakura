#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SakuraPS1ControllerMode) {
    SakuraPS1ControllerModeDigital = 0,
    SakuraPS1ControllerModeDualShock = 1,
};

@interface SakuraPS1Core : NSObject

+ (nonnull instancetype)shared;

@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, getter=isPaused) BOOL paused;
@property(nonatomic) SakuraPS1ControllerMode controllerMode;
@property(nonatomic) int aspectRatio;
@property(nonatomic) BOOL fastBoot;
@property(nonatomic) float upscaleMultiplier;
@property(nonatomic) BOOL metalFXTexture;
// INI EmuCore/GS metalfx_temporal_display. uses MetalFX MTLFXTemporalScaler with cleared RG16 motion and depth stubs, optional spatial fallback on failure. separate from internal-res spatial scaler (metalFXTexture) and from MetalFX frame interpolation (metalFXFrameInterpolation).
@property(nonatomic) BOOL metalFXTemporalDisplay;
// when YES, emulation thread pushes pixels to a mailbox and the main thread uploads and presents Metal (CAMetalLayer). when NO, present runs on the emulation thread for latency debugging.
@property(nonatomic) BOOL mainThreadMetalPresentEnabled;
// INI EmuCore/GS videotoolbox_ios26_frame_features. on iOS 26+ device, VideoToolbox Low-Latency Frame Interpolation (VTLowLatencyFrameInterpolation) between consecutive core frames blits to _frameTexture before MetalFX/present. no libretro key, ignored on simulator and older iOS.
@property(nonatomic) BOOL videotoolboxFrameFeatures;
// INI EmuCore/GS metalfx_frame_interpolation. extra Metal present between PS1 frames (MetalFX or blend) for higher display refresh. pairs with videotoolboxFrameFeatures for the MetalFX path on iOS 26+.
@property(nonatomic) BOOL metalFXFrameInterpolation;
// final Metal blit presets. Beetle GPU tex filter strings are applied separately. 0=Nearest, 1=Bilinear,
// 2=3-point, 3=SABR blend, 4=xBR edge-directed, 5=xBRZ+corners, 6=FSR-style sharpened upscale, 7=Anime4K-style edge refine (linear taps).
@property(nonatomic) int textureFilter;
// INI EmuCore/GS fxaa: post-process anti-alias on Metal output after texture filter/CAS.
@property(nonatomic) BOOL fxaa;
// INI EmuCore/GS smaa_quality. 0=Off, 1=Low, 2=Medium, 3=High, 4=Ultra. runs the 3-pass SMAA driver
// (edge, blend weights, neighborhood) after the presentation shader. independent of FXAA, use either,
// neither, or both. sakura adds linear-space, adaptive threshold, pixel-art preserve.
@property(nonatomic) int smaaQuality;
// INI EmuCore/GS smaa_linear: edge detection in linear color space (recommended ON for sRGB framebuffers).
@property(nonatomic) BOOL smaaLinearSpace;
// INI EmuCore/GS smaa_adaptive: per-pixel adaptive threshold from local 3x3 luma variance.
@property(nonatomic) BOOL smaaAdaptiveThreshold;
// INI EmuCore/GS smaa_pixel_art: skip blending on axis-aligned hard-edge pixels (preserves PSX UI text).
@property(nonatomic) BOOL smaaPixelArtMode;
// INI EmuCore/GS smaa_threshold_scale: multiplier on the base 0.05 SMAA threshold (0.5..2.0 typical).
@property(nonatomic) float smaaThresholdScale;
// INI EmuCore/GS smaa_pixel_art_tol: pixel-art mode tolerance, smaller is stricter (default 0.04).
@property(nonatomic) float smaaPixelArtTolerance;
@property(nonatomic) int casMode;
@property(nonatomic) int casSharpness;
@property(nonatomic) BOOL autoSwitchControllerMode;
// wall-clock fast-forward / slow-mo. multiplies how many retro_run calls fit in real time (1=realtime, 2 ~= 2x). beetle CPU/GPU OC is separate.
@property(nonatomic) double hostEmulationSpeed;

// output queue. latency 0..512 ms, backlog trim always-on (audioSync arg accepted for ABI stability but ignored), optional mute while run speed > 1x, optional pitch-stable resampling when run speed != 1x. applied live from applyEmulatorSettings.
- (void)applyHostAudioSettingsLatencyMs:(NSInteger)latencyMs audioSync:(BOOL)audioSync muteWhenTurbo:(BOOL)muteWhenTurbo audioTimeStretch:(BOOL)audioTimeStretch;

- (nonnull NSString *)coreName;
- (nullable NSString *)lastError;

- (void)setRenderView:(nullable UIView *)view;
- (void)notifyDisplayResizeWithWidth:(int)width height:(int)height scale:(float)scale;

// main thread only. duplicate-present the last uploaded GPU frame at display refresh when mainThreadMetalPresentEnabled is on (ProMotion etc.).
- (void)gpuCadencePump;

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
                         highlightCompress:(float)highlightCompress;

- (BOOL)bootGameAtPath:(nonnull NSString *)gamePath biosPath:(nullable NSString *)biosPath error:(NSError * _Nullable * _Nullable)error;
- (void)stop;

// push a libretro core option override, e.g. beetle_psx_pgxp_mode = "memory only".
// most beetle PSX options only take effect on next game boot.
- (void)setLibretroVariable:(nonnull NSString *)key value:(nullable NSString *)value;

- (void)setPadButton:(NSInteger)button pressed:(BOOL)pressed;
- (void)setLeftStickX:(float)x y:(float)y;
- (void)setRightStickX:(float)x y:(float)y;
- (void)setPhysicalPadButton:(NSInteger)button pressed:(BOOL)pressed;
- (void)setPhysicalLeftStickX:(float)x y:(float)y;
- (void)setPhysicalRightStickX:(float)x y:(float)y;
- (void)pressAnalogModeToggle;

// Per-port variants. Port 0 = PS1 Player 1, Port 1 = PS1 Player 2. Touch
// input is locked to port 0 by the Swift layer; physical gamepads route
// through the port assigner. Out-of-range ports are clamped to 0.
- (SakuraPS1ControllerMode)controllerModeForPort:(int)port;
- (void)setControllerMode:(SakuraPS1ControllerMode)mode forPort:(int)port;
- (void)setPadButton:(NSInteger)button pressed:(BOOL)pressed port:(int)port;
- (void)setLeftStickX:(float)x y:(float)y port:(int)port;
- (void)setRightStickX:(float)x y:(float)y port:(int)port;
- (void)setPhysicalPadButton:(NSInteger)button pressed:(BOOL)pressed port:(int)port;
- (void)setPhysicalLeftStickX:(float)x y:(float)y port:(int)port;
- (void)setPhysicalRightStickX:(float)x y:(float)y port:(int)port;
- (void)pressAnalogModeToggleForPort:(int)port;

- (BOOL)saveStateToSlot:(int)slot;
- (BOOL)loadStateFromSlot:(int)slot;
- (BOOL)hasSaveStateInSlot:(int)slot;
- (nullable NSDate *)saveStateDateForSlot:(int)slot;

// memory card (SRAM) persistence via libretro's RETRO_MEMORY_SAVE_RAM.
// loadSaveRAMFromDisk runs after the core accepts retro_load_game.
// flushSaveRAMToDisk runs on stop, periodic tick, app background, and after
// every save-state write. manual invocation is safe, hash-deduped.
- (BOOL)loadSaveRAMFromDisk;
- (BOOL)flushSaveRAMToDisk;

- (BOOL)writeSaveStateBytesToPath:(nonnull NSString *)path;
- (BOOL)loadSaveStateBytesFromPath:(nonnull NSString *)path;

- (nonnull NSString *)saveStatePathForISOBaseName:(nonnull NSString *)isoLastComponent slot:(int)slot;
- (nullable NSString *)saveStatePreviewPathForLibraryISO:(nonnull NSString *)libraryISOEntry slot:(int)slot;

- (double)fps;
- (double)vps;
- (double)speed;
- (uint64_t)framesRendered;
// monotonic count of CAMetalDrawable presentDrawable commits, includes split-present cadence duplicates.
- (uint64_t)metalLayerDrawablePresentCount;

// libretro nominal framebuffer size before host upscale / aspect padding
- (unsigned)baseWidth;
- (unsigned)baseHeight;
// last uploaded emulator frame dimensions (BGRA texture), 0 when none.
- (unsigned)presentPixelWidth;
- (unsigned)presentPixelHeight;

@end

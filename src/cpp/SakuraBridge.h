// SakuraBridge.h: ObjC bridge for C++ emulator control
// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT void SakuraLogUnified(NSString *_Nonnull subsystem, NSString *_Nonnull level, NSString *_Nonnull message);

typedef NS_ENUM(NSInteger, SakuraEmulatorState) {
    SakuraEmulatorStateStopped = 0,
    SakuraEmulatorStateRunning,
    SakuraEmulatorStatePaused,
    SakuraEmulatorStateSaving,
    SakuraEmulatorStateSuspended,
};

typedef NS_ENUM(NSInteger, SakuraCoreType) {
    SakuraCoreTypeInterpreter = 0,
};

typedef NS_ENUM(NSInteger, PadButton) {
    PadButtonUp = 0,
    PadButtonDown,
    PadButtonLeft,
    PadButtonRight,
    PadButtonCross,
    PadButtonCircle,
    PadButtonSquare,
    PadButtonTriangle,
    PadButtonL1,
    PadButtonR1,
    PadButtonL2,
    PadButtonR2,
    PadButtonStart,
    PadButtonSelect,
    PadButtonL3,
    PadButtonR3,
};

@interface SakuraBridge : NSObject

// Game render view (for UIViewRepresentable)
+ (nonnull UIView *)gameRenderView;

// Lifecycle
+ (void)saveNVRAM;
+ (void)saveMemoryCards;
+ (void)saveAllState;  // NVM + MC
+ (BOOL)isRunning;

// NVM status
+ (nullable NSDate *)lastNVMSaveDate;
+ (nullable NSString *)nvmFilePath;
+ (BOOL)nvmFileExists;

// save state slots 1..10, async, returns immediately.
// completion fires on main queue. ok == false on failure: no running vm,
// empty slot, decode error, etc.
+ (BOOL)saveStateToSlot:(int)slot;
+ (BOOL)loadStateFromSlot:(int)slot;
+ (BOOL)hasSaveStateInSlot:(int)slot;
+ (nullable NSDate *)saveStateDateForSlot:(int)slot;
+ (BOOL)hasSaveStateInSlot:(int)slot forISOFileName:(nonnull NSString *)isoName;
+ (nullable NSDate *)saveStateDateForSlot:(int)slot forISOFileName:(nonnull NSString *)isoName;

// Save states by explicit path (for media attachments)
+ (BOOL)writeSaveStateBytesToPath:(nonnull NSString *)path;
+ (BOOL)loadSaveStateBytesFromPath:(nonnull NSString *)path;

// library-relative iso name to resolved absolute path when the file exists.
+ (nullable NSString *)resolvedAbsolutePathForLibraryISO:(nullable NSString *)isoName;
// total byte count of the payload at isoPath. for .cue/.m3u/.ccd we sum
// referenced bin/img/disc files so multi-disc sets do not show 80 bytes.
// falls back to the file's own size when no child files can be resolved.
+ (uint64_t)totalPayloadByteCountForISOPath:(nonnull NSString *)isoPath;
// SaveStates/<per-game>/slotN.preview.png when present, slots 1..10.
+ (nullable NSString *)saveStatePreviewPathForISOName:(nonnull NSString *)isoName slot:(int)slot;
// remove slot 1..10 .state files and adjacent preview pngs for this entry, no-op if none.
+ (void)deleteSaveStatesAndPreviewsForLibraryISO:(nonnull NSString *)isoName;

// Pad input
+ (void)setPadButton:(PadButton)button pressed:(BOOL)pressed;
+ (void)setPadButton:(PadButton)button pressed:(BOOL)pressed port:(int)port;
+ (void)setLeftStickX:(float)x y:(float)y;
+ (void)setLeftStickX:(float)x y:(float)y port:(int)port;
+ (void)setRightStickX:(float)x y:(float)y;
+ (void)setRightStickX:(float)x y:(float)y port:(int)port;

// vibration legacy hook. ps1 cores may post via notification for haptics.
// rumble commands. values are 0..1, large is low-freq, small is high-freq.
+ (void)handleVibrationForPad:(int)padIndex largeMotor:(float)largeMotor smallMotor:(float)smallMotor;

// VM control
+ (void)requestVMStop;
+ (void)setFullScreen:(BOOL)enabled;

// Info
+ (nonnull NSString *)biosName;
+ (nonnull NSString *)buildVersion;
+ (BOOL)recommendedMTVUEnabled;

// osd overlay no-ops, swift hud owns overlays.
+ (void)setPerformanceOverlayVisible:(BOOL)visible;
+ (BOOL)isPerformanceOverlayVisible;
+ (void)applyOsdPreset:(int)preset;  // legacy. prefer per-flag INI (Sakura HUD). 0=off, 1=simple, 2=detail, 3=full

// Performance telemetry for the Swift HUD (PS1 core FPS / frame counts).
+ (double)perfFPS;
// CAMetalLayer present commits per wall second, derived in HUD from metalLayerDrawablePresentCount delta.
+ (unsigned long long)perfMetalLayerPresentCount;
+ (unsigned long long)perfNeuralCommitCount;
+ (double)perfVPS;
+ (double)perfSpeed;          // 0..1
// PS1 framebuffer base size when the core is ready. 0 when not running or unknown.
+ (unsigned)psBaseWidth;
+ (unsigned)psBaseHeight;
+ (unsigned)psPresentWidth;
+ (unsigned)psPresentHeight;

// ISO management
+ (nullable NSString *)currentISOPath;
+ (nonnull NSString *)isoDirectory;
+ (nonnull NSString *)documentsDirectory;
+ (nonnull NSArray<NSString *> *)availableISOs;

// [P44] ISO boot
+ (void)bootISO:(nonnull NSString *)isoName;

// [P44] BIOS management
+ (nonnull NSString *)biosDirectory;
+ (nonnull NSArray<NSString *> *)availableBIOSes;
+ (nonnull NSString *)defaultBIOSName;
+ (void)setDefaultBIOS:(nonnull NSString *)biosName;

// [P44] Favorites
+ (BOOL)isFavorite:(nonnull NSString *)isoName;
+ (void)setFavorite:(nonnull NSString *)isoName favorite:(BOOL)favorite;

// [P44] INI generic getter/setter
+ (int)getINIInt:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(int)def;
+ (BOOL)getINIBool:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(BOOL)def;
+ (float)getINIFloat:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(float)def;
+ (nonnull NSString *)getINIString:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(nonnull NSString *)def;
+ (BOOL)containsINIValue:(nonnull NSString *)section key:(nonnull NSString *)key;
+ (void)setINIInt:(nonnull NSString *)section key:(nonnull NSString *)key value:(int)value;
+ (void)setINIBool:(nonnull NSString *)section key:(nonnull NSString *)key value:(BOOL)value;
+ (void)setINIFloat:(nonnull NSString *)section key:(nonnull NSString *)key value:(float)value;
+ (void)setINIString:(nonnull NSString *)section key:(nonnull NSString *)key value:(nonnull NSString *)value;

// INI write-gate. when ON, every setINI* call becomes a no-op. SettingsStore
// flips this around its own init/reload so read-then-write-same-value round
// trips can't clobber the on-disk INI when the bridge sees a half-init
// settings layer.
+ (void)setINIWriteSuppressed:(BOOL)suppressed;
+ (BOOL)isINIWriteSuppressed;

// dump INI backing store state to the log: path, settings layer wired,
// file size. call at startup to diagnose settings-reset reports.
+ (void)logINIDiagnostics:(nonnull NSString *)tag;

// push INI changes into the running VM. serial queue with short debounce, safe from any thread.
+ (void)applyEmulatorSettings;
// same as apply without debounce. cancels pending debounced apply. use before boot or when disk must match RAM immediately.
+ (void)applyEmulatorSettingsImmediately;
// flush coalesced INI disk writes. call on resign-active or background.
+ (void)flushINIWritesSynchronously;
// re-read Sakura.ini into RAM after replacing the file on disk.
+ (void)reloadINIStoreFromDisk;
+ (void)applyRunningHostEmulationSpeedLive:(float)speed;

// host metal present aspect: 0 Auto, 1 16:9, 2 4:3, 3 Stretch, 4 Fill. updates running core immediately.
+ (void)setHostPresentAspectMode:(int)mode;

// [P44] VM lifecycle for menu flow
+ (BOOL)isEmulationRunning;
+ (BOOL)hasBIOS;
+ (BOOL)requestVMBoot;
+ (nullable NSString *)lastBootFailureReason;
+ (void)requestVMShutdown;

// in-game quick menu pause/resume.
+ (BOOL)isEmulationPaused;
+ (void)setEmulationPaused:(BOOL)paused;

// [P53] Gamepad button mapping
+ (void)startButtonCapture;
+ (void)stopButtonCapture;
+ (void)pollGamepadForCapture;  // call from main thread when VM is not running
+ (int)capturedButton;  // returns SDL_GamepadButton or -1
+ (void)setButtonMapping:(int)padButtonIndex toSDLButton:(int)sdlButton;
+ (int)getButtonMapping:(int)padButtonIndex;
+ (void)resetButtonMappings;
+ (void)resetKeyboardPadMappings;
// Sakura/KeyboardPad INI section. key like Cross, Up, L1. returns nil if absent.
+ (nullable NSString *)keyboardPadBindingForIniKey:(NSString *)iniKey;

// physical controller to emulator pump runs on display link. suppressed while menus capture input.
+ (void)setPhysicalPadToGameSuppressed:(BOOL)suppressed;
+ (BOOL)isPhysicalPadToGameSuppressed;
+ (void)pumpPhysicalGamepad;
+ (void)refreshPhysicalGamepadInputCache;

// gpu cadence duplicate-present while main-thread metal present is enabled. call from main-thread CADisplayLink at display refresh.
+ (void)gpuCadencePump;

// raw SDL-compatible gamepad button (SakuraGamepad / SDL_GamepadButton order). VM may be running.
+ (BOOL)isSDLGamepadButtonPressed:(int)sdlButton;

// first held button on the primary extended/micro gamepad, or -1. for settings capture.
+ (int)firstPressedSDLGamepadButton;

// serial if readable, else inode of the resolved payload path (same rule as metadata: .cue/.m3u/.ccd to data file) so alternate extensions do not duplicate.
+ (nonnull NSString *)libraryDedupKeyForISOPath:(nonnull NSString *)path;
// dedup key from a serial already scanned for isoPath. avoids reading the payload again during library dedup. must match isoSerial/title semantics for that row.
+ (nonnull NSString *)libraryDedupKeyForCachedSerial:(nullable NSString *)serial isoPath:(nonnull NSString *)path;
// st_dev/st_ino/size/mtime_nsec of SakuraResolveMetadataPayloadPath(isoPath), for serial cache validation. missing keys only if stat failed.
+ (nullable NSDictionary *)libraryPayloadIdentityForISOPath:(nonnull NSString *)path;

// game metadata (serial, title, region) from ISO. read-only scans, safe from library refresh while VM is running.
+ (nullable NSString *)isoSerialForPath:(nonnull NSString *)path;
+ (nullable NSString *)isoTitleForPath:(nonnull NSString *)path;
+ (nullable NSString *)isoRegionForPath:(nonnull NSString *)path;

// PS1 controller mode (0 = digital, 1 = dualshock). global default + per-game override.
+ (int)ps1ControllerMode;
+ (void)setPS1ControllerMode:(int)mode;
+ (int)ps1ControllerModeForGame:(nonnull NSString *)gameName;
+ (void)setPS1ControllerMode:(int)mode forGame:(nonnull NSString *)gameName;
+ (void)setPS1ControllerModeForCurrentISOOrGlobal:(int)mode;
// when the VM is running, [SakuraPS1Core shared] controllerMode. otherwise ps1ControllerModeForGame: with currentISOPath or global.
+ (int)ps1CoreControllerMode;

+ (int)ps1ControllerModeForPort:(int)port;
+ (void)setPS1ControllerMode:(int)mode forPort:(int)port;
+ (int)ps1ControllerModeForGame:(nonnull NSString *)gameName port:(int)port;
+ (void)setPS1ControllerMode:(int)mode forGame:(nonnull NSString *)gameName port:(int)port;
+ (void)setPS1ControllerModeForCurrentISOOrGlobal:(int)mode port:(int)port;
+ (int)ps1CoreControllerModeForPort:(int)port;

+ (void)pressAnalogModeToggle;

+ (CGFloat)screenPotentialEDRHeadroomApprox;
+ (BOOL)presentationHDRHeadroomLikelyAvailable;

+ (nullable UIImage *)processNeuralTextureArtUIImage:(nullable UIImage *)image;
+ (void)warmUpNeuralModelAsync;

@end

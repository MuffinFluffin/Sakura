#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#import "SakuraBridge.h"
#import "SakuraPS1Core.h"
#include "SakuraGamepadIOS.h"
#include "SakuraLogSink.h"

extern "C" void Sakura_IOS_SetScreenIsCaptured(bool captured);

UIView* g_gameRenderView = nil;

extern "C" void Sakura_SetSDLFullscreen(bool enabled) { (void)enabled; }

static volatile sig_atomic_t s_in_crash_sig = 0;
static void SakuraCrashSignalHandler(int sig, siginfo_t* si, void* /*ctx*/)
{
    if (s_in_crash_sig) { _exit(128 + sig); }
    s_in_crash_sig = 1;

    const char* name = "UNKNOWN";
    switch (sig) {
        case SIGABRT: name = "SIGABRT"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGTRAP: name = "SIGTRAP"; break;
        case SIGPIPE: name = "SIGPIPE"; break;
        default: break;
    }
    const double elapsed = Sakura_LogElapsedSecSignalSafe();
    char head[384];
    int nw = snprintf(head, sizeof(head),
        "[%10.4f] Sakura:Crash:Error: signal=%d(%s) code=%d addr=%p pid=%d tid=%llu\n",
        elapsed, sig, name, si ? si->si_code : 0,
        si ? si->si_addr : nullptr, (int)getpid(),
        (unsigned long long)(uintptr_t)pthread_self());
    if (nw > 0) {
        size_t len = (nw < (int)sizeof(head)) ? (size_t)nw : sizeof(head) - 1;
        (void)write(STDERR_FILENO, head, len);
    }

    void* frames[48];
    int n = backtrace(frames, 48);
    for (int i = 0; i < n; i++) {
        char ln[144];
        int nl = snprintf(ln, sizeof(ln), "[%10.4f] Sakura:Crash:Trace: #%02d %p\n",
            elapsed, i, frames[i]);
        if (nl > 0) {
            size_t len = (nl < (int)sizeof(ln)) ? (size_t)nl : sizeof(ln) - 1;
            (void)write(STDERR_FILENO, ln, len);
        }
    }
    fsync(STDERR_FILENO);

    struct sigaction sa{};
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, nullptr);
    raise(sig);
}

static void SakuraInstallCrashHandlers(void)
{
    struct sigaction sa{};
    sa.sa_sigaction = &SakuraCrashSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGABRT, SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGTRAP };
    for (int s : sigs) sigaction(s, &sa, nullptr);
}

static void SakuraObjCExceptionHandler(NSException* ex)
{
    Sakura_LogNative("ObjC", "Error", "uncaught name=%s reason=%s",
        ex.name.UTF8String ?: "(null)", ex.reason.UTF8String ?: "(null)");
    for (NSString* sym in ex.callStackSymbols) {
        Sakura_LogNative("ObjC", "Trace", "  %s", sym.UTF8String ?: "");
    }
    fsync(STDERR_FILENO);
}

extern "C" void Sakura_IOS_EarlyInit(void)
{
    Sakura_LogInit();

    NSString* documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[documentsDir stringByAppendingPathComponent:@"bios"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[documentsDir stringByAppendingPathComponent:@"Games"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[documentsDir stringByAppendingPathComponent:@"logs"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[documentsDir stringByAppendingPathComponent:@"Saves/PS1"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[documentsDir stringByAppendingPathComponent:@"SaveStates"] withIntermediateDirectories:YES attributes:nil error:nil];

    NSString* logsDir = [documentsDir stringByAppendingPathComponent:@"logs"];

    NSDateFormatter* stampFmt = [[NSDateFormatter alloc] init];
    stampFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stampFmt.timeZone = NSTimeZone.localTimeZone;
    stampFmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString* stampStr = [stampFmt stringFromDate:[NSDate date]];
    NSString* logPath = [logsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"sakura-%@.log", stampStr]];

    if (freopen(logPath.fileSystemRepresentation, "w", stderr) == NULL) {
        Sakura_LogNative("Log", "Error", "freopen stderr to session log failed");
    }
    if (dup2(fileno(stderr), fileno(stdout)) == -1) {
        Sakura_LogNative("Log", "Error", "dup2 stdout to stderr failed");
    }
    setvbuf(stderr, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);

    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    NSString* version  = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    Sakura_LogNative("Log", "Info", "unified=1 path=%s pid=%d", logPath.fileSystemRepresentation, getpid());
    Sakura_LogNative("Bundle", "Info", "identifier=%s", bundleID.UTF8String ?: "(null)");
    Sakura_LogNative("App", "Info", "version=%s build=%s_%s", version.UTF8String, __DATE__, __TIME__);

    {
        NSArray<NSString*>* entries = [fm contentsOfDirectoryAtPath:logsDir error:nil];
        NSMutableArray<NSString*>* logs = [NSMutableArray array];
        for (NSString* name in entries) {
            if ([name hasPrefix:@"sakura-"] && [name.pathExtension isEqualToString:@"log"]) {
                [logs addObject:name];
            }
        }
        [logs sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) { return [b compare:a]; }];
        for (NSUInteger i = 20; i < logs.count; i++) {
            [fm removeItemAtPath:[logsDir stringByAppendingPathComponent:logs[i]] error:nil];
        }
    }

    SakuraInstallCrashHandlers();
    NSSetUncaughtExceptionHandler(&SakuraObjCExceptionHandler);


#if DEBUG
    Sakura_LogNative("Dyld", "Debug", "map_begin");
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header* hdr = _dyld_get_image_header(i);
        Sakura_LogNative("Dyld", "Debug", "idx=%u addr=%p slide=%p path=%s", i, hdr, (void*)slide, name ? name : "");
    }
    Sakura_LogNative("Dyld", "Debug", "map_end");
#endif
    fflush(stderr);
}


extern "C" void Sakura_IOS_OnSceneReady(void)
{
    Sakura_IOS_SetScreenIsCaptured([UIScreen mainScreen].isCaptured);

    static std::atomic<bool> s_sessionPrimed{false};
    if (!s_sessionPrimed.exchange(true)) {
        SakuraGamepadIOS_Start();

        NSError* avErr = nil;
        AVAudioSession* session = AVAudioSession.sharedInstance;
        if (![session setCategory:AVAudioSessionCategoryPlayback
                      mode:AVAudioSessionModeDefault
                   options:AVAudioSessionCategoryOptionAllowBluetoothA2DP
                     error:&avErr]) {
            Sakura_LogNative("Audio", "Warning", "AVAudioSession setCategory failed: %s",
                avErr.localizedDescription.UTF8String ?: "(null)");
        }
        if (![session setActive:YES error:&avErr]) {
            Sakura_LogNative("Audio", "Warning", "AVAudioSession setActive failed: %s",
                avErr.localizedDescription.UTF8String ?: "(null)");
        }
    }

}

extern "C" void Sakura_IOS_ConfigureGameAudioSession(double coreSampleRate)
{
    AVAudioSession* session = AVAudioSession.sharedInstance;
    NSError* err = nil;

    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionAllowBluetoothA2DP
                   error:&err];

    const double pref = coreSampleRate > 1.0 ? coreSampleRate : 44100.0;
    err = nil;
    if (![session setPreferredSampleRate:pref error:&err]) {
        Sakura_LogNative("Audio", "Warning", "preferredSampleRate (game): %s",
            err.localizedDescription.UTF8String ?: "(null)");
    }

    err = nil;
    const NSTimeInterval ioDur = pref >= 47900.0 ? 0.004 : 0.005;
    if (![session setPreferredIOBufferDuration:ioDur error:&err]) {
        Sakura_LogNative("Audio", "Warning", "preferred IO buffer (game): %s",
            err.localizedDescription.UTF8String ?: "(null)");
    }
    err = nil;
    if (![session setActive:YES error:&err]) {
        Sakura_LogNative("Audio", "Warning", "audio session activate (game): %s",
            err.localizedDescription.UTF8String ?: "(null)");
    }
}

extern "C" void Sakura_IOS_SetGameRenderView(void* view)
{
    g_gameRenderView = view ? (__bridge UIView*)view : nil;
    [[SakuraPS1Core shared] setRenderView:g_gameRenderView];
}

extern "C" void Sakura_IOS_NotifyDisplayResize(int width, int height, float scale)
{
    if (width <= 0 || height <= 0) return;
    [[SakuraPS1Core shared] notifyDisplayResizeWithWidth:width height:height scale:scale];
}

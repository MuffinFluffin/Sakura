#import "SakuraBridge.h"
#import "SakuraPS1Core.h"
#import "SakuraNeuralUpscale.h"
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <os/lock.h>

#include <atomic>
#include <sys/stat.h>

#include "SakuraGamepadButtons.h"
#include "SakuraGamepadIOS.h"
#include "SakuraLogSink.h"

extern UIView* g_gameRenderView;

void SakuraLogUnified(NSString *subsystem, NSString *level, NSString *message)
{
    const char *a = (subsystem != nil && subsystem.length > 0) ? subsystem.UTF8String : "Core";
    const char *lv = (level != nil && level.length > 0) ? level.UTF8String : "Info";
    NSString *msg = message ?: @"";
    const char *m = msg.UTF8String ?: "";
    Sakura_LogNative(a, lv, "%s", m);
}

static NSString* const SakuraINIFilename = @"Sakura.ini";
static NSString* const SakuraNotificationVMShutdown = @"SakuraVMDidShutdown";
static NSString* const SakuraNotificationVibrate = @"SakuraVibrationUpdate";
NSString* const SakuraNotificationPS1ControllerModeChanged = @"SakuraPS1ControllerModeChanged";
static NSString* const SakuraPadKeyButton = @"Button%d";
static NSString* const SakuraPadSection = @"GamepadMapping";
static NSString* const SakuraKeyboardPadSection = @"Sakura/KeyboardPad";

#if TARGET_OS_IPHONE
static BOOL SakuraPresentationHdrDrawableAvailable(void)
{
    if (@available(iOS 16.0, *))
        return [UIScreen mainScreen].potentialEDRHeadroom > 1.02;
    return NO;
}
#else
static BOOL SakuraPresentationHdrDrawableAvailable(void) { return NO; }
#endif

static NSString* const SakuraCueExt = @"cue";
static NSString* const SakuraCueTypoExt = @"cua";
static NSString* const SakuraLargeBinExt = @"bin";
static const unsigned long long SakuraLargeBinThreshold = 50ull * 1024ull * 1024ull;

// maps settings INI texture filter preset to beetle_psx_* filter string for cores that honor it.

static NSString *SakuraINIBeetleTextureFilterOption(int preset)
{
    switch (preset) {
        case 1: return @"bilinear";
        case 2: return @"3-point";
        case 3: return @"SABR";
        case 4: return @"xBR";
        case 5:
        case 6:
        case 7:
            return @"nearest";
        default:
            return @"nearest";
    }
}

static NSString *SakuraINIBeetleInternalResolution(float mult)
{
    if (mult >= 14.f) return @"16x";
    if (mult >= 6.f) return @"8x";
    if (mult >= 3.f) return @"4x";
    if (mult >= 1.5f) return @"2x";
    return @"1x(native)";
}

static void SakuraApplyBeetlePSXLibretroVariable(SakuraPS1Core *core, NSString *suffix, NSString *value)
{
    if (!core || suffix.length == 0) return;
    NSString *sw = [NSString stringWithFormat:@"beetle_psx_%@", suffix];
    NSString *hw = [NSString stringWithFormat:@"beetle_psx_hw_%@", suffix];
    [core setLibretroVariable:sw value:value];
    [core setLibretroVariable:hw value:value];
}

static NSDate* g_lastNVMSaveDate = nil;
static std::atomic<bool> g_iniWriteSuppressed{false};

static dispatch_queue_t SakuraSettingsApplyQueue(void)
{
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("sakura.settings.apply", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static dispatch_block_t g_pendingDebouncedApplyBlock = nil;

@interface SakuraINIStore : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSString*>*>* sections;
@property(nonatomic, copy) NSString* path;
@property(nonatomic) BOOL dirty;
+ (instancetype)shared;
- (NSString*)getString:(NSString*)section key:(NSString*)key def:(NSString*)def;
- (int)getInt:(NSString*)section key:(NSString*)key def:(int)def;
- (BOOL)getBool:(NSString*)section key:(NSString*)key def:(BOOL)def;
- (float)getFloat:(NSString*)section key:(NSString*)key def:(float)def;
- (BOOL)contains:(NSString*)section key:(NSString*)key;
- (void)setString:(NSString*)value section:(NSString*)section key:(NSString*)key;
- (void)setInt:(int)value section:(NSString*)section key:(NSString*)key;
- (void)setBool:(BOOL)value section:(NSString*)section key:(NSString*)key;
- (void)setFloat:(float)value section:(NSString*)section key:(NSString*)key;
- (void)removeSection:(NSString*)section;
- (void)flushWritesSynchronously;
- (void)reloadFromDisk;
- (void)load;
@end

@implementation SakuraINIStore {
    os_unfair_lock _sectionsLock;
    dispatch_queue_t _persistQueue;
    dispatch_block_t _pendingPersistBlock;
}

+ (instancetype)shared {
    static SakuraINIStore* s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[SakuraINIStore alloc] init];
        [s load];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;
    _sectionsLock = OS_UNFAIR_LOCK_INIT;
    _persistQueue = dispatch_queue_create("sakura.ini.persist", DISPATCH_QUEUE_SERIAL);
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    self.path = [docs stringByAppendingPathComponent:SakuraINIFilename];
    self.sections = [NSMutableDictionary dictionary];
    return self;
}

- (void)scheduleDebouncedPersist {
    dispatch_async(_persistQueue, ^{
        if (self->_pendingPersistBlock) {
            dispatch_block_cancel(self->_pendingPersistBlock);
            self->_pendingPersistBlock = nil;
        }
        SakuraINIStore* pin = self;
        dispatch_block_t blk = dispatch_block_create(DISPATCH_BLOCK_ASSIGN_CURRENT, ^{
            [pin performSaveToDiskIfDirty];
        });
        self->_pendingPersistBlock = blk;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), self->_persistQueue, blk);
    });
}

- (void)performSaveToDiskIfDirty {
    NSMutableString* out = nil;
    NSString* pathCopy = nil;
    BOOL wasDirty = NO;
    os_unfair_lock_lock(&_sectionsLock);
    wasDirty = self.dirty;
    if (!wasDirty) {
        os_unfair_lock_unlock(&_sectionsLock);
        return;
    }
    out = [NSMutableString string];
    NSArray* sectionNames = [self.sections.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* section in sectionNames) {
        [out appendFormat:@"[%@]\n", section];
        NSDictionary* d = self.sections[section];
        NSArray* keys = [d.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString* k in keys) {
            [out appendFormat:@"%@ = %@\n", k, d[k]];
        }
        [out appendString:@"\n"];
    }
    pathCopy = [self.path copy];
    os_unfair_lock_unlock(&_sectionsLock);

    NSError* err = nil;
    BOOL ok = [out writeToFile:pathCopy atomically:YES encoding:NSUTF8StringEncoding error:&err];
    os_unfair_lock_lock(&_sectionsLock);
    if (ok)
        self.dirty = NO;
    os_unfair_lock_unlock(&_sectionsLock);
    if (!ok)
        SakuraLogUnified(@"INI", @"Error", [NSString stringWithFormat:@"SakuraINIStore save failed: %@", err]);
}

- (void)flushWritesSynchronously {
    dispatch_sync(_persistQueue, ^{
        if (self->_pendingPersistBlock) {
            dispatch_block_cancel(self->_pendingPersistBlock);
            self->_pendingPersistBlock = nil;
        }
        [self performSaveToDiskIfDirty];
    });
}

- (NSString*)getString:(NSString*)section key:(NSString*)key def:(NSString*)def {
    os_unfair_lock_lock(&_sectionsLock);
    NSString* v = self.sections[section][key];
    os_unfair_lock_unlock(&_sectionsLock);
    return v ?: def;
}
- (int)getInt:(NSString*)section key:(NSString*)key def:(int)def {
    os_unfair_lock_lock(&_sectionsLock);
    NSString* v = self.sections[section][key];
    os_unfair_lock_unlock(&_sectionsLock);
    return v ? (int)v.intValue : def;
}
- (BOOL)getBool:(NSString*)section key:(NSString*)key def:(BOOL)def {
    os_unfair_lock_lock(&_sectionsLock);
    NSString* v = self.sections[section][key];
    os_unfair_lock_unlock(&_sectionsLock);
    if (!v)
        return def;
    return [v.lowercaseString isEqualToString:@"true"] || [v isEqualToString:@"1"];
}
- (float)getFloat:(NSString*)section key:(NSString*)key def:(float)def {
    os_unfair_lock_lock(&_sectionsLock);
    NSString* v = self.sections[section][key];
    os_unfair_lock_unlock(&_sectionsLock);
    return v ? v.floatValue : def;
}
- (BOOL)contains:(NSString*)section key:(NSString*)key {
    os_unfair_lock_lock(&_sectionsLock);
    BOOL ok = (self.sections[section][key] != nil);
    os_unfair_lock_unlock(&_sectionsLock);
    return ok;
}
- (void)setString:(NSString*)value section:(NSString*)section key:(NSString*)key {
    os_unfair_lock_lock(&_sectionsLock);
    NSMutableDictionary* d = self.sections[section];
    if (!d) {
        d = [NSMutableDictionary dictionary];
        self.sections[section] = d;
    }
    d[key] = [value copy];
    self.dirty = YES;
    os_unfair_lock_unlock(&_sectionsLock);
    [self scheduleDebouncedPersist];
}
- (void)setInt:(int)value section:(NSString*)section key:(NSString*)key {
    [self setString:[NSString stringWithFormat:@"%d", value] section:section key:key];
}
- (void)setBool:(BOOL)value section:(NSString*)section key:(NSString*)key {
    [self setString:value ? @"true" : @"false" section:section key:key];
}
- (void)setFloat:(float)value section:(NSString*)section key:(NSString*)key {
    [self setString:[NSString stringWithFormat:@"%g", value] section:section key:key];
}
- (void)removeSection:(NSString*)section {
    os_unfair_lock_lock(&_sectionsLock);
    [self.sections removeObjectForKey:section];
    self.dirty = YES;
    os_unfair_lock_unlock(&_sectionsLock);
    [self scheduleDebouncedPersist];
}

- (void)reloadFromDisk {
    dispatch_sync(_persistQueue, ^{
        if (self->_pendingPersistBlock) {
            dispatch_block_cancel(self->_pendingPersistBlock);
            self->_pendingPersistBlock = nil;
        }
        NSError* err = nil;
        NSString* text = [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:&err];
        os_unfair_lock_lock(&_sectionsLock);
        [self.sections removeAllObjects];
        if (text.length > 0) {
            __block NSString* current = nil;
            [text enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
                (void)stop;
                NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (trimmed.length == 0 || [trimmed hasPrefix:@";"] || [trimmed hasPrefix:@"#"])
                    return;
                if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
                    current = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
                    NSMutableDictionary* d = self.sections[current];
                    if (!d) {
                        d = [NSMutableDictionary dictionary];
                        self.sections[current] = d;
                    }
                    return;
                }
                if (!current)
                    return;
                NSRange eq = [trimmed rangeOfString:@"="];
                if (eq.location == NSNotFound)
                    return;
                NSString* key =
                    [[trimmed substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString* val =
                    [[trimmed substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSMutableDictionary* d = self.sections[current];
                if (!d) {
                    d = [NSMutableDictionary dictionary];
                    self.sections[current] = d;
                }
                d[key] = val;
            }];
        }
        self.dirty = NO;
        os_unfair_lock_unlock(&_sectionsLock);
    });
}

- (void)load {
    [self reloadFromDisk];
}

@end

static BOOL SakuraIsDirectGameExt(NSString* ext)
{
    if (ext.length == 0) return NO;
    static NSSet<NSString*>* exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [[NSSet alloc] initWithObjects:
            @"iso", @"img", @"chd", @"pbp", @"m3u", @"toc", @"ccd",
            @"mds", @"mdf", @"nrg", @"cdi", @"psx", @"ecm",
            @"cso", @"zso", @"gz",
            SakuraCueExt, SakuraCueTypoExt,
            nil];
    });
    return [exts containsObject:ext];
}

static NSArray<NSString*>* SakuraCueReferencedFiles(NSString* cuePath)
{
    NSError* error = nil;
    NSString* text = [NSString stringWithContentsOfFile:cuePath encoding:NSUTF8StringEncoding error:&error];
    if (!text) text = [NSString stringWithContentsOfFile:cuePath encoding:NSISOLatin1StringEncoding error:nil];
    if (!text) return @[];
    NSMutableArray<NSString*>* refs = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
        (void)stop;
        NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length < 6 || [trimmed rangeOfString:@"FILE " options:NSCaseInsensitiveSearch].location != 0) return;
        NSRange firstQuote = [trimmed rangeOfString:@"\""];
        if (firstQuote.location != NSNotFound) {
            NSUInteger after = firstQuote.location + firstQuote.length;
            NSRange rest = NSMakeRange(after, trimmed.length - after);
            NSRange secondQuote = [trimmed rangeOfString:@"\"" options:0 range:rest];
            if (secondQuote.location != NSNotFound) {
                NSString* name = [trimmed substringWithRange:NSMakeRange(after, secondQuote.location - after)];
                if (name.length > 0) [refs addObject:name.lastPathComponent];
                return;
            }
        }
        NSArray<NSString*>* pieces = [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSString*>* nonEmpty = [NSMutableArray array];
        for (NSString* p in pieces) if (p.length > 0) [nonEmpty addObject:p];
        if (nonEmpty.count >= 2) [refs addObject:((NSString*)nonEmpty[1]).lastPathComponent];
    }];
    return refs;
}

static NSString* SakuraNormalizedCueName(NSString* file)
{
    if (![file.pathExtension.lowercaseString isEqualToString:SakuraCueTypoExt]) return file;
    return [file.stringByDeletingPathExtension stringByAppendingPathExtension:SakuraCueExt];
}

static BOOL SakuraCueHasExistingRef(NSString* dir, NSString* cuePath)
{
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* ref in SakuraCueReferencedFiles(cuePath)) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:ref]]) return YES;
    }
    return NO;
}

// Pick the largest sibling .bin > threshold not already claimed by another cue.
static NSString* SakuraPickOrphanBin(NSString* dir, NSArray<NSString*>* siblings, NSSet<NSString*>* claimedLower)
{
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* best = nil;
    unsigned long long bestSize = 0;
    for (NSString* sib in siblings) {
        if (![sib.pathExtension.lowercaseString isEqualToString:SakuraLargeBinExt]) continue;
        if ([claimedLower containsObject:sib.lowercaseString]) continue;
        NSDictionary* attrs = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:sib] error:nil];
        unsigned long long size = [attrs fileSize];
        if (size <= SakuraLargeBinThreshold) continue;
        if (size > bestSize) { best = sib; bestSize = size; }
    }
    return best;
}

// Replace the first FILE line and drop extras, pointing the cue at binFile.
// If the cue has no FILE line at all, write a fresh single-track template.
static BOOL SakuraRewriteCueToBin(NSString* cuePath, NSString* binFile)
{
    NSError* err = nil;
    NSString* text = [NSString stringWithContentsOfFile:cuePath encoding:NSUTF8StringEncoding error:&err];
    if (!text) text = [NSString stringWithContentsOfFile:cuePath encoding:NSISOLatin1StringEncoding error:nil];
    NSString* template_ = [NSString stringWithFormat:@"FILE \"%@\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n", binFile];
    if (text.length == 0) {
        return [template_ writeToFile:cuePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    BOOL replaced = NO;
    for (NSString* raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString* trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        BOOL isFile = trimmed.length >= 5 && [trimmed rangeOfString:@"FILE " options:NSCaseInsensitiveSearch].location == 0;
        if (isFile) {
            if (!replaced) {
                [out addObject:[NSString stringWithFormat:@"FILE \"%@\" BINARY", binFile]];
                replaced = YES;
            }
            continue;
        }
        [out addObject:raw];
    }
    if (!replaced) {
        return [template_ writeToFile:cuePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return [[out componentsJoinedByString:@"\n"] writeToFile:cuePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Create <basename>.cue beside a loose .bin so mednafen can load it and the bin
// stops showing as a second library row beside its real disc.
static BOOL SakuraEnsureCueForLooseBin(NSString* dir, NSString* binFile)
{
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* cueName = [binFile.stringByDeletingPathExtension stringByAppendingPathExtension:SakuraCueExt];
    NSString* cuePath = [dir stringByAppendingPathComponent:cueName];
    if ([fm fileExistsAtPath:cuePath]) return NO;
    NSString* body = [NSString stringWithFormat:@"FILE \"%@\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n", binFile];
    return [body writeToFile:cuePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString* SakuraResolveGamePath(NSString* gameName)
{
    if (gameName.length == 0) return nil;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray<NSString*>* dirs = @[
        [docs stringByAppendingPathComponent:@"Games"],
        [docs stringByAppendingPathComponent:@"iso"],
        docs,
    ];
    // gameName may be a relative path (e.g. "FF7/Disc1.cue") from the
    // recursive scan; stringByAppendingPathComponent handles slashes.
    for (NSString* dir in dirs) {
        NSString* path = [dir stringByAppendingPathComponent:gameName];
        if ([fm fileExistsAtPath:path]) return path;
    }
    // Fallback: legacy callers may pass a bare basename for a file that now
    // lives in a subfolder. Walk Games/ once looking for a matching leaf.
    NSString* gamesDir = [docs stringByAppendingPathComponent:@"Games"];
    NSString* leaf = gameName.lastPathComponent;
    NSDirectoryEnumerator<NSString*>* en = [fm enumeratorAtPath:gamesDir];
    for (NSString* sub in en) {
        if ([sub.lastPathComponent caseInsensitiveCompare:leaf] == NSOrderedSame) {
            return [gamesDir stringByAppendingPathComponent:sub];
        }
    }
    return nil;
}

static BOOL SakuraIsKnownPS1SerialPrefix(NSString* prefix)
{
    static NSSet<NSString*>* prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = [[NSSet alloc] initWithObjects:
            @"CPCS", @"ESPM", @"HPS", @"LSP", @"PAPX", @"PBPX", @"PCPD", @"PCPX",
            @"PEPX", @"PUPX", @"SCAJ", @"SCED", @"SCES", @"SCPS", @"SIPS", @"SLED",
            @"SLES", @"SLKA", @"SLPM", @"SLPS", @"SLUS", @"SCUS", nil];
    });
    return [prefixes containsObject:prefix.uppercaseString];
}

static NSString* SakuraNormalizePS1Serial(NSString* raw)
{
    if (raw.length == 0) return nil;
    NSString* upper = raw.uppercaseString;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"([A-Z]{3,5})[\\s_\\-\\.]*([0-9]{3})[\\s_\\-\\.]*([0-9]{2})"
                                                                         options:0
                                                                           error:nil];
    NSTextCheckingResult* m = [re firstMatchInString:upper options:0 range:NSMakeRange(0, upper.length)];
    if (!m || m.numberOfRanges < 4) return nil;

    NSString* prefix = [upper substringWithRange:[m rangeAtIndex:1]];
    if (!SakuraIsKnownPS1SerialPrefix(prefix)) return nil;

    NSString* first = [upper substringWithRange:[m rangeAtIndex:2]];
    NSString* second = [upper substringWithRange:[m rangeAtIndex:3]];
    return [NSString stringWithFormat:@"%@-%@%@", prefix, first, second];
}

static NSString* SakuraFirstExistingCuePayload(NSString* cuePath)
{
    NSString* dir = cuePath.stringByDeletingLastPathComponent;
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* ref in SakuraCueReferencedFiles(cuePath)) {
        NSString* candidate = [dir stringByAppendingPathComponent:ref];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSString* SakuraFirstM3UEntry(NSString* m3uPath)
{
    NSError* error = nil;
    NSString* text = [NSString stringWithContentsOfFile:m3uPath encoding:NSUTF8StringEncoding error:&error];
    if (!text) text = [NSString stringWithContentsOfFile:m3uPath encoding:NSISOLatin1StringEncoding error:nil];
    if (!text) return nil;

    NSString* dir = m3uPath.stringByDeletingLastPathComponent;
    __block NSString* first = nil;
    [text enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) return;
        NSString* candidate = [dir stringByAppendingPathComponent:trimmed];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            first = candidate;
            *stop = YES;
        }
    }];
    return first;
}

static NSString* SakuraResolveMetadataPayloadPath(NSString* path)
{
    if (path.length == 0) return nil;
    NSString* ext = path.pathExtension.lowercaseString;
    NSFileManager* fm = NSFileManager.defaultManager;

    if ([ext isEqualToString:SakuraCueExt] || [ext isEqualToString:SakuraCueTypoExt]) {
        NSString* payload = SakuraFirstExistingCuePayload(path);
        return payload ?: path;
    }
    if ([ext isEqualToString:@"m3u"]) {
        NSString* entry = SakuraFirstM3UEntry(path);
        return entry ? SakuraResolveMetadataPayloadPath(entry) : path;
    }
    if ([ext isEqualToString:@"ccd"]) {
        NSString* base = path.stringByDeletingPathExtension;
        for (NSString* candidate in @[[base stringByAppendingPathExtension:@"img"],
                                      [base stringByAppendingPathExtension:@"bin"]]) {
            if ([fm fileExistsAtPath:candidate]) return candidate;
        }
    }
    return path;
}

static NSString* SakuraFindPS1SerialInText(NSString* text)
{
    if (text.length == 0) return nil;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"[A-Z]{3,5}[\\s_\\-\\.]*[0-9]{3}[\\s_\\-\\.]*[0-9]{2}"
                                                                         options:NSRegularExpressionCaseInsensitive
                                                                           error:nil];
    NSArray<NSTextCheckingResult*>* matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult* m in matches) {
        NSString* serial = SakuraNormalizePS1Serial([text substringWithRange:m.range]);
        if (serial.length > 0) return serial;
    }
    return nil;
}

static NSString* SakuraScanPS1SerialFromFile(NSString* path)
{
    NSString* payload = SakuraResolveMetadataPayloadPath(path);
    if (payload.length == 0) return nil;

    NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:payload error:nil];
    unsigned long long fileSize = 0;
    if (attrs) fileSize = [attrs fileSize];

    NSFileHandle* fh = [NSFileHandle fileHandleForReadingAtPath:payload];
    if (!fh) return nil;
    NSMutableData* acc = [[NSMutableData alloc] init];

    NSString* (^blobSerial)(NSData*) = ^NSString* (NSData* mdata) {
        if (!mdata || mdata.length == 0) return nil;
        NSString* t =
            [[[NSString alloc] initWithData:mdata encoding:NSISOLatin1StringEncoding] autorelease];
        if (t.length == 0) return nil;
        return SakuraFindPS1SerialInText(t);
    };

    NSString* (^readChunk)(NSUInteger) =
        ^NSString* (NSUInteger maxLen) {
        if (!fh || maxLen == 0) return nil;
        @try {
            NSData* d = [fh readDataOfLength:maxLen];
            if (d.length > 0) [acc appendData:d];
        } @catch (NSException*) {
            return nil;
        }
        return blobSerial(acc);
    };

    @try {
#if TARGET_OS_IPHONE
        const NSUInteger slice = (NSUInteger)(1024u * 1024u);
        NSUInteger firstNeed = slice;
        if (fileSize > 0) firstNeed = (NSUInteger)MIN((unsigned long long)slice, fileSize);
        NSString* hit = readChunk(firstNeed);
        if (hit.length > 0) {
            @try {
                [fh closeFile];
            } @catch (NSException*) {
            }
            [acc release];
            return hit;
        }
        if (fileSize > firstNeed) {
            @try {
                [fh seekToFileOffset:firstNeed];
            } @catch (NSException*) {
                @try {
                    [fh closeFile];
                } @catch (NSException*) {
                }
                [acc release];
                return SakuraFindPS1SerialInText(payload.lastPathComponent);
            }
            NSUInteger remaining = fileSize > firstNeed ? (NSUInteger)(fileSize - firstNeed) : 0;
            NSUInteger secondChunk = MIN(slice, remaining);
            hit = readChunk(secondChunk);
            if (hit.length > 0) {
                @try {
                    [fh closeFile];
                } @catch (NSException*) {
                }
                [acc release];
                return hit;
            }
        }
        @try {
            [fh closeFile];
        } @catch (NSException*) {
        }
#else
        const NSUInteger desktopCap = (NSUInteger)(4u * 1024u * 1024u);
        NSUInteger desktopNeed = desktopCap;
        if (fileSize > 0) desktopNeed = (NSUInteger)MIN((unsigned long long)desktopCap, fileSize);
        NSString* hit = readChunk(desktopNeed);
        if (hit.length > 0) {
            @try {
                [fh closeFile];
            } @catch (NSException*) {
            }
            [acc release];
            return hit;
        }
        @try {
            [fh closeFile];
        } @catch (NSException*) {
        }
#endif
    } @catch (NSException*) {
        @try {
            [fh closeFile];
        } @catch (NSException*) {
        }
        [acc release];
        return SakuraFindPS1SerialInText(payload.lastPathComponent);
    }

    NSString* fallback = SakuraFindPS1SerialInText(payload.lastPathComponent);
    [acc release];
    return fallback;
}

static NSString* SakuraCleanGameTitleFromFilename(NSString* path)
{
    NSString* title = path.lastPathComponent.stringByDeletingPathExtension;
    if (title.length == 0) return nil;

    NSRegularExpression* serialRe = [NSRegularExpression regularExpressionWithPattern:@"\\b[A-Z]{3,5}[\\s_\\-\\.]*[0-9]{3}[\\s_\\-\\.]*[0-9]{2}\\b"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    title = [serialRe stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    NSRegularExpression* suffixRe = [NSRegularExpression regularExpressionWithPattern:@"\\s*[\\(\\[][^\\)\\]]*(USA|Europe|Japan|World|Disc|Track|Rev|Beta|Demo|En,|v[0-9]|NTSC|PAL)[^\\)\\]]*[\\)\\]]\\s*$"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    while (true) {
        NSString* next = [suffixRe stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
        if ([next isEqualToString:title]) break;
        title = next;
    }
    title = [title stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return title.length > 0 ? title : nil;
}

static NSString* SakuraSelectedBIOSPath(void)
{
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* biosDir = [SakuraBridge biosDirectory];
    NSString* configured = [SakuraBridge defaultBIOSName];
    if (configured.length > 0) {
        NSString* path = [biosDir stringByAppendingPathComponent:configured.lastPathComponent];
        if ([fm fileExistsAtPath:path]) return path;
    }
    for (NSString* name in [SakuraBridge availableBIOSes]) {
        NSString* path = [biosDir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static NSString *g_lastBootFailureReason = nil;

static void SakuraBridgeApplyEmulatorSettingsCoreAndBeetleFromINI(void)
{
    SakuraPS1Core *core = [SakuraPS1Core shared];

    NSString *aspectStr = [SakuraBridge getINIString:@"EmuCore/GS" key:@"AspectRatio" defaultValue:@"4:3"];
    int aspectIdx = 2;
    if ([aspectStr isEqualToString:@"Fill"]) aspectIdx = 3;
    core.aspectRatio = aspectIdx;
    core.fastBoot = [SakuraBridge getINIBool:@"GameISO" key:@"FastBoot" defaultValue:NO];
    const float upscaleMult = [SakuraBridge getINIFloat:@"EmuCore/GS" key:@"upscale_multiplier" defaultValue:1.0f];
    core.upscaleMultiplier = upscaleMult;
    core.metalFXTexture = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"metalfx_texture" defaultValue:NO];
    core.metalFXTemporalDisplay = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"metalfx_temporal_display" defaultValue:NO];
    BOOL mainThreadMetalPresent = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"split_present" defaultValue:YES];
    core.mainThreadMetalPresentEnabled = mainThreadMetalPresent;
    core.videotoolboxFrameFeatures = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"videotoolbox_ios26_frame_features" defaultValue:YES];
    core.metalFXFrameInterpolation = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"metalfx_frame_interpolation" defaultValue:NO];
    int emuFilterPreset = (int)[SakuraBridge getINIInt:@"EmuCore/GS" key:@"filter" defaultValue:0];
    if (emuFilterPreset < 0) emuFilterPreset = 0;
    if (emuFilterPreset > 7) emuFilterPreset = 7;
    core.textureFilter = emuFilterPreset;
    core.fxaa = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"fxaa" defaultValue:NO];
    {
        int smaaQ = (int)[SakuraBridge getINIInt:@"EmuCore/GS" key:@"smaa_quality" defaultValue:0];
        if (smaaQ < 0) smaaQ = 0;
        if (smaaQ > 4) smaaQ = 4;
        core.smaaQuality = smaaQ;
        core.smaaLinearSpace = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"smaa_linear" defaultValue:YES];
        core.smaaAdaptiveThreshold = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"smaa_adaptive" defaultValue:YES];
        core.smaaPixelArtMode = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"smaa_pixel_art" defaultValue:YES];
        float thr = [SakuraBridge getINIFloat:@"EmuCore/GS" key:@"smaa_threshold_scale" defaultValue:1.0f];
        if (thr < 0.1f) thr = 0.1f;
        if (thr > 4.0f) thr = 4.0f;
        core.smaaThresholdScale = thr;
        float tol = [SakuraBridge getINIFloat:@"EmuCore/GS" key:@"smaa_pixel_art_tol" defaultValue:0.04f];
        if (tol < 0.001f) tol = 0.001f;
        if (tol > 0.2f) tol = 0.2f;
        core.smaaPixelArtTolerance = tol;
    }

    core.casMode = (int)[SakuraBridge getINIInt:@"EmuCore/GS" key:@"CASMode" defaultValue:0];
    core.casSharpness = (int)[SakuraBridge getINIInt:@"EmuCore/GS" key:@"CASSharpness" defaultValue:50];
    core.autoSwitchControllerMode = [SakuraBridge getINIBool:@"Controller" key:@"AutoSwitch" defaultValue:NO];

    SakuraApplyBeetlePSXLibretroVariable(core, @"internal_resolution", SakuraINIBeetleInternalResolution(upscaleMult));
    SakuraApplyBeetlePSXLibretroVariable(core, @"filter", SakuraINIBeetleTextureFilterOption(emuFilterPreset));
    NSString *pgxp = [SakuraBridge getINIString:@"PSX/Core" key:@"PGXPMode" defaultValue:@"disabled"];
    if ([pgxp isEqualToString:@"off"] || pgxp.length == 0)
        pgxp = @"disabled";
    NSSet *allowedPGXP = [NSSet setWithArray:@[ @"disabled", @"memory only", @"memory + CPU" ]];
    if (![allowedPGXP containsObject:pgxp])
        pgxp = @"disabled";
    if ([pgxp isEqualToString:@"memory + CPU"]) {
        NSString *gp = [SakuraBridge currentISOPath];
        if (gp.length > 0) {
            NSString *raw = [SakuraBridge isoSerialForPath:gp];
            NSString *norm = SakuraNormalizePS1Serial(raw ?: @"");
            NSString *key = ((norm.length > 0) ? norm : raw).uppercaseString;
            static NSSet<NSString *> *s_pgxpNoCpuSerials = nil;
            static dispatch_once_t s_pgxpNoCpuOnce;
            dispatch_once(&s_pgxpNoCpuOnce, ^{
                s_pgxpNoCpuSerials = [[NSSet alloc] initWithObjects:
                    @"SLPS-00001", @"SCUS-94300", @"SCES-00001",
                    @"SLPS-00150", @"SLUS-00214", @"SCES-00242", @"SLPS-91028",
                    @"SLPS-01798", @"SLPS-01800", @"SLPS-91463", @"SCPS-45356",
                    @"SLUS-00797", @"SCES-01706", @"SCED-01832",
                    nil];
            });
            if (key.length > 0 && [s_pgxpNoCpuSerials containsObject:key])
                pgxp = @"memory only";
        }
    }
    SakuraApplyBeetlePSXLibretroVariable(core, @"pgxp_mode", pgxp);
    NSString *pgxpTex = [pgxp isEqualToString:@"disabled"] ? @"disabled" : @"enabled";
    SakuraApplyBeetlePSXLibretroVariable(core, @"pgxp_texture", pgxpTex);
    NSString *pgxp2d = [pgxp isEqualToString:@"disabled"] ? @"disabled" : @"4px";
    SakuraApplyBeetlePSXLibretroVariable(core, @"pgxp_2d_tol", pgxp2d);

    BOOL widescreen = [SakuraBridge getINIBool:@"PSX/Core" key:@"WidescreenHack" defaultValue:NO];
    SakuraApplyBeetlePSXLibretroVariable(core, @"widescreen_hack", widescreen ? @"enabled" : @"disabled");

    NSString *dither = [SakuraBridge getINIString:@"PSX/Core" key:@"DitherMode" defaultValue:@"1x(native)"];
    if ([dither isEqualToString:@"off"])
        dither = @"disabled";
    SakuraApplyBeetlePSXLibretroVariable(core, @"dither_mode", dither);

    NSString *colorDepth = [SakuraBridge getINIString:@"PSX/Core" key:@"InternalColorDepth" defaultValue:@"dithered 16bpp (native)"];
    SakuraApplyBeetlePSXLibretroVariable(core, @"internal_color_depth", colorDepth);

    BOOL frameDup = [SakuraBridge getINIBool:@"PSX/Core" key:@"FrameDuping" defaultValue:YES];
    SakuraApplyBeetlePSXLibretroVariable(core, @"frame_duping", frameDup ? @"enabled" : @"disabled");

    NSString *cpuFreq = [SakuraBridge getINIString:@"PSX/Core" key:@"CPUFreqScale" defaultValue:@"100%"];
    SakuraApplyBeetlePSXLibretroVariable(core, @"cpu_freq_scale", cpuFreq);

    NSString *cdAccess = [SakuraBridge getINIString:@"PSX/Core" key:@"CDAccessMethod" defaultValue:@"sync"];
    SakuraApplyBeetlePSXLibretroVariable(core, @"cd_access_method", cdAccess);

    NSString *deint = [SakuraBridge getINIString:@"PSX/Core" key:@"Deinterlacer" defaultValue:@"bob"];
    if (![deint isEqualToString:@"weave"] && ![deint isEqualToString:@"bob"]) deint = @"bob";
    SakuraApplyBeetlePSXLibretroVariable(core, @"deinterlacer", deint);

    // crop overscan: "smart" = h+v (default), "static" = h only, "disabled" = raw.
    NSString *cropOver = [SakuraBridge getINIString:@"PSX/Core" key:@"CropOverscan" defaultValue:@"smart"];
    if (![cropOver isEqualToString:@"smart"]
        && ![cropOver isEqualToString:@"static"]
        && ![cropOver isEqualToString:@"disabled"]) {
        cropOver = @"smart";
    }
    SakuraApplyBeetlePSXLibretroVariable(core, @"crop_overscan", cropOver);

    float hostEmu = [SakuraBridge getINIFloat:@"PSX/Core" key:@"host_emulation_speed" defaultValue:1.0f];
    if (hostEmu < 0.25f) hostEmu = 0.25f;
    if (hostEmu > 8.0f) hostEmu = 8.0f;
    core.hostEmulationSpeed = (double)hostEmu;
}

static void SakuraBridgeApplyEmulatorSettingsPresentationAudioNeuralFromINI(void)
{
    SakuraPS1Core *core = [SakuraPS1Core shared];
    float colorSat = [SakuraBridge getINIFloat:@"EmuCore/GS" key:@"display_color_saturation" defaultValue:1.f];
    if (colorSat < 0.f) colorSat = 0.f;
    if (colorSat > 2.f) colorSat = 2.f;

    BOOL adjEn = NO;
    if ([SakuraBridge containsINIValue:@"EmuCore/GS" key:@"color_adjust_enabled"]) {
        adjEn = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"color_adjust_enabled" defaultValue:NO];
    } else {
        adjEn = fabsf(colorSat - 1.f) > 1e-4f;
    }

    auto clampF = [](float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); };

    const BOOL hdrCapable = SakuraPresentationHdrDrawableAvailable();
    BOOL hdrINI = hdrCapable ? [SakuraBridge getINIBool:@"EmuCore/GS" key:@"color_adjust_hdr_enabled" defaultValue:NO] : NO;
    if (!adjEn)
        hdrINI = NO;

    float hdrExposure = clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_hdr_exposure" defaultValue:0.f], -2.f, 2.f);
    float hdrSat = clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_hdr_saturation" defaultValue:1.f], 0.f, 2.f);
    float hdrContr = clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_hdr_contrast" defaultValue:1.f], 0.5f, 2.f);
    float hdrBloom = clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_hdr_bloom" defaultValue:0.f], 0.f, 1.f);
    float hdrShadow = clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_hdr_shadow_lift" defaultValue:0.f], 0.f, 0.5f);
    float hdrHi = clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_hdr_highlight_compress" defaultValue:0.f], 0.f, 1.f);

    [core setPresentationColorAdjustEnabled:adjEn
                                   saturation:colorSat
                                   brightness:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_brightness" defaultValue:0.f], -0.5f, 0.5f)
                                     contrast:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_contrast" defaultValue:1.f], 0.5f, 2.f)
                                     vibrance:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_vibrance" defaultValue:0.f], -1.f, 1.f)
                                     exposure:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_exposure" defaultValue:0.f], -2.f, 2.f)
                                        gamma:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_gamma" defaultValue:1.f], 0.5f, 2.5f)
                             colorTemperature:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_temperature" defaultValue:0.f], -1.f, 1.f)
                                   sharpness:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_sharpness" defaultValue:0.f], 0.f, 2.f)
                             bloomIntensity:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_bloom" defaultValue:0.f], 0.f, 1.f)
                                bloomRadius:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_bloom_radius" defaultValue:3.f], 0.25f, 8.f)
                          vignetteIntensity:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_vignette" defaultValue:0.f], 0.f, 1.f)
                             vignetteRadius:clampF([SakuraBridge getINIFloat:@"EmuCore/GS" key:@"color_adjust_vignette_radius" defaultValue:1.f], 0.25f, 2.5f)
                          hdrGradeEnabled:hdrINI
                            hdrExtendedDrawable:hdrINI
                                  hdrExposure:hdrExposure
                              hdrSaturation:hdrSat
                                hdrContrast:hdrContr
                                   hdrBloom:hdrBloom
                               shadowLift:hdrShadow
                         highlightCompress:hdrHi];

    int audioLat = (int)[SakuraBridge getINIInt:@"PSX/Core" key:@"audio_latency_ms" defaultValue:128];
    if (audioLat < 0) audioLat = 0;
    if (audioLat > 512) audioLat = 512;
    BOOL audioSync = [SakuraBridge getINIBool:@"PSX/Core" key:@"audio_sync" defaultValue:YES];
    BOOL muteTurbo = [SakuraBridge getINIBool:@"PSX/Core" key:@"mute_audio_when_turbo" defaultValue:YES];
    BOOL audioStretch = [SakuraBridge getINIBool:@"PSX/Core" key:@"audio_time_stretch" defaultValue:YES];
    [core applyHostAudioSettingsLatencyMs:audioLat audioSync:audioSync muteWhenTurbo:muteTurbo audioTimeStretch:audioStretch];

    NSString *neuralModelIni = [SakuraBridge getINIString:@"EmuCore/GS" key:@"neural_upscale_model" defaultValue:@"bundle"];
    BOOL neuralLiveIni = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_live" defaultValue:NO];
    BOOL neuralTexArtIni = [SakuraBridge getINIBool:@"EmuCore/GS" key:@"neural_upscale_texture_art" defaultValue:NO];
    static NSString *s_prevNeuralModelIni = nil;
    static BOOL s_prevNeuralLiveIni = NO;
    static BOOL s_prevNeuralTexArtIni = NO;
    if (neuralLiveIni && !s_prevNeuralLiveIni) {
    }
    const BOOL neuralIniChanged =
        (!s_prevNeuralModelIni || ![neuralModelIni isEqualToString:s_prevNeuralModelIni] || neuralLiveIni != s_prevNeuralLiveIni || neuralTexArtIni != s_prevNeuralTexArtIni);
    if (neuralIniChanged) {
    }
    s_prevNeuralModelIni = [neuralModelIni copy];
    s_prevNeuralLiveIni = neuralLiveIni;
    s_prevNeuralTexArtIni = neuralTexArtIni;
}

@implementation SakuraBridge

+ (BOOL)writeSaveStateBytesToPath:(nonnull NSString *)path {
    return [[SakuraPS1Core shared] writeSaveStateBytesToPath:path];
}

+ (BOOL)loadSaveStateBytesFromPath:(nonnull NSString *)path {
    return [[SakuraPS1Core shared] loadSaveStateBytesFromPath:path];
}

+ (void)initialize {
    if (self != [SakuraBridge class]) return;
    // promote per-game controller mode to DualShock when the core posts the
    // auto-switch notification.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"SakuraPS1AutoSwitchToDualShockRequested"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        NSString* gameName = (NSString *)note.userInfo[@"game"] ?: ([SakuraBridge currentISOPath] ?: @"");
        if (gameName.length == 0) {
            [SakuraBridge setPS1ControllerMode:(int)SakuraPS1ControllerModeDualShock];
        } else {
            [SakuraBridge setPS1ControllerMode:(int)SakuraPS1ControllerModeDualShock forGame:gameName];
        }
    }];
}

+ (UIView*)gameRenderView {
    return g_gameRenderView;
}

+ (void)saveNVRAM {
    g_lastNVMSaveDate = [NSDate date];
}
+ (void)saveMemoryCards {
    // libretro SRAM flush, hash-deduped, no-op when nothing changed.
    (void)[[SakuraPS1Core shared] flushSaveRAMToDisk];
}
+ (void)saveAllState {
    [self saveNVRAM];
    [self saveMemoryCards];
}
+ (BOOL)isRunning { return [SakuraPS1Core shared].running; }
+ (BOOL)recommendedMTVUEnabled { return NO; }

+ (nullable NSDate*)lastNVMSaveDate { return g_lastNVMSaveDate; }
+ (nullable NSString*)nvmFilePath { return nil; }
+ (BOOL)nvmFileExists {
    NSString* path = [self nvmFilePath];
    if (!path) return NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

+ (BOOL)saveStateToSlot:(int)slot {
    return [[SakuraPS1Core shared] saveStateToSlot:slot];
}
+ (BOOL)loadStateFromSlot:(int)slot {
    return [[SakuraPS1Core shared] loadStateFromSlot:slot];
}
+ (BOOL)hasSaveStateInSlot:(int)slot {
    return [[SakuraPS1Core shared] hasSaveStateInSlot:slot];
}
+ (nullable NSDate*)saveStateDateForSlot:(int)slot {
    return [[SakuraPS1Core shared] saveStateDateForSlot:slot];
}

+ (BOOL)hasSaveStateInSlot:(int)slot forISOFileName:(NSString *)isoName {
    if (!isoName.length) return NO;
    NSString *path = [[SakuraPS1Core shared] saveStatePathForISOBaseName:isoName slot:slot];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

+ (nullable NSDate *)saveStateDateForSlot:(int)slot forISOFileName:(NSString *)isoName {
    if (!isoName.length) return nil;
    NSString *path = [[SakuraPS1Core shared] saveStatePathForISOBaseName:isoName slot:slot];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return attrs[NSFileModificationDate];
}

+ (nullable NSString *)resolvedAbsolutePathForLibraryISO:(nullable NSString *)isoName {
    if (!isoName.length) return nil;
    return SakuraResolveGamePath(isoName);
}

+ (uint64_t)totalPayloadByteCountForISOPath:(NSString *)isoPath {
    if (isoPath.length == 0) return 0;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* ext = isoPath.pathExtension.lowercaseString;

    // playlist/cuesheet files on disk are tiny. report the sum of the
    // bin/img discs they reference instead.
    auto sizeOf = ^uint64_t(NSString* p) {
        if (p.length == 0) return 0;
        NSDictionary* a = [fm attributesOfItemAtPath:p error:nil];
        NSNumber* n = a[NSFileSize];
        return n ? (uint64_t)n.unsignedLongLongValue : 0;
    };

    if ([ext isEqualToString:@"m3u"]) {
        NSString* text = [NSString stringWithContentsOfFile:isoPath encoding:NSUTF8StringEncoding error:nil];
        if (!text) text = [NSString stringWithContentsOfFile:isoPath encoding:NSISOLatin1StringEncoding error:nil];
        if (!text) return sizeOf(isoPath);
        NSString* dir = isoPath.stringByDeletingLastPathComponent;
        __block uint64_t total = 0;
        __block BOOL any = NO;
        [text enumerateLinesUsingBlock:^(NSString* line, BOOL* _Nonnull stop) {
            NSString* t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (t.length == 0 || [t hasPrefix:@"#"]) return;
            NSString* child = [dir stringByAppendingPathComponent:t];
            if ([fm fileExistsAtPath:child]) {
                any = YES;
                total += [SakuraBridge totalPayloadByteCountForISOPath:child];
            }
        }];
        return any ? total : sizeOf(isoPath);
    }
    if ([ext isEqualToString:SakuraCueExt] || [ext isEqualToString:SakuraCueTypoExt]) {
        NSString* dir = isoPath.stringByDeletingLastPathComponent;
        uint64_t total = 0;
        BOOL any = NO;
        for (NSString* ref in SakuraCueReferencedFiles(isoPath)) {
            NSString* child = [dir stringByAppendingPathComponent:ref];
            if ([fm fileExistsAtPath:child]) {
                any = YES;
                total += sizeOf(child);
            }
        }
        return any ? total : sizeOf(isoPath);
    }
    if ([ext isEqualToString:@"ccd"]) {
        NSString* base = isoPath.stringByDeletingPathExtension;
        for (NSString* cand in @[[base stringByAppendingPathExtension:@"img"],
                                 [base stringByAppendingPathExtension:@"bin"]]) {
            if ([fm fileExistsAtPath:cand]) return sizeOf(cand);
        }
    }
    return sizeOf(isoPath);
}

+ (nullable NSString *)saveStatePreviewPathForISOName:(NSString *)isoName slot:(int)slot {
    if (!isoName.length || slot < 1 || slot > 10) return nil;
    return [[SakuraPS1Core shared] saveStatePreviewPathForLibraryISO:isoName slot:slot];
}

+ (void)deleteSaveStatesAndPreviewsForLibraryISO:(NSString *)isoName {
    if (!isoName.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    SakuraPS1Core *core = [SakuraPS1Core shared];
    for (int slot = 1; slot <= 10; slot++) {
        NSString *statePath = [core saveStatePathForISOBaseName:isoName slot:slot];
        NSString *thumb = @"";
        if (statePath.length) {
            NSString *folder = statePath.stringByDeletingLastPathComponent;
            NSString *stem = statePath.lastPathComponent.stringByDeletingPathExtension;
            thumb = [folder stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"preview.png"]];
        }
        if (statePath.length && [fm fileExistsAtPath:statePath])
            [fm removeItemAtPath:statePath error:nil];
        if (thumb.length && [fm fileExistsAtPath:thumb])
            [fm removeItemAtPath:thumb error:nil];
    }
}

+ (void)setPadButton:(PadButton)button pressed:(BOOL)pressed {
    [[SakuraPS1Core shared] setPadButton:button pressed:pressed];
}
+ (void)setPadButton:(PadButton)button pressed:(BOOL)pressed port:(int)port {
    [[SakuraPS1Core shared] setPadButton:button pressed:pressed port:port];
}
+ (void)setLeftStickX:(float)x y:(float)y {
    [[SakuraPS1Core shared] setLeftStickX:x y:y];
}
+ (void)setLeftStickX:(float)x y:(float)y port:(int)port {
    [[SakuraPS1Core shared] setLeftStickX:x y:y port:port];
}
+ (void)setRightStickX:(float)x y:(float)y {
    [[SakuraPS1Core shared] setRightStickX:x y:y];
}
+ (void)setRightStickX:(float)x y:(float)y port:(int)port {
    [[SakuraPS1Core shared] setRightStickX:x y:y port:port];
}

+ (void)handleVibrationForPad:(int)padIndex largeMotor:(float)large smallMotor:(float)small {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:SakuraNotificationVibrate
                          object:nil
                        userInfo:@{@"pad": @(padIndex), @"large": @(large), @"small": @(small)}];
    });
}

+ (NSString*)biosName { return @"PlayStation"; }
+ (void)requestVMStop {
    [[SakuraPS1Core shared] stop];
    [[NSNotificationCenter defaultCenter] postNotificationName:SakuraNotificationVMShutdown object:nil];
}
+ (void)setFullScreen:(BOOL)enabled { (void)enabled; }
+ (NSString*)buildVersion {
    NSString* v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    return [NSString stringWithFormat:@"Sakura v%@", v];
}

+ (void)setPerformanceOverlayVisible:(BOOL)visible { (void)visible; }
+ (BOOL)isPerformanceOverlayVisible { return NO; }
+ (void)applyOsdPreset:(int)preset { (void)preset; }

+ (double)perfFPS { return [SakuraPS1Core shared].running ? [[SakuraPS1Core shared] fps] : 0.0; }
+ (unsigned long long)perfMetalLayerPresentCount { return [[SakuraPS1Core shared] metalLayerDrawablePresentCount]; }
+ (unsigned long long)perfNeuralCommitCount { return (unsigned long long)[[SakuraNeuralUpscale shared] neuralOutputCommitCount]; }
+ (double)perfVPS { return [SakuraPS1Core shared].running ? [[SakuraPS1Core shared] vps] : 0.0; }
+ (double)perfSpeed { return [SakuraPS1Core shared].running ? [[SakuraPS1Core shared] speed] : 0.0; }
+ (unsigned)psBaseWidth { return [[SakuraPS1Core shared] baseWidth]; }
+ (unsigned)psBaseHeight { return [[SakuraPS1Core shared] baseHeight]; }
+ (unsigned)psPresentWidth { return [[SakuraPS1Core shared] presentPixelWidth]; }
+ (unsigned)psPresentHeight { return [[SakuraPS1Core shared] presentPixelHeight]; }

#if TARGET_OS_IPHONE
+ (CGFloat)screenPotentialEDRHeadroomApprox {
    if (@available(iOS 16.0, *))
        return (CGFloat)fmax(1.0, (double)[UIScreen mainScreen].potentialEDRHeadroom);
    return 1.f;
}
+ (BOOL)presentationHDRHeadroomLikelyAvailable { return SakuraPresentationHdrDrawableAvailable(); }
#else
+ (CGFloat)screenPotentialEDRHeadroomApprox { return 1.f; }
+ (BOOL)presentationHDRHeadroomLikelyAvailable { return NO; }
#endif

+ (NSString*)documentsDirectory {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (NSString*)isoDirectory {
    NSString* docs = [self documentsDirectory];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* games = [docs stringByAppendingPathComponent:@"Games"];
    NSString* legacy = [docs stringByAppendingPathComponent:@"iso"];
    BOOL hasLegacy = [fm fileExistsAtPath:legacy];
    BOOL hasGames = [fm fileExistsAtPath:games];
    if (hasLegacy && !hasGames) {
        [fm moveItemAtPath:legacy toPath:games error:nil];
    } else if (hasLegacy && hasGames) {
        for (NSString* name in [fm contentsOfDirectoryAtPath:legacy error:nil]) {
            NSString* src = [legacy stringByAppendingPathComponent:name];
            NSString* dst = [games stringByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:dst]) [fm moveItemAtPath:src toPath:dst error:nil];
        }
        if ([fm contentsOfDirectoryAtPath:legacy error:nil].count == 0) {
            [fm removeItemAtPath:legacy error:nil];
        }
    }
    [fm createDirectoryAtPath:games withIntermediateDirectories:YES attributes:nil error:nil];
    return games;
}

+ (NSArray<NSString*>*)availableISOs {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    NSMutableArray<NSString*>* isos = [NSMutableArray array];

    // dir: absolute on-disk dir. relPrefix: relative path ("" or "FF7"). recurse: only under Games/.
    void (^__block scanDir)(NSString*, NSString*, BOOL) = nil;
    scanDir = ^(NSString* dir, NSString* relPrefix, BOOL recurse) {
        NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:dir error:nil];
        NSMutableSet<NSString*>* cueOwnedBins = [NSMutableSet set];
        NSMutableArray<NSString*>* cuePaths = [NSMutableArray array];

        // First pass: normalize .cua → .cue and collect cue file paths.
        for (NSString* file in files) {
            NSString* ext = file.pathExtension.lowercaseString;
            NSString* name = file;
            if ([ext isEqualToString:SakuraCueTypoExt]) {
                NSString* normalized = SakuraNormalizedCueName(file);
                NSString* src = [dir stringByAppendingPathComponent:file];
                NSString* dst = [dir stringByAppendingPathComponent:normalized];
                if (![fm fileExistsAtPath:dst] && [fm moveItemAtPath:src toPath:dst error:nil]) {
                    name = normalized;
                }
            }
            NSString* cueLikeExt = name.pathExtension.lowercaseString;
            if (![cueLikeExt isEqualToString:SakuraCueExt] && ![cueLikeExt isEqualToString:SakuraCueTypoExt]) continue;
            [cuePaths addObject:[dir stringByAppendingPathComponent:name]];
        }

        // Heal cues whose FILE refs are missing on disk by pointing them at a
        // sibling .bin not already claimed by another cue. Common when bins
        // got renamed after the cue was authored.
        if (cuePaths.count > 0) {
            NSMutableSet<NSString*>* claimed = [NSMutableSet set];
            for (NSString* cp in cuePaths) {
                for (NSString* ref in SakuraCueReferencedFiles(cp)) {
                    if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:ref]]) {
                        [claimed addObject:ref.lowercaseString];
                    }
                }
            }
            for (NSString* cp in cuePaths) {
                if (SakuraCueHasExistingRef(dir, cp)) continue;
                NSString* pick = SakuraPickOrphanBin(dir, files, claimed);
                if (pick.length == 0) continue;
                if (SakuraRewriteCueToBin(cp, pick)) {
                    [claimed addObject:pick.lowercaseString];
                }
            }
        }

        // Build cueOwnedBins from the (possibly-rewritten) cues.
        for (NSString* cp in cuePaths) {
            for (NSString* ref in SakuraCueReferencedFiles(cp)) {
                [cueOwnedBins addObject:ref.lowercaseString];
            }
        }

        // Auto-create a one-track .cue beside any loose .bin > threshold so the
        // PSX core can load it and the bin doesn't show as a second library row.
        for (NSString* file in files) {
            if (![file.pathExtension.lowercaseString isEqualToString:SakuraLargeBinExt]) continue;
            if ([cueOwnedBins containsObject:file.lowercaseString]) continue;
            NSDictionary* attrs = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:file] error:nil];
            if ([attrs fileSize] <= SakuraLargeBinThreshold) continue;
            if (SakuraEnsureCueForLooseBin(dir, file)) {
                [cueOwnedBins addObject:file.lowercaseString];
            }
        }

        // Re-list to include any newly created .cue files.
        files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString* file in files) {
            NSString* relPath = relPrefix.length > 0
                ? [relPrefix stringByAppendingPathComponent:file]
                : file;
            NSString* fullPath = [dir stringByAppendingPathComponent:file];

            BOOL isDir = NO;
            [fm fileExistsAtPath:fullPath isDirectory:&isDir];
            if (isDir) {
                if (recurse && ![file hasPrefix:@"."]) {
                    scanDir(fullPath, relPath, YES);
                }
                continue;
            }

            if ([seen containsObject:relPath]) continue;
            NSString* ext = file.pathExtension.lowercaseString;
            if ([ext isEqualToString:SakuraCueTypoExt]) {
                NSString* normalizedCue = SakuraNormalizedCueName(file);
                if (![normalizedCue isEqualToString:file] && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:normalizedCue]]) continue;
            }
            if (SakuraIsDirectGameExt(ext)) {
                [isos addObject:relPath];
                [seen addObject:relPath];
            } else if ([ext isEqualToString:SakuraLargeBinExt]) {
                if ([cueOwnedBins containsObject:file.lowercaseString]) continue;
                NSDictionary* attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                if ([attrs fileSize] > SakuraLargeBinThreshold) {
                    [isos addObject:relPath];
                    [seen addObject:relPath];
                }
            }
        }
    };

    // Games/ recurses (per-game subfolders are canonical).
    // Documents/ root only, do not sweep iCloud or app-support trees.
    scanDir([self isoDirectory], @"", YES);
    scanDir([self documentsDirectory], @"", NO);
    return isos;
}

+ (nullable NSString*)currentISOPath {
    NSString* boot = [[SakuraINIStore shared] getString:@"GameISO" key:@"BootISO" def:@""];
    return boot.length > 0 ? boot : nil;
}

+ (void)bootISO:(NSString*)isoName {
    [[SakuraINIStore shared] setString:isoName ?: @"" section:@"GameISO" key:@"BootISO"];
}

+ (NSString*)biosDirectory {
    NSString* dir = [[self documentsDirectory] stringByAppendingPathComponent:@"bios"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSArray<NSString*>*)availableBIOSes {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray* out = [NSMutableArray array];
    NSString* dir = [self biosDirectory];
    for (NSString* file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString* ext = file.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"bin"] && ![ext isEqualToString:@"rom"]) continue;
        NSString* full = [dir stringByAppendingPathComponent:file];
        unsigned long long sz = [[fm attributesOfItemAtPath:full error:nil] fileSize];
        if (sz >= 256 * 1024 && sz <= 4 * 1024 * 1024) {
            [out addObject:file];
        }
    }
    return out;
}

+ (NSString*)defaultBIOSName {
    return [[SakuraINIStore shared] getString:@"Filenames" key:@"BIOS" def:@""];
}
+ (void)setDefaultBIOS:(NSString*)biosName {
    [[SakuraINIStore shared] setString:biosName ?: @"" section:@"Filenames" key:@"BIOS"];
}

+ (BOOL)isFavorite:(NSString*)isoName {
    return [[SakuraINIStore shared] getBool:@"Favorites" key:isoName def:NO];
}
+ (void)setFavorite:(NSString*)isoName favorite:(BOOL)favorite {
    [[SakuraINIStore shared] setBool:favorite section:@"Favorites" key:isoName];
}

+ (void)setINIWriteSuppressed:(BOOL)suppressed { g_iniWriteSuppressed.store(suppressed); }
+ (BOOL)isINIWriteSuppressed { return g_iniWriteSuppressed.load(); }

+ (void)logINIDiagnostics:(NSString*)tag {
    NSString* path = [SakuraINIStore shared].path;
    struct stat st{};
    long sz = -1;
    if (stat(path.fileSystemRepresentation, &st) == 0) sz = (long)st.st_size;
    Sakura_LogNative("INI", "Dev", "tag=%s path='%s' size=%ld",
        tag.UTF8String ?: "", path.UTF8String ?: "", sz);
}

+ (int)getINIInt:(NSString*)section key:(NSString*)key defaultValue:(int)def {
    return [[SakuraINIStore shared] getInt:section key:key def:def];
}
+ (BOOL)getINIBool:(NSString*)section key:(NSString*)key defaultValue:(BOOL)def {
    return [[SakuraINIStore shared] getBool:section key:key def:def];
}
+ (float)getINIFloat:(NSString*)section key:(NSString*)key defaultValue:(float)def {
    return [[SakuraINIStore shared] getFloat:section key:key def:def];
}
+ (NSString*)getINIString:(NSString*)section key:(NSString*)key defaultValue:(NSString*)def {
    return [[SakuraINIStore shared] getString:section key:key def:def];
}
+ (BOOL)containsINIValue:(NSString*)section key:(NSString*)key {
    return [[SakuraINIStore shared] contains:section key:key];
}
+ (void)setINIInt:(NSString*)section key:(NSString*)key value:(int)value {
    if (g_iniWriteSuppressed.load()) return;
    [[SakuraINIStore shared] setInt:value section:section key:key];
}
+ (void)setINIBool:(NSString*)section key:(NSString*)key value:(BOOL)value {
    if (g_iniWriteSuppressed.load()) return;
    [[SakuraINIStore shared] setBool:value section:section key:key];
}
+ (void)setINIFloat:(NSString*)section key:(NSString*)key value:(float)value {
    if (g_iniWriteSuppressed.load()) return;
    [[SakuraINIStore shared] setFloat:value section:section key:key];
}
+ (void)setINIString:(NSString*)section key:(NSString*)key value:(NSString*)value {
    if (g_iniWriteSuppressed.load()) return;
    [[SakuraINIStore shared] setString:value ?: @"" section:section key:key];
}
+ (void)setHostPresentAspectMode:(int)mode {
    int m = (mode == 3) ? 3 : 2;
    [[SakuraPS1Core shared] setAspectRatio:m];
}

+ (void)flushINIWritesSynchronously {
    [[SakuraINIStore shared] flushWritesSynchronously];
}

+ (void)reloadINIStoreFromDisk {
    [[SakuraINIStore shared] reloadFromDisk];
}

+ (void)applyEmulatorSettings {
    dispatch_queue_t q = SakuraSettingsApplyQueue();
    dispatch_async(q, ^{
        if (g_pendingDebouncedApplyBlock) {
            dispatch_block_cancel(g_pendingDebouncedApplyBlock);
            g_pendingDebouncedApplyBlock = nil;
        }
        dispatch_block_t blk = dispatch_block_create(DISPATCH_BLOCK_ASSIGN_CURRENT, ^{
            SakuraBridgeApplyEmulatorSettingsCoreAndBeetleFromINI();
            SakuraBridgeApplyEmulatorSettingsPresentationAudioNeuralFromINI();
            g_pendingDebouncedApplyBlock = nil;
        });
        g_pendingDebouncedApplyBlock = blk;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.048 * NSEC_PER_SEC)), q, blk);
    });
}

+ (void)applyEmulatorSettingsImmediately {
    dispatch_sync(SakuraSettingsApplyQueue(), ^{
        if (g_pendingDebouncedApplyBlock) {
            dispatch_block_cancel(g_pendingDebouncedApplyBlock);
            g_pendingDebouncedApplyBlock = nil;
        }
        SakuraBridgeApplyEmulatorSettingsCoreAndBeetleFromINI();
        SakuraBridgeApplyEmulatorSettingsPresentationAudioNeuralFromINI();
    });
}

+ (void)applyRunningHostEmulationSpeedLive:(float)speed {
    float hostEmu = speed;
    if (hostEmu < 0.25f)
        hostEmu = 0.25f;
    if (hostEmu > 8.0f)
        hostEmu = 8.0f;
    [[SakuraPS1Core shared] setHostEmulationSpeed:(double)hostEmu];
}

+ (UIImage *)processNeuralTextureArtUIImage:(UIImage *)image {
    if (!image)
        return nil;
    return [[SakuraNeuralUpscale shared] upscaleUIImageForTextureArtIfEnabled:image];
}

+ (void)warmUpNeuralModelAsync {
    [[SakuraNeuralUpscale shared] warmUpAsync];
}

+ (BOOL)isEmulationRunning { return [SakuraPS1Core shared].running; }
+ (BOOL)hasBIOS { return SakuraSelectedBIOSPath() != nil; }

+ (BOOL)requestVMBoot {
    g_lastBootFailureReason = nil;
    NSString* gameName = [self currentISOPath];
    int padMode = [self ps1ControllerModeForGame:gameName ?: @""];
    [[SakuraPS1Core shared] setControllerMode:(SakuraPS1ControllerMode)padMode];
    [[SakuraINIStore shared] flushWritesSynchronously];
    [self applyEmulatorSettingsImmediately];
    NSString* gamePath = SakuraResolveGamePath(gameName);
    NSString* biosPath = SakuraSelectedBIOSPath();
    NSError* error = nil;
    if (![[SakuraPS1Core shared] bootGameAtPath:gamePath ?: @"" biosPath:biosPath error:&error]) {
        g_lastBootFailureReason = ([error localizedDescription].length > 0)
            ? [[error localizedDescription] copy]
            : [@"Boot failed." copy];
        SakuraLogUnified(@"Boot", @"Error", [NSString stringWithFormat:@"PS1 boot failed: %@", error.localizedDescription]);
        return NO;
    }
    return YES;
}

+ (nullable NSString *)lastBootFailureReason {
    return g_lastBootFailureReason;
}

+ (void)requestVMShutdown {
    [[SakuraPS1Core shared] stop];
    [[NSNotificationCenter defaultCenter] postNotificationName:SakuraNotificationVMShutdown object:nil];
}

+ (BOOL)isEmulationPaused { return [SakuraPS1Core shared].isPaused; }
+ (void)setEmulationPaused:(BOOL)paused { [SakuraPS1Core shared].paused = paused; }

static std::atomic<bool> s_captureMode{false};
static std::atomic<int>  s_capturedButton{-1};
static int s_buttonMap[16] = {
    SakuraGamepad::BUTTON_DPAD_UP,
    SakuraGamepad::BUTTON_DPAD_DOWN,
    SakuraGamepad::BUTTON_DPAD_LEFT,
    SakuraGamepad::BUTTON_DPAD_RIGHT,
    SakuraGamepad::BUTTON_SOUTH,
    SakuraGamepad::BUTTON_EAST,
    SakuraGamepad::BUTTON_WEST,
    SakuraGamepad::BUTTON_NORTH,
    SakuraGamepad::BUTTON_LEFT_SHOULDER,
    SakuraGamepad::BUTTON_RIGHT_SHOULDER,
    -1, -1,
    SakuraGamepad::BUTTON_START,
    SakuraGamepad::BUTTON_BACK,
    SakuraGamepad::BUTTON_LEFT_STICK,
    SakuraGamepad::BUTTON_RIGHT_STICK,
};

+ (void)startButtonCapture {
    s_capturedButton.store(-1);
    s_captureMode.store(true);
}
+ (void)stopButtonCapture { s_captureMode.store(false); }
+ (void)pollGamepadForCapture {
    if (!s_captureMode.load()) return;
    int cap = -1;
    SakuraGamepadIOS_PollCapture(&cap);
    if (cap >= 0) s_capturedButton.store(cap);
}
+ (int)capturedButton { return s_capturedButton.exchange(-1); }

+ (void)setButtonMapping:(int)idx toSDLButton:(int)sdl {
    if (idx >= 0 && idx < 16) {
        s_buttonMap[idx] = sdl;
        NSString* key = [NSString stringWithFormat:SakuraPadKeyButton, idx];
        [[SakuraINIStore shared] setInt:sdl section:SakuraPadSection key:key];
    }
}
+ (int)getButtonMapping:(int)idx {
    if (idx >= 0 && idx < 16) {
        NSString* key = [NSString stringWithFormat:SakuraPadKeyButton, idx];
        if ([[SakuraINIStore shared] contains:SakuraPadSection key:key]) {
            s_buttonMap[idx] = [[SakuraINIStore shared] getInt:SakuraPadSection key:key def:s_buttonMap[idx]];
        }
        return s_buttonMap[idx];
    }
    return -1;
}
+ (void)resetButtonMappings {
    static const int defMap[16] = {
        SakuraGamepad::BUTTON_DPAD_UP, SakuraGamepad::BUTTON_DPAD_DOWN,
        SakuraGamepad::BUTTON_DPAD_LEFT, SakuraGamepad::BUTTON_DPAD_RIGHT,
        SakuraGamepad::BUTTON_SOUTH, SakuraGamepad::BUTTON_EAST,
        SakuraGamepad::BUTTON_WEST, SakuraGamepad::BUTTON_NORTH,
        SakuraGamepad::BUTTON_LEFT_SHOULDER, SakuraGamepad::BUTTON_RIGHT_SHOULDER,
        -1, -1,
        SakuraGamepad::BUTTON_START, SakuraGamepad::BUTTON_BACK,
        SakuraGamepad::BUTTON_LEFT_STICK, SakuraGamepad::BUTTON_RIGHT_STICK,
    };
    for (int i = 0; i < 16; i++) s_buttonMap[i] = defMap[i];
    [[SakuraINIStore shared] removeSection:SakuraPadSection];
}

+ (void)resetKeyboardPadMappings {
    [[SakuraINIStore shared] removeSection:SakuraKeyboardPadSection];
}

+ (nullable NSString *)keyboardPadBindingForIniKey:(NSString *)iniKey {
    if (iniKey.length == 0) return nil;
    if (![[SakuraINIStore shared] contains:SakuraKeyboardPadSection key:iniKey]) return nil;
    NSString *v = [[SakuraINIStore shared] getString:SakuraKeyboardPadSection key:iniKey def:@""];
    return v.length > 0 ? v : nil;
}

+ (BOOL)isPhysicalPadToGameSuppressed {
    return Sakura_IsPhysicalPadToGameSuppressed() ? YES : NO;
}

+ (void)setPhysicalPadToGameSuppressed:(BOOL)suppressed {
    Sakura_SetPhysicalPadToGameSuppressed(suppressed ? true : false);
    if (suppressed) {
        SakuraPS1Core* core = [SakuraPS1Core shared];
        for (int i = 0; i < 16; i++) {
            [core setPhysicalPadButton:i pressed:NO];
        }
        [core setPhysicalLeftStickX:0 y:0];
        [core setPhysicalRightStickX:0 y:0];
    }
}

+ (void)refreshPhysicalGamepadInputCache {
    SakuraGamepadIOS_RefreshMainThreadCachedInput();
}

+ (BOOL)isSDLGamepadButtonPressed:(int)sdl {
    if (sdl >= 100 && sdl < 106) {
        float axis = SakuraGamepadIOS_Axis(sdl - 100);
        return (axis > 0.5f || axis < -0.5f) ? YES : NO;
    }
    if (sdl < 0 || sdl >= SakuraGamepad::BUTTON_COUNT) return NO;
    return SakuraGamepadIOS_ButtonPressed(sdl) ? YES : NO;
}

+ (int)firstPressedSDLGamepadButton {
    int cap = -1;
    SakuraGamepadIOS_PollCapture(&cap);
    if (cap >= 0) return cap;
    for (int i = 0; i < 6; i++) {
        float axis = SakuraGamepadIOS_Axis(i);
        if (axis > 0.5f || axis < -0.5f) return 100 + i;
    }
    return -1;
}

+ (nullable NSString*)isoSerialForPath:(NSString*)path {
    NSString* serial = SakuraScanPS1SerialFromFile(path);
    if (serial.length > 0) return serial;
    return SakuraFindPS1SerialInText(path.lastPathComponent);
}
+ (nonnull NSString*)libraryDedupKeyForISOPath:(NSString*)path {
    if (path.length == 0) return @"";
    NSString* serial = [self isoSerialForPath:path];
    if (serial.length > 0) {
        NSString* norm = SakuraNormalizePS1Serial(serial);
        NSString* u = ((norm.length > 0) ? norm : serial).uppercaseString;
        return [@"s:" stringByAppendingString:u];
    }
    NSString* payload = SakuraResolveMetadataPayloadPath(path);
    if (payload.length == 0) payload = path;
    struct stat st{};
    if (stat(payload.fileSystemRepresentation, &st) == 0) {
        return [NSString stringWithFormat:@"i:%llu:%llu",
                (unsigned long long)st.st_dev, (unsigned long long)st.st_ino];
    }
    return [@"p:" stringByAppendingString:path];
}

+ (nonnull NSString*)libraryDedupKeyForCachedSerial:(NSString*)cachedSerial isoPath:(NSString*)path
{
    if (path.length == 0) return @"";
    if (cachedSerial.length > 0) {
        NSString* norm = SakuraNormalizePS1Serial(cachedSerial);
        NSString* u = ((norm.length > 0) ? norm : cachedSerial).uppercaseString;
        return [@"s:" stringByAppendingString:u];
    }
    NSString* payload = SakuraResolveMetadataPayloadPath(path);
    if (payload.length == 0) payload = path;
    struct stat st{};
    if (stat(payload.fileSystemRepresentation, &st) == 0) {
        return [NSString stringWithFormat:@"i:%llu:%llu",
                (unsigned long long)st.st_dev, (unsigned long long)st.st_ino];
    }
    return [@"p:" stringByAppendingString:path];
}

+ (nullable NSDictionary*)libraryPayloadIdentityForISOPath:(NSString*)path
{
    if (path.length == 0) return nil;
    NSString* payload = SakuraResolveMetadataPayloadPath(path);
    if (payload.length == 0) payload = path;
    struct stat st{};
    if (stat(payload.fileSystemRepresentation, &st) != 0) return nil;
    return @{
        @"dev" : @(st.st_dev),
        @"ino" : @(st.st_ino),
        @"size" : @((unsigned long long)st.st_size),
        @"mtimeSec" : @(st.st_mtime),
        @"mtimeNsec" : @(st.st_mtimespec.tv_nsec),
    };
}

+ (nullable NSString*)isoTitleForPath:(NSString*)path {
    return SakuraCleanGameTitleFromFilename(path);
}
+ (nullable NSString*)isoRegionForPath:(NSString*)path {
    NSString* serial = [self isoSerialForPath:path];
    if (serial.length < 4) return nil;
    NSString* prefix = [[serial substringToIndex:4] uppercaseString];
    if ([prefix hasPrefix:@"SCU"] || [prefix hasPrefix:@"SLU"]) return @"NTSC-U";
    if ([prefix hasPrefix:@"SCE"] || [prefix hasPrefix:@"SLE"]) return @"PAL";
    if ([prefix hasPrefix:@"SCP"] || [prefix hasPrefix:@"SLP"] || [prefix isEqualToString:@"SIPS"]) return @"NTSC-J";
    if ([prefix isEqualToString:@"SLKA"]) return @"NTSC-K";
    if ([prefix isEqualToString:@"SCAJ"]) return @"NTSC-Asia";
    return nil;
}

static inline int SakuraClampPS1ControllerPickerMode(int raw) {
    return (raw == 0 || raw == 1) ? raw : (int)SakuraPS1ControllerModeDigital;
}

+ (int)ps1ControllerMode { return [self ps1ControllerModeForPort:0]; }
+ (void)setPS1ControllerMode:(int)mode { [self setPS1ControllerMode:mode forPort:0]; }
+ (int)ps1ControllerModeForGame:(NSString*)gameName { return [self ps1ControllerModeForGame:gameName port:0]; }
+ (void)setPS1ControllerMode:(int)mode forGame:(NSString*)gameName { [self setPS1ControllerMode:mode forGame:gameName port:0]; }
+ (void)setPS1ControllerModeForCurrentISOOrGlobal:(int)mode { [self setPS1ControllerModeForCurrentISOOrGlobal:mode port:0]; }
+ (int)ps1CoreControllerMode { return [self ps1CoreControllerModeForPort:0]; }

+ (int)ps1ControllerModeForPort:(int)port {
    if (port < 0 || port > 1) return (int)SakuraPS1ControllerModeDigital;
    NSString *key = (port == 0) ? @"Mode0" : @"Mode1";
    SakuraINIStore* ini = [SakuraINIStore shared];
    if (port == 0 && ![ini contains:@"Controller" key:key] && [ini contains:@"Controller" key:@"Mode"]) {
        return SakuraClampPS1ControllerPickerMode([ini getInt:@"Controller" key:@"Mode" def:(int)SakuraPS1ControllerModeDigital]);
    }
    return SakuraClampPS1ControllerPickerMode([ini getInt:@"Controller" key:key def:(int)SakuraPS1ControllerModeDigital]);
}

+ (void)setPS1ControllerMode:(int)mode forPort:(int)port {
    if (port < 0 || port > 1) return;
    const int clamped = SakuraClampPS1ControllerPickerMode(mode);
    NSString *key = (port == 0) ? @"Mode0" : @"Mode1";
    [[SakuraINIStore shared] setInt:clamped section:@"Controller" key:key];
    [[SakuraPS1Core shared] setControllerMode:(SakuraPS1ControllerMode)clamped forPort:port];
    NSDictionary* info = @{ @"mode": @(clamped), @"port": @(port) };
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SakuraNotificationPS1ControllerModeChanged object:nil userInfo:info];
}

+ (int)ps1ControllerModeForGame:(NSString*)gameName port:(int)port {
    if (gameName.length == 0) return [self ps1ControllerModeForPort:port];
    if (port < 0 || port > 1) return (int)SakuraPS1ControllerModeDigital;
    NSString *baseKey = [@"Game/" stringByAppendingString:gameName];
    NSString *key = [baseKey stringByAppendingString:(port == 0) ? @"/Mode0" : @"/Mode1"];
    SakuraINIStore* ini = [SakuraINIStore shared];
    if ([ini contains:@"Controller" key:key]) {
        return SakuraClampPS1ControllerPickerMode([ini getInt:@"Controller" key:key def:[self ps1ControllerModeForPort:port]]);
    }
    if (port == 0 && [ini contains:@"Controller" key:baseKey]) {
        return SakuraClampPS1ControllerPickerMode([ini getInt:@"Controller" key:baseKey def:[self ps1ControllerModeForPort:0]]);
    }
    return [self ps1ControllerModeForPort:port];
}

+ (void)setPS1ControllerMode:(int)mode forGame:(NSString*)gameName port:(int)port {
    if (gameName.length == 0) return;
    if (port < 0 || port > 1) return;
    const int clamped = SakuraClampPS1ControllerPickerMode(mode);
    NSString *key = [NSString stringWithFormat:@"Game/%@/%@", gameName, (port == 0) ? @"Mode0" : @"Mode1"];
    [[SakuraINIStore shared] setInt:clamped section:@"Controller" key:key];
    [[SakuraPS1Core shared] setControllerMode:(SakuraPS1ControllerMode)clamped forPort:port];
    NSDictionary* info = @{ @"mode": @(clamped), @"port": @(port) };
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SakuraNotificationPS1ControllerModeChanged object:nil userInfo:info];
}

+ (void)setPS1ControllerModeForCurrentISOOrGlobal:(int)mode port:(int)port {
    NSString* path = [self currentISOPath] ?: @"";
    if (path.length == 0) {
        [self setPS1ControllerMode:mode forPort:port];
    } else {
        [self setPS1ControllerMode:mode forGame:path port:port];
    }
}

+ (int)ps1CoreControllerModeForPort:(int)port {
    if (port < 0 || port > 1) return 0;
    SakuraPS1Core* core = [SakuraPS1Core shared];
    if (core.running) {
        return SakuraClampPS1ControllerPickerMode((int)[core controllerModeForPort:port]);
    }
    NSString* g = [self currentISOPath] ?: @"";
    return [self ps1ControllerModeForGame:g port:port];
}

+ (void)pumpPhysicalGamepad {
    if (Sakura_IsPhysicalPadToGameSuppressed()) return;
    if (![SakuraPS1Core shared].running) return;

    SakuraGamepadIOS_RefreshMainThreadCachedInput();

    SakuraPS1Core* core = [SakuraPS1Core shared];

    for (int p = 0; p < 2; ++p) {
        if (!SakuraGamepadIOS_PortOccupied(p)) {
            for (int i = 0; i < 16; ++i) {
                [core setPhysicalPadButton:i pressed:NO port:p];
            }
            [core setPhysicalLeftStickX:0 y:0 port:p];
            [core setPhysicalRightStickX:0 y:0 port:p];
            continue;
        }

        const BOOL digital = ([core controllerModeForPort:p] == SakuraPS1ControllerModeDigital);

        float lx = SakuraGamepadIOS_AxisForPort(p, 0);
        float ly = SakuraGamepadIOS_AxisForPort(p, 1);
        float rx = SakuraGamepadIOS_AxisForPort(p, 2);
        float ry = SakuraGamepadIOS_AxisForPort(p, 3);
        const float t = 0.42f;
        const int stickU = ly < -t ? 1 : 0;
        const int stickD = ly > t ? 1 : 0;
        const int stickL = lx < -t ? 1 : 0;
        const int stickR = lx > t ? 1 : 0;

        for (int i = 0; i < 16; i++) {
            int map = s_buttonMap[i];
            int down = 0;
            if (map >= 100 && map < 106) {
                float a = SakuraGamepadIOS_AxisForPort(p, map - 100);
                down = (a > 0.5f || a < -0.5f) ? 1 : 0;
            } else if (map >= 0) {
                down = SakuraGamepadIOS_ButtonPressedForPort(p, map) ? 1 : 0;
            }
            if (i == 10 && s_buttonMap[10] < 0) {
                down = SakuraGamepadIOS_AxisForPort(p, 4) > 0.35f ? 1 : 0;
            }
            if (i == 11 && s_buttonMap[11] < 0) {
                down = SakuraGamepadIOS_AxisForPort(p, 5) > 0.35f ? 1 : 0;
            }
            if (digital && i < 4) {
                if (i == 0 && stickU) down = 1;
                if (i == 1 && stickD) down = 1;
                if (i == 2 && stickL) down = 1;
                if (i == 3 && stickR) down = 1;
            }
            [core setPhysicalPadButton:i pressed:(down ? YES : NO) port:p];
        }
        if (digital) {
            [core setPhysicalLeftStickX:0.f y:0.f port:p];
            [core setPhysicalRightStickX:0.f y:0.f port:p];
        } else {
            [core setPhysicalLeftStickX:lx y:ly port:p];
            [core setPhysicalRightStickX:rx y:ry port:p];
        }
    }
}

+ (void)gpuCadencePump {
    SakuraPS1Core *core = [SakuraPS1Core shared];
    if (!core || ![core respondsToSelector:@selector(gpuCadencePump)])
        return;
    @try {
        [core gpuCadencePump];
    } @catch (__unused NSException *ex) {
    }
}

+ (void)pressAnalogModeToggle {
    [[SakuraPS1Core shared] pressAnalogModeToggle];
}

@end

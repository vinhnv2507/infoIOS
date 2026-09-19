#import "ChengIOSBackup.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#import <Security/Security.h>
#import <sqlite3.h>
#include <copyfile.h>
#include <errno.h>
#include <signal.h>
#include <dlfcn.h>
#ifndef COPYFILE_NOFOLLOW
#define COPYFILE_NOFOLLOW (COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
#endif
#ifndef COPYFILE_RECURSIVE
#define COPYFILE_RECURSIVE (1<<15)
#endif
#ifndef COPYFILE_CLONE
#define COPYFILE_CLONE (1<<24)
#endif

extern char **environ;

static NSString * const kChengBackupErrorDomain = @"com.vinhnv2507.chengios.backup";

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *bundleExecutable;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSDictionary *entitlements;
@property (nonatomic, readonly) NSString *applicationType;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)terminateApplication:(NSString *)bundleIdentifier withOptions:(id)options;
- (NSArray *)allInstalledApplications;
@end

static LSApplicationProxy *CIProxy(NSString *bundleID);
static void CIRunKillall(NSString *processName);
static void CITerminateBundle(NSString *bundleID);
static void CITerminateRelatedBundles(NSString *bundleID);
static BOOL CIKeychainTextMatchesBundle(NSString *text, NSString *bundleID);
static BOOL CIPathSafeToMutate(NSString *path);
static NSArray<NSString *> *CIKnownKeychainServices(NSString *bundleID);
static void CIWipeKnownKeychainServices(NSString *bundleID);
static void CISettleForDisk(NSString *bundleID);
static void CISettleAfterDisk(NSString *bundleID);
static NSDictionary<NSString *, NSString *> *CIAllGroupPaths(NSString *bundleID);
static NSDictionary<NSString *, NSString *> *CIPluginPaths(NSString *bundleID);
static BOOL CIBundleIsTikTokFamily(NSString *bundleID);
static BOOL CIBundleIsShopeeFamily(NSString *bundleID);
static BOOL CIBundleIsSticky(NSString *bundleID);
static void CIKillShopeeHard(void);
static NSArray<NSString *> *CIKnownShopeeBundles(void);
static BOOL CIBundleLooksDirty(NSString *bundleID);
static void CIKillTikTokHard(void);
static void CIKillEraseTargets(NSArray<NSString *> *targets);
static NSArray<NSString *> *CIExpandEraseTargets(NSArray<NSString *> *bundleIDs);
static NSArray<NSString *> *CIExpandBackupTargets(NSArray<NSString *> *bundleIDs);
static NSString *CIKeychainRestoreFamilyKey(NSString *bundleID);
static NSArray<NSString *> *CIEraseOrder(NSArray<NSString *> *targets);
static NSArray<NSString *> *CIDataContainerRoots(void);
static NSString *CIResolveBundleID(NSString *bundleID);
static NSDictionary<NSString *, NSString *> *CIScanContainersMatching(NSArray<NSString *> *roots, BOOL (^pred)(NSString *ident));
static void CIContainerIndexClear(void);
static void CIKeychainSQLSettle(void);
static BOOL CIRmRf(NSString *path);
static BOOL CIStashDelete(NSString *path);
static void CIChownMobileR(NSString *path);

static NSArray<NSString *> *CIKeychainCollectAgrps(NSString *bundleID);
static NSString *CITeamIDFromAppID(NSString *value);
static id CIKeychainSQLBackupValue(NSDictionary *cols, NSString *canonical);
static NSString *CIKeychainSQLCanonicalColumn(NSString *key);
static NSString *CIKeychainSQLQuoteIdentifier(NSString *value);
static NSDictionary<NSString *, NSString *> *CIKeychainSQLTableColumns(sqlite3 *db, NSString *table);
static NSString *CIKeychainSQLActualColumn(NSDictionary<NSString *, NSString *> *schema, NSString *canonical);


static NSError *CIError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kChengBackupErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Error"}];
}

NSString *ChengIOSBackupErrorMessage(NSError *error) {
    if (!error) {
        return @"";
    }
    return error.localizedDescription ?: @"Error";
}

static NSString *CIFirstExistingDir(NSArray<NSString *> *candidates, BOOL create) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        BOOL dir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&dir] && dir) {
            return path;
        }
    }
    if (!create) {
        return candidates.firstObject;
    }
    for (NSString *path in candidates) {
        NSString *parent = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:parent]) {
            continue;
        }
        NSError *err = nil;
        if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&err] ||
            ([fm fileExistsAtPath:path])) {
            return path;
        }
    }
    NSString *fallback = candidates.lastObject ?: @"/var/mobile/Documents/ChengIOS";
    [fm createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil];
    return fallback;
}

static NSArray<NSString *> *CIBackupRootCandidates(void) {
    return @[
        @"/var/mobile/Media/ChengIOS/Backups",
        @"/private/var/mobile/Media/ChengIOS/Backups",
        @"/var/mobile/Documents/ChengIOS/Backups",
        @"/var/jb/var/mobile/Documents/ChengIOS/Backups"
    ];
}

static BOOL CIValidBackupID(NSString *backupID) {
    if (backupID.length < 4 || backupID.length > 80) {
        return NO;
    }
    if ([backupID hasPrefix:@"."] || [backupID containsString:@".."] ||
        [backupID containsString:@"/"] || [backupID containsString:@"\\"]) {
        return NO;
    }
    for (NSUInteger i = 0; i < backupID.length; i++) {
        unichar c = [backupID characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
        if (!ok) {
            return NO;
        }
    }
    return YES;
}

NSString *ChengIOSBackupRoot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *preferred = @[
        @"/var/mobile/Media/ChengIOS/Backups",
        @"/private/var/mobile/Media/ChengIOS/Backups"
    ];
    for (NSString *path in preferred) {
        BOOL dir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&dir] && dir) {
            return path;
        }
        if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil] ||
            [fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return CIFirstExistingDir(CIBackupRootCandidates(), YES);
}

static NSString *CIBackupDirForID(NSString *backupID) {
    if (!CIValidBackupID(backupID)) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in CIBackupRootCandidates()) {
        NSString *dir = [root stringByAppendingPathComponent:backupID];
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"meta.plist"]] ||
            [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"profile.plist"]]) {
            return dir;
        }
    }
    return nil;
}

static NSString *CISanitizeName(NSString *name) {
    NSString *raw = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) {
        return @"";
    }
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length && out.length < 64; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == ' ' || c == '+') {
            [out appendFormat:@"%C", c];
        } else if (c == '/' || c == '\\' || c == ':') {
            [out appendString:@"-"];
        }
    }
    while ([out hasPrefix:@"."]) {
        [out deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    return out;
}

static NSString *CINewBackupID(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *path = [[ChengIOSBackupRoot() stringByAppendingPathComponent:stamp] stringByAppendingPathComponent:@"meta.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return stamp;
    }
    return [NSString stringWithFormat:@"%@-%u", stamp, arc4random_uniform(900) + 100];
}

NSString *ChengIOSSuggestedBackupName(void) {
    NSDictionary *profile = ChengIOSLoadSavedProfile();
    NSString *product = profile[@"_product"] ?: profile[@"spoofedModel"] ?: @"iPhone";
    NSString *iso = [profile[@"isoCountryCode"] uppercaseString] ?: @"";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"MM-dd HH:mm";
    NSString *when = [fmt stringFromDate:[NSDate date]];
    if (iso.length > 0) {
        return [NSString stringWithFormat:@"%@ %@ %@", when, product, iso];
    }
    return [NSString stringWithFormat:@"%@ %@", when, product];
}

BOOL ChengIOSBundleIsSafari(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    NSString *low = bundleID.lowercaseString;
    return [low isEqualToString:@"com.apple.mobilesafari"] ||
           [low isEqualToString:@"com.apple.safariviewservice"] ||
           [low isEqualToString:@"com.apple.safari"] ||
           [low isEqualToString:@"com.apple.webapp"] ||
           [low hasPrefix:@"com.apple.mobilesafari."];
}

BOOL ChengIOSBundleIsProtected(NSString *bundleID) {
    if (bundleID.length == 0) {
        return YES;
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        return NO;
    }
    NSString *low = bundleID.lowercaseString;
    NSArray<NSString *> *blocked = @[
        @"com.apple.springboard",
        @"com.apple.preferences",
        @"com.apple.backboardd",
        @"com.apple.webkit",
        @"com.vinhnv2507.chengios.app",
        @"com.saurik.cydia",
        @"org.coolstar.sileo",
        @"xyz.willy.zebra",
        @"com.tigisoftware.filza",
        @"com.opa334.altlist",
        @"com.opa334.trollstore",
        @"ws.hbang.newterm2",
        @"com.apptapp.installer",
        @"org.coolstar.electra",
        @"science.xnu.undecimus"
    ];
    if ([blocked containsObject:low]) {
        return YES;
    }
    if ([low hasPrefix:@"com.apple."]) {
        return YES;
    }
    if ([low hasPrefix:@"com.vinhnv2507.chengios"]) {
        return YES;
    }
    if ([low hasPrefix:@"com.saurik."] || [low hasPrefix:@"org.coolstar.sileo"] ||
        [low hasPrefix:@"xyz.willy.zebra"]) {
        return YES;
    }
    return NO;
}

static BOOL CIAppEnabledFlag(id value) {
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [value[@"enabled"] boolValue] || [value[@"tweakEnabled"] boolValue] || [value[@"on"] boolValue];
    }
    return NO;
}

NSArray<NSString *> *ChengIOSSelectedBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    id enabled = ChengIOSPrefValue(@"appEnabled");
    if ([enabled isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in enabled) {
            if (![key isKindOfClass:[NSString class]] || key.length == 0) {
                continue;
            }
            if (CIAppEnabledFlag(enabled[key]) && ![seen containsObject:key]) {
                [out addObject:key];
                [seen addObject:key];
            }
        }
    }
    id spoofed = ChengIOSPrefValue(@"spoofedApps");
    if ([spoofed isKindOfClass:[NSArray class]]) {
        for (id item in spoofed) {
            if (![item isKindOfClass:[NSString class]] || [item length] == 0) {
                continue;
            }
            if (![seen containsObject:item]) {
                [out addObject:item];
                [seen addObject:item];
            }
        }
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

NSArray<NSString *> *ChengIOSUserSelectedBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *bundle in ChengIOSSelectedBundleIDs()) {
        NSString *resolved = CIResolveBundleID(bundle) ?: bundle;
        NSString *use = resolved.length ? resolved : bundle;
        if (use.length == 0 || [seen containsObject:use] || ChengIOSBundleIsProtected(use)) {
            continue;
        }
        [seen addObject:use];
        [out addObject:use];
    }
    return out;
}

NSString *ChengIOSCanonicalBundleID(NSString *bundleID) {
    return CIResolveBundleID(bundleID);
}

NSString *ChengIOSBundleDisplayName(NSString *bundleID) {
    if (bundleID.length == 0) {
        return @"";
    }
    LSApplicationProxy *proxy = CIProxy(CIResolveBundleID(bundleID));
    if (proxy.localizedName.length > 0) {
        return proxy.localizedName;
    }
    NSString *low = bundleID.lowercaseString;
    if ([low containsString:@"facebook"]) return @"Facebook";
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."]) return @"Shopee";
    if (CIBundleIsTikTokFamily(bundleID) || [low hasPrefix:@"com.ss.iphone."] || [low hasPrefix:@"com.zhiliaoapp."]) return @"TikTok";
    if ([low containsString:@"safari"]) return @"Safari";
    if ([low containsString:@"aida64"] || [low containsString:@"finalwire"]) return @"AIDA64";
    if ([low containsString:@"instagram"]) return @"Instagram";
    NSString *tail = bundleID.pathExtension.length ? bundleID.pathExtension : bundleID;
    if ([tail isEqualToString:@"vn"] || [tail isEqualToString:@"go"] || tail.length <= 2) {
        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            return parts[parts.count - 2];
        }
    }
    return tail;
}

NSString *ChengIOSBundleDisplayTitle(NSString *bundleID) {
    NSString *resolved = CIResolveBundleID(bundleID) ?: bundleID;
    NSString *name = ChengIOSBundleDisplayName(resolved);
    if (name.length == 0) {
        return resolved ?: @"";
    }
    if ([name isEqualToString:resolved]) {
        return resolved;
    }
    return [NSString stringWithFormat:@"%@ (%@)", name, resolved];
}

static NSString *CIShortAppTag(NSString *bundleID) {
    if (bundleID.length == 0) {
        return @"";
    }
    NSString *low = bundleID.lowercaseString;
    if ([low containsString:@"facebook"]) return @"FB";
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."]) return @"Shopee";
    if ([low containsString:@"tiktok"] || [low containsString:@"musically"] || [low containsString:@"aweme"] || [low hasPrefix:@"com.ss.iphone."] || [low hasPrefix:@"com.zhiliaoapp."]) return @"TT";
    if ([low containsString:@"safari"]) return @"Safari";
    if ([low containsString:@"aida64"] || [low containsString:@"finalwire"]) return @"AIDA";
    if ([low containsString:@"instagram"]) return @"IG";
    NSString *name = ChengIOSBundleDisplayName(bundleID);
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (name.length > 8) {
        name = [name substringToIndex:8];
    }
    return name.length ? name : @"App";
}

NSString *ChengIOSSuggestedBackupNameForBundles(NSArray<NSString *> *bundleIDs) {
    NSString *base = ChengIOSSuggestedBackupName();
    if (bundleIDs.count == 0) {
        return base;
    }
    NSMutableArray *tags = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *bid in bundleIDs) {
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) {
            continue;
        }
        NSString *tag = CIShortAppTag(bid);
        if (tag.length == 0 || [seen containsObject:tag]) {
            continue;
        }
        [seen addObject:tag];
        [tags addObject:tag];
    }
    if (tags.count == 0) {
        return base;
    }
    if (tags.count > 4) {
        NSUInteger extra = tags.count - 3;
        NSArray *head = [tags subarrayWithRange:NSMakeRange(0, 3)];
        tags = [head mutableCopy];
        [tags addObject:[NSString stringWithFormat:@"%lu", (unsigned long)extra]];
    }
    return [NSString stringWithFormat:@"%@ %@", base, [tags componentsJoinedByString:@"+"]];
}

void ChengIOSRequestRespring(void) {
    pid_t pid = 0;
    const char *candidates[] = {
        "/var/jb/usr/bin/sbreload",
        "/usr/bin/sbreload",
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        NULL
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        if (access(candidates[i], X_OK) != 0) {
            continue;
        }
        if (strstr(candidates[i], "sbreload") != NULL) {
            const char *args[] = {candidates[i], NULL};
            if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)args, environ) == 0) {
                return;
            }
        } else {
            const char *args[] = {candidates[i], "-9", "SpringBoard", NULL};
            if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)args, environ) == 0) {
                return;
            }
        }
    }
}


static LSApplicationProxy *CIProxy(NSString *bundleID) {
    if (bundleID.length == 0) {
        return nil;
    }
    Class cls = objc_getClass("LSApplicationProxy");
    if (!cls || ![cls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        return nil;
    }
    LSApplicationProxy *proxy = [cls applicationProxyForIdentifier:bundleID];
    NSString *ident = proxy.applicationIdentifier ?: proxy.bundleIdentifier;
    if (ident.length == 0) {
        return nil;
    }
    return proxy;
}

static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *gCIContainerIndex;

static void CIContainerIndexClear(void) {
    gCIContainerIndex = nil;
}

static NSDictionary<NSString *, NSString *> *CIContainerIndexForRoot(NSString *root) {
    if (root.length == 0) {
        return @{};
    }
    if (!gCIContainerIndex) {
        gCIContainerIndex = [NSMutableDictionary dictionary];
    }
    NSDictionary<NSString *, NSString *> *hit = gCIContainerIndex[root];
    if (hit) {
        return hit;
    }
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if (uuid.length < 30) {
            continue;
        }
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        NSString *metaPath = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *found = meta[@"MCMMetadataIdentifier"];
        if (found.length == 0) {
            id info = meta[@"MCMMetadataInfo"];
            if ([info isKindOfClass:[NSDictionary class]]) {
                found = info[@"MCMMetadataIdentifier"];
            }
        }
        if (found.length > 0 && !map[found]) {
            map[found] = dir;
        }
    }
    gCIContainerIndex[root] = map;
    return map;
}

static NSString *CIScanContainer(NSArray<NSString *> *roots, NSString *identifier) {
    if (identifier.length == 0) {
        return nil;
    }
    for (NSString *root in roots) {
        NSString *path = CIContainerIndexForRoot(root)[identifier];
        if (path.length > 0) {
            return path;
        }
    }
    return nil;
}

static NSArray<NSString *> *CIDataContainerRoots(void) {
    return @[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application"
    ];
}

static BOOL CIBundleHasContainer(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    if (CIProxy(bundleID)) {
        return YES;
    }
    return CIScanContainer(CIDataContainerRoots(), bundleID).length > 0;
}

static NSString *CIResolveBundleID(NSString *bundleID) {
    if (bundleID.length == 0) {
        return bundleID;
    }
    if (CIBundleHasContainer(bundleID)) {
        return bundleID;
    }
    NSString *low = bundleID.lowercaseString ?: @"";
    NSMutableArray<NSString *> *prefixHits = [NSMutableArray array];
    for (NSString *root in CIDataContainerRoots()) {
        NSDictionary<NSString *, NSString *> *index = CIContainerIndexForRoot(root);
        for (NSString *ident in index) {
            NSString *il = ident.lowercaseString ?: @"";
            if ([il isEqualToString:low]) {
                return ident;
            }
            if (low.length >= 10 && [il hasPrefix:low]) {
                [prefixHits addObject:ident];
            }
        }
    }
    if (prefixHits.count == 1) {
        return prefixHits.firstObject;
    }
    BOOL tiktokish = CIBundleIsTikTokFamily(bundleID) ||
                     [low hasPrefix:@"com.ss.iphone.ugc."] ||
                     [low hasPrefix:@"com.zhiliaoapp."];
    if (tiktokish) {
        NSArray<NSString *> *cands = @[
            @"com.ss.iphone.ugc.Aweme",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go"
        ];
        for (NSString *cand in cands) {
            if (CIBundleHasContainer(cand)) {
                return cand;
            }
        }
        for (NSString *root in CIDataContainerRoots()) {
            NSDictionary<NSString *, NSString *> *index = CIContainerIndexForRoot(root);
            for (NSString *ident in index) {
                if (CIBundleIsTikTokFamily(ident)) {
                    return ident;
                }
            }
        }
        return @"com.ss.iphone.ugc.Aweme";
    }
    BOOL shopeeish = CIBundleIsShopeeFamily(bundleID) ||
                     [low hasPrefix:@"com.beeasy."] ||
                     [low hasPrefix:@"com.shopee."] ||
                     [low containsString:@"shopee"];
    if (shopeeish) {
        for (NSString *cand in CIKnownShopeeBundles()) {
            if (CIBundleHasContainer(cand)) {
                return cand;
            }
        }
        for (NSString *root in CIDataContainerRoots()) {
            NSDictionary<NSString *, NSString *> *index = CIContainerIndexForRoot(root);
            for (NSString *ident in index) {
                if (CIBundleIsShopeeFamily(ident)) {
                    return ident;
                }
            }
        }
        return @"com.beeasy.shopee.vn";
    }
    if (prefixHits.count > 0) {
        return prefixHits.firstObject;
    }
    return bundleID;
}

static NSString *CIDataPath(NSString *bundleID) {
    bundleID = CIResolveBundleID(bundleID);
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSString *path = proxy.dataContainerURL.path;
    BOOL dir = NO;
    if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] && dir) {
        return path;
    }
    return CIScanContainer(CIDataContainerRoots(), bundleID);
}

static NSDictionary<NSString *, NSString *> *CIGroupPaths(NSString *bundleID) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *urls = nil;
    if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
        urls = proxy.groupContainerURLs;
    }
    [urls enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        NSString *group = [key isKindOfClass:[NSString class]] ? key : nil;
        NSString *path = nil;
        if ([obj isKindOfClass:[NSURL class]]) {
            path = [(NSURL *)obj path];
        } else if ([obj isKindOfClass:[NSString class]]) {
            path = obj;
        }
        if (group.length > 0 && path.length > 0) {
            map[group] = path;
        }
    }];
    if (map.count == 0) {
        NSArray *groups = nil;
        id ents = nil;
        if ([proxy respondsToSelector:@selector(entitlements)]) {
            ents = proxy.entitlements;
        }
        if ([ents isKindOfClass:[NSDictionary class]]) {
            groups = ents[@"com.apple.security.application-groups"];
        }
        if ([groups isKindOfClass:[NSArray class]]) {
            for (id group in groups) {
                if (![group isKindOfClass:[NSString class]]) {
                    continue;
                }
                NSString *path = CIScanContainer(@[
                    @"/var/mobile/Containers/Shared/AppGroup",
                    @"/private/var/mobile/Containers/Shared/AppGroup"
                ], group);
                if (path.length > 0) {
                    map[group] = path;
                }
            }
        }
    }
    return map;
}

static BOOL CIIsReservedName(NSString *name) {
    if (name.length == 0) {
        return YES;
    }
    return [name isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"] ||
           [name hasPrefix:@".com.apple.mobile_container_manager"];
}

static NSArray<NSString *> *CIAppDataSubdirs(void) {
    return @[ @"Documents", @"Library", @"tmp", @"SystemData", @"StoreKit" ];
}

static const uid_t kCIMobileUID = 501;
static const gid_t kCIMobileGID = 501;
static unsigned long long gCICopyBytes = 0;
static NSUInteger gCICopyFiles = 0;
static NSUInteger gCICopyFailed = 0;
static NSMutableDictionary *gCILastRestoreStats = nil;
static BOOL gCIFastErase = NO;

static void CICopyStatsReset(void) {
    gCICopyBytes = 0;
    gCICopyFiles = 0;
    gCICopyFailed = 0;
}

NSDictionary *ChengIOSLastRestoreStats(void) {
    return [gCILastRestoreStats copy];
}

static void CIClearItemFlags(NSString *path) {
    if (path.length == 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSFileImmutable] = @NO;
    attrs[NSFileAppendOnly] = @NO;
    attrs[NSFilePosixPermissions] = @0777;
    [fm setAttributes:attrs ofItemAtPath:path error:nil];
    const char *raw = path.fileSystemRepresentation;
    if (raw) {
        chmod(raw, 0777);
    }
}

static void CIProtectItem(NSString *path) {
    if (path.length == 0) {
        return;
    }
    NSError *err = nil;
    [[NSFileManager defaultManager] setAttributes:@{
        NSFileOwnerAccountID: @(kCIMobileUID),
        NSFileGroupOwnerAccountID: @(kCIMobileGID),
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication
    } ofItemAtPath:path error:&err];
    (void)err;
}

static void CIChownTree(NSString *path) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    struct stat st;
    memset(&st, 0, sizeof(st));
    if (raw) {
        lchown(raw, kCIMobileUID, kCIMobileGID);
        if (lstat(raw, &st) == 0) {
            mode_t mode = st.st_mode;
            if (S_ISDIR(mode)) {
                if ([[path lastPathComponent] isEqualToString:@"tmp"]) {
                    chmod(raw, 0777);
                } else {
                    chmod(raw, (mode | 0700) & 0777);
                }
            } else if (S_ISREG(mode)) {
                chmod(raw, mode | 0600);
            }
        }
    }
    if (!S_ISLNK(st.st_mode)) {
        CIProtectItem(path);
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSString *type = attrs.fileType;
    if ([type isEqualToString:NSFileTypeDirectory]) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
            CIChownTree([path stringByAppendingPathComponent:name]);
        }
    }
}

static BOOL CIRemoveDeep(NSString *path) {
    if (path.length == 0) {
        return YES;
    }
    if (CIIsReservedName(path.lastPathComponent)) {
        return YES;
    }
    CIClearItemFlags(path);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (!attrs) {
        return YES;
    }
    BOOL ok = YES;
    if ([attrs.fileType isEqualToString:NSFileTypeDirectory]) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
            if (CIIsReservedName(name)) {
                continue;
            }
            if (!CIRemoveDeep([path stringByAppendingPathComponent:name])) {
                ok = NO;
            }
        }
    }
    if (![fm removeItemAtPath:path error:nil]) {
        CIClearItemFlags(path);
        if (![fm removeItemAtPath:path error:nil]) {
            ok = NO;
        }
    }
    return ok;
}

static BOOL CIEmptyDir(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir]) {
        return YES;
    }
    if (!isDir) {
        CIClearItemFlags(dir);
        return [fm removeItemAtPath:dir error:nil];
    }
    CIClearItemFlags(dir);
    BOOL ok = YES;
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (CIIsReservedName(name)) {
            continue;
        }
        if (!CIRemoveDeep([dir stringByAppendingPathComponent:name])) {
            ok = NO;
        }
    }
    return ok;
}

static BOOL CIPathSafeToMutate(NSString *path) {
    if (path.length < 28) {
        return NO;
    }
    NSString *low = path.lowercaseString;
    if ([low containsString:@"/chengios/backups"]) {
        return NO;
    }
    if ([low hasPrefix:@"/var/tmp/chengios-trash/"] ||
        [low hasPrefix:@"/private/var/tmp/chengios-trash/"] ||
        [low hasPrefix:@"/tmp/chengios-trash/"] ||
        [low hasPrefix:@"/private/tmp/chengios-trash/"]) {
        return YES;
    }
    NSArray<NSString *> *parts = path.pathComponents;
    if ([low containsString:@"/containers/data/application/"] && parts.count >= 7) {
        return YES;
    }
    if ([low containsString:@"/containers/shared/appgroup/"] && parts.count >= 7) {
        return YES;
    }
    if ([low containsString:@"/library/caches/"] && parts.count >= 6) {
        return YES;
    }
    if ([low containsString:@"/library/splashboard/snapshots/"] && parts.count >= 6) {
        return YES;
    }
    if ([low containsString:@"/library/preferences/"] && [low hasSuffix:@".plist"]) {
        return YES;
    }
    if ([low containsString:@"/library/saved application state/"] && parts.count >= 6) {
        return YES;
    }
    if ([low containsString:@"/containers/data/pluginkitplugin/"] && parts.count >= 7) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/safari"] || [low hasPrefix:@"/private/var/mobile/library/safari"]) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/cookies"] || [low hasPrefix:@"/private/var/mobile/library/cookies"]) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/webkit"] || [low hasPrefix:@"/private/var/mobile/library/webkit"]) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/httpstorages"] || [low hasPrefix:@"/private/var/mobile/library/httpstorages"]) {
        return YES;
    }
    if ([low containsString:@"/library/safarisafebrowsing"]) {
        return YES;
    }
    if ([low containsString:@"/library/application support/com.facebook"] ||
        [low containsString:@"/library/application support/facebook"] ||
        [low containsString:@"/library/application support/com.shopee"] ||
        [low containsString:@"/library/application support/com.beeasy"] ||
        [low containsString:@"/library/application support/tongdun"] ||
        [low containsString:@"/library/application support/trustdecision"] ||
        [low containsString:@"/library/application support/tiktok"] ||
        [low containsString:@"/library/application support/musically"] ||
        [low containsString:@"/library/application support/aweme"] ||
        [low containsString:@"/library/application support/com.zhiliao"] ||
        [low containsString:@"/library/application support/bytedance"]) {
        return parts.count >= 6;
    }
    return NO;
}

static BOOL CIEmptyContainer(NSString *path) {
    if (!CIPathSafeToMutate(path)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        return YES;
    }
    BOOL ok = YES;
    for (NSString *sub in CIAppDataSubdirs()) {
        NSString *child = [path stringByAppendingPathComponent:sub];
        if ([fm fileExistsAtPath:child]) {
            if (!CIStashDelete(child)) {
                ok = NO;
            }
        }
        [fm createDirectoryAtPath:child withIntermediateDirectories:YES attributes:nil error:nil];
        const char *raw = child.fileSystemRepresentation;
        if (raw) {
            lchown(raw, kCIMobileUID, kCIMobileGID);
            chmod(raw, [sub isEqualToString:@"tmp"] ? 0777 : 0755);
        }
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
        if (CIIsReservedName(name) || [CIAppDataSubdirs() containsObject:name]) {
            continue;
        }
        if (!CIStashDelete([path stringByAppendingPathComponent:name])) {
            ok = NO;
        }
    }
    return ok;
}

static BOOL CITreeHasFiles(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return NO;
    }
    if (!isDir) {
        return YES;
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
        if (CIIsReservedName(name)) {
            continue;
        }
        return YES;
    }
    return NO;
}

static int CIRunTool(const char *bin, const char *arg1, const char *arg2, const char *arg3) {
    if (!bin || access(bin, X_OK) != 0) {
        return -1;
    }
    pid_t pid = 0;
    const char *args[5];
    int n = 0;
    args[n++] = bin;
    if (arg1) {
        args[n++] = arg1;
    }
    if (arg2) {
        args[n++] = arg2;
    }
    if (arg3) {
        args[n++] = arg3;
    }
    args[n] = NULL;
    if (posix_spawn(&pid, bin, NULL, NULL, (char *const *)args, environ) != 0) {
        return -1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

static BOOL CIRmRf(NSString *path) {
    if (path.length == 0 || !CIPathSafeToMutate(path)) {
        return NO;
    }
    CIClearItemFlags(path);
    const char *raw = path.fileSystemRepresentation;
    if (!raw) {
        return NO;
    }
    int rc = CIRunTool("/bin/rm", "-rf", raw, NULL);
    if (rc != 0) {
        rc = CIRunTool("/var/jb/bin/rm", "-rf", raw, NULL);
    }
    if (rc != 0) {
        rc = CIRunTool("/usr/bin/rm", "-rf", raw, NULL);
    }
    if (rc == 0) {
        return YES;
    }
    return CIRemoveDeep(path);
}

static void CIRmRfAsync(NSString *path) {
    if (path.length == 0 || !CIPathSafeToMutate(path)) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signal(SIGCHLD, SIG_IGN);
    });
    const char *raw = path.fileSystemRepresentation;
    if (!raw) {
        return;
    }
    pid_t pid = 0;
    const char *bins[] = { "/bin/rm", "/var/jb/bin/rm", "/var/jb/usr/bin/rm", "/usr/bin/rm", NULL };
    for (int i = 0; bins[i]; i++) {
        if (access(bins[i], X_OK) != 0) {
            continue;
        }
        const char *args[] = { bins[i], "-rf", raw, NULL };
        if (posix_spawn(&pid, bins[i], NULL, NULL, (char *const *)args, environ) == 0) {
            return;
        }
    }
    CIRmRf(path);
}

static BOOL CIStashDelete(NSString *path) {
    if (path.length == 0 || !CIPathSafeToMutate(path)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        return YES;
    }
    CIClearItemFlags(path);
    NSString *root = @"/var/tmp/ChengIOS-trash";
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    const char *rootRaw = root.fileSystemRepresentation;
    if (rootRaw) {
        chmod(rootRaw, 0777);
    }
    NSString *stash = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%u-%u",
        (unsigned)[[NSDate date] timeIntervalSince1970], arc4random()]];
    const char *from = path.fileSystemRepresentation;
    const char *to = stash.fileSystemRepresentation;
    if (from && to && rename(from, to) == 0) {
        CIRmRfAsync(stash);
        return YES;
    }
    return CIRmRf(path);
}

static void CIChownMobileR(NSString *path) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (!raw) {
        return;
    }
    if (CIRunTool("/usr/sbin/chown", "-R", "501:501", raw) == 0) {
        return;
    }
    if (CIRunTool("/var/jb/usr/sbin/chown", "-R", "501:501", raw) == 0) {
        return;
    }
    CIChownTree(path);
}

static BOOL CISkipBackupName(NSString *name) {
    NSString *low = name.lowercaseString ?: @"";
    if (low.length == 0) {
        return YES;
    }
    return [low isEqualToString:@"logs"] ||
           [low isEqualToString:@"crashreporter"] ||
           [low isEqualToString:@"fscacheddata"] ||
           [low isEqualToString:@"gpucache"] ||
           [low isEqualToString:@"gpu_cache"] ||
           [low isEqualToString:@"code cache"] ||
           [low isEqualToString:@"cachestorage"] ||
           [low isEqualToString:@"networkcache"] ||
           [low isEqualToString:@"offlinewebapplicationcache"] ||
           [low isEqualToString:@"saved application state"] ||
           [low isEqualToString:@"splashboard"] ||
           [low isEqualToString:@"com.apple.nsurlsessiond"] ||
           [low hasPrefix:@"com.apple.webkit.networking"] ||
           [low hasSuffix:@".log"];
}

static unsigned long long CICopyOneFile(NSString *from, NSString *to) {
    const char *src = from.fileSystemRepresentation;
    const char *dst = to.fileSystemRepresentation;
    if (!src || !dst) {
        gCICopyFailed += 1;
        return 0;
    }
    CIClearItemFlags(from);
    unlink(dst);
    int rc = copyfile(src, dst, NULL, COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_UNLINK);
    if (rc != 0) {
        rc = copyfile(src, dst, NULL, COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_UNLINK);
    }
    if (rc != 0) {
        rc = copyfile(src, dst, NULL, COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW | COPYFILE_UNLINK);
    }
    if (rc != 0) {
        NSError *err = nil;
        if (![[NSFileManager defaultManager] copyItemAtPath:from toPath:to error:&err]) {
            gCICopyFailed += 1;
            return 0;
        }
    }
    gCICopyFiles += 1;
    struct stat st;
    memset(&st, 0, sizeof(st));
    if (lstat(dst, &st) == 0 && S_ISREG(st.st_mode)) {
        gCICopyBytes += (unsigned long long)st.st_size;
        return (unsigned long long)st.st_size;
    }
    return 0;
}

static unsigned long long CICopyTree(NSString *from, NSString *to) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (CIIsReservedName(from.lastPathComponent) || CISkipBackupName(from.lastPathComponent)) {
        return 0;
    }
    struct stat st;
    memset(&st, 0, sizeof(st));
    const char *src = from.fileSystemRepresentation;
    if (!src || lstat(src, &st) != 0) {
        return 0;
    }
    if (S_ISDIR(st.st_mode)) {
        [fm createDirectoryAtPath:[to stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:to error:nil];
        int rc = copyfile(src, to.fileSystemRepresentation, NULL,
                          COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW);
        if (rc != 0) {
            rc = copyfile(src, to.fileSystemRepresentation, NULL,
                          COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW);
        }
        if (rc == 0) {
            gCICopyFiles += 1;
            unsigned long long bytes = 0;
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:to];
            NSUInteger n = 0;
            for (NSString *rel in en) {
                (void)rel;
                n += 1;
                if (n >= 8) {
                    [en skipDescendants];
                    break;
                }
            }
            struct stat dstst;
            memset(&dstst, 0, sizeof(dstst));
            if (lstat(to.fileSystemRepresentation, &dstst) == 0) {
                bytes = (unsigned long long)dstst.st_size;
            }
            gCICopyBytes += bytes;
            return bytes > 0 ? bytes : 1;
        }
        [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil];
        unsigned long long total = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:from error:nil]) {
            if (CIIsReservedName(name) || CISkipBackupName(name)) {
                continue;
            }
            total += CICopyTree([from stringByAppendingPathComponent:name],
                                [to stringByAppendingPathComponent:name]);
        }
        return total;
    }
    if (S_ISSOCK(st.st_mode) || S_ISFIFO(st.st_mode) || S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)) {
        return 0;
    }
    NSString *parent = [to stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    return CICopyOneFile(from, to);
}

static unsigned long long CIBackupContainer(NSString *fromContainer, NSString *toDataDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long bytes = 0;
    [fm createDirectoryAtPath:toDataDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:fromContainer error:nil]) {
        if (CIIsReservedName(name) || CISkipBackupName(name)) {
            continue;
        }
        if ([name isEqualToString:@"Library"]) {
            NSString *libFrom = [fromContainer stringByAppendingPathComponent:@"Library"];
            NSString *libTo = [toDataDir stringByAppendingPathComponent:@"Library"];
            [fm createDirectoryAtPath:libTo withIntermediateDirectories:YES attributes:nil error:nil];
            for (NSString *child in [fm contentsOfDirectoryAtPath:libFrom error:nil]) {
                if (CIIsReservedName(child) || CISkipBackupName(child)) {
                    continue;
                }
                if ([child isEqualToString:@"WebKit"]) {
                    NSString *wkFrom = [libFrom stringByAppendingPathComponent:child];
                    NSString *wkTo = [libTo stringByAppendingPathComponent:child];
                    [fm createDirectoryAtPath:wkTo withIntermediateDirectories:YES attributes:nil error:nil];
                    for (NSString *wkChild in [fm contentsOfDirectoryAtPath:wkFrom error:nil]) {
                        if (CIIsReservedName(wkChild) || CISkipBackupName(wkChild)) {
                            continue;
                        }
                        bytes += CICopyTree([wkFrom stringByAppendingPathComponent:wkChild],
                                            [wkTo stringByAppendingPathComponent:wkChild]);
                    }
                    continue;
                }
                bytes += CICopyTree([libFrom stringByAppendingPathComponent:child],
                                    [libTo stringByAppendingPathComponent:child]);
            }
            continue;
        }
        bytes += CICopyTree([fromContainer stringByAppendingPathComponent:name],
                            [toDataDir stringByAppendingPathComponent:name]);
    }
    return bytes;
}

static BOOL CIRestoreContainer(NSString *saved, NSString *live) {
    if (!CIPathSafeToMutate(live)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL savedDir = NO;
    if (![fm fileExistsAtPath:saved isDirectory:&savedDir] || !savedDir) {
        return NO;
    }
    if (!CITreeHasFiles(saved)) {
        return NO;
    }
    CIEmptyContainer(live);
    for (NSString *name in [fm contentsOfDirectoryAtPath:saved error:nil]) {
        if (CIIsReservedName(name)) {
            continue;
        }
        NSString *dst = [live stringByAppendingPathComponent:name];
        CICopyTree([saved stringByAppendingPathComponent:name], dst);
    }
    CIChownMobileR(live);
    return gCICopyFailed == 0 || gCICopyFiles > 0;
}


static BOOL CIWipeContents(NSString *path) {
    if (!CIPathSafeToMutate(path)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return YES;
    }
    if (!isDir) {
        CIClearItemFlags(path);
        return [fm removeItemAtPath:path error:nil];
    }
    if (gCIFastErase) {
        BOOL ok = YES;
        for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
            if (CIIsReservedName(name)) {
                continue;
            }
            if (!CIStashDelete([path stringByAppendingPathComponent:name])) {
                ok = NO;
            }
        }
        return ok;
    }
    return CIEmptyDir(path);
}

static void CIRunKillall(NSString *processName) {
    if (processName.length == 0 || [processName containsString:@"/"]) {
        return;
    }
    pid_t pid = 0;
    const char *bins[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        "/var/jb/bin/killall",
        "/usr/bin/killall",
        NULL
    };
    for (int i = 0; bins[i]; i++) {
        if (access(bins[i], X_OK) != 0) {
            continue;
        }
        const char *args[] = {bins[i], "-9", processName.UTF8String, NULL};
        if (posix_spawn(&pid, bins[i], NULL, NULL, (char *const *)args, environ) == 0) {
            int status = 0;
            waitpid(pid, &status, 0);
            return;
        }
    }
}

static void CISettleForDisk(NSString *bundleID) {
    CITerminateRelatedBundles(bundleID);
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        CIRunKillall(@"Facebook");
        CIRunKillall(@"Messenger");
        CIRunKillall(@"MessengerLite");
    }
    if (CIBundleIsShopeeFamily(bundleID) || [low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        CIKillShopeeHard();
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"musically"] ||
        [low containsString:@"aweme"]) {
        CIKillTikTokHard();
    }
}

static void CISettleAfterDisk(NSString *bundleID) {
    CITerminateRelatedBundles(bundleID);
}

static void CIReemptyPrefs(NSString *container) {
    if (container.length == 0 || !CIPathSafeToMutate(container)) {
        return;
    }
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/Preferences"]);
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/Cookies"]);
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/HTTPStorages"]);
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/Caches"]);
}

static void CITerminateBundle(NSString *bundleID) {
    if (bundleID.length == 0) {
        return;
    }
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if ([ws respondsToSelector:@selector(terminateApplication:withOptions:)]) {
        (void)[ws terminateApplication:bundleID withOptions:nil];
    }
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSString *exec = nil;
    if ([proxy respondsToSelector:@selector(bundleExecutable)]) {
        exec = proxy.bundleExecutable;
    }
    if (exec.length > 0) {
        CIRunKillall(exec);
    }
    NSString *last = bundleID.pathExtension.length ? bundleID.pathExtension : bundleID.lastPathComponent;
    if (last.length > 0 && ![last isEqualToString:exec]) {
        CIRunKillall(last);
    }
}

static NSArray<NSString *> *CIExtraWipePaths(NSString *bundleID) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *prefsRoots = @[
        @"/var/mobile/Library/Preferences",
        @"/private/var/mobile/Library/Preferences",
        @"/var/jb/var/mobile/Library/Preferences"
    ];
    for (NSString *root in prefsRoots) {
        [paths addObject:[root stringByAppendingPathComponent:[bundleID stringByAppendingString:@".plist"]]];
    }
    NSArray<NSString *> *cacheRoots = @[
        @"/var/mobile/Library/Caches",
        @"/private/var/mobile/Library/Caches"
    ];
    for (NSString *root in cacheRoots) {
        [paths addObject:[root stringByAppendingPathComponent:bundleID]];
    }
    NSArray<NSString *> *snapRoots = @[
        @"/var/mobile/Library/SplashBoard/Snapshots",
        @"/private/var/mobile/Library/SplashBoard/Snapshots"
    ];
    for (NSString *root in snapRoots) {
        [paths addObject:[root stringByAppendingPathComponent:bundleID]];
        [paths addObject:[root stringByAppendingPathComponent:[@"sceneID:" stringByAppendingString:bundleID]]];
    }
    NSString *low = bundleID.lowercaseString;
    NSArray<NSString *> *prefRoots = @[
        @"/var/mobile/Library/Preferences",
        @"/private/var/mobile/Library/Preferences"
    ];
    NSMutableArray<NSString *> *extraNames = [NSMutableArray array];
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        [extraNames addObjectsFromArray:@[
            @"com.apple.account.Facebook.plist",
            @"com.apple.account.facebook.plist",
            @"group.com.facebook.Facebook.plist",
            @"group.com.facebook.family.plist",
            @"group.com.facebook.Messenger.plist",
            @"group.com.facebook.msysstorage.plist",
            @"group.com.facebook.platform.plist",
            @"group.com.metaplatforms.family.plist",
            @"com.facebook.Facebook.plist",
            @"com.facebook.auth.plist",
            @"com.facebook.DBL.plist",
            @"fb_dbl.plist",
            @"DBLAccounts.plist",
            @"saved_accounts.plist"
        ]];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        [extraNames addObjectsFromArray:@[
            @"group.com.shopee.vn.plist",
            @"group.com.shopee.SG.plist",
            @"group.com.shopee.id.plist",
            @"group.com.shopee.my.plist",
            @"group.com.shopee.th.plist",
            @"group.com.shopee.tw.plist",
            @"group.com.shopee.ph.plist",
            @"group.com.shopee.intlseller.plist",
            @"group.com.beeasy.marketplace.vn.plist",
            @"group.com.shopeepay.vn.plist",
            @"com.shopee.vn.plist",
            @"com.shopee.SG.plist",
            @"com.beeasy.marketplace.vn.plist",
            @"com.appsflyer.plist",
            @"com.adjust.sdk.plist",
            @"com.google.gmp.measurement.plist"
        ]];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"]) {
        [extraNames addObjectsFromArray:@[
            @"group.com.zhiliaoapp.musically.plist",
            @"com.zhiliaoapp.musically.plist",
            @"com.zhiliaoapp.musically.go.plist",
            @"group.com.ss.iphone.ugc.Aweme.plist",
            @"com.ss.iphone.ugc.Aweme.plist",
            @"AwemeUserDefaults.plist",
            @"group.com.bytedance.tiktok.plist"
        ]];
    }
    for (NSString *prefRoot in prefRoots) {
        for (NSString *name in extraNames) {
            [paths addObject:[prefRoot stringByAppendingPathComponent:name]];
        }
    }
    NSArray<NSString *> *stateRoots = @[
        @"/var/mobile/Library/Saved Application State",
        @"/private/var/mobile/Library/Saved Application State"
    ];
    for (NSString *root in stateRoots) {
        [paths addObject:[root stringByAppendingPathComponent:[bundleID stringByAppendingString:@".savedState"]]];
    }
    return paths;
}

static BOOL CIBundlesAreRelated(NSString *left, NSString *right) {
    if (left.length == 0 || right.length == 0) {
        return NO;
    }
    NSString *a = left.lowercaseString;
    NSString *b = right.lowercaseString;
    if ([a isEqualToString:b]) {
        return YES;
    }
    NSArray<NSArray<NSString *> *> *families = @[
        @[@"com.facebook.", @"com.meta."],
        @[@"com.burbn.", @"com.instagram."],
        @[@"net.whatsapp."],
        @[@"com.shopee.", @"com.beeasy.", @"com.sgs."],
        @[@"com.zhiliaoapp.", @"com.ss.iphone.", @"com.bytedance."]
    ];
    for (NSArray<NSString *> *family in families) {
        BOOL ha = NO;
        BOOL hb = NO;
        for (NSString *prefix in family) {
            if ([a hasPrefix:prefix]) {
                ha = YES;
            }
            if ([b hasPrefix:prefix]) {
                hb = YES;
            }
        }
        if (ha && hb) {
            return YES;
        }
    }
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [b componentsSeparatedByString:@"."];
    return pa.count >= 2 && pb.count >= 2 && [pa[0] isEqualToString:pb[0]] && [pa[1] isEqualToString:pb[1]];
}

static BOOL CIGroupUsedByOtherApps(NSString *group, NSString *bundleID, NSArray<NSString *> *erasing) {
    if (group.length == 0) {
        return NO;
    }
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if (![ws respondsToSelector:@selector(allInstalledApplications)]) {
        return NO;
    }
    NSArray *apps = [ws allInstalledApplications];
    for (id app in apps) {
        NSString *other = nil;
        if ([app respondsToSelector:@selector(applicationIdentifier)]) {
            other = [app applicationIdentifier];
        }
        if (other.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
            other = [app bundleIdentifier];
        }
        if (other.length == 0 || [other isEqualToString:bundleID]) {
            continue;
        }
        if ([erasing containsObject:other] || CIBundlesAreRelated(bundleID, other)) {
            continue;
        }
        NSDictionary *urls = nil;
        if ([app respondsToSelector:@selector(groupContainerURLs)]) {
            urls = [app groupContainerURLs];
        }
        if ([urls isKindOfClass:[NSDictionary class]] && urls[group]) {
            return YES;
        }
    }
    return NO;
}

static BOOL CIBundleIsFacebookFamily(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    return [low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"];
}

static BOOL CIBundleIsInstagramFamily(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    return [low hasPrefix:@"com.burbn."] || [low containsString:@"instagram"] || [low containsString:@"threads"];
}

static BOOL CIBundleIsWhatsAppFamily(NSString *bundleID) {
    return [bundleID.lowercaseString containsString:@"whatsapp"];
}

static NSString *CIKeychainRestoreFamilyKey(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString ?: @"";
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        return @"facebook";
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] ||
        [low containsString:@"musically"] || [low containsString:@"bytedance"]) {
        return @"tiktok";
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return @"shopee";
    }
    return low.length > 0 ? low : bundleID;
}

static BOOL CIKeychainAgrpIsForeignMeta(NSString *agrp, NSString *bundleID) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (low.length == 0) {
        return NO;
    }
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        if ([low containsString:@"instagram"] || [low containsString:@"burbn"] ||
            [low containsString:@"whatsapp"] || [low containsString:@"threads"]) {
            return YES;
        }
    }
    if (CIBundleIsInstagramFamily(bundleID) && ([low containsString:@"whatsapp"])) {
        return YES;
    }
    if (CIBundleIsWhatsAppFamily(bundleID) &&
        ([low containsString:@"instagram"] || [low containsString:@"burbn"] || [low containsString:@"threads"])) {
        return YES;
    }
    return NO;
}

static BOOL CIKeychainTextMatchesBundle(NSString *text, NSString *bundleID) {
    if (text.length == 0 || bundleID.length == 0) {
        return NO;
    }
    NSString *blob = text.lowercaseString;
    NSString *low = bundleID.lowercaseString;
    if ([blob containsString:low]) {
        return YES;
    }
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        NSArray<NSString *> *needles = @[
            @"facebook", @"fbauth", @"fbsdk", @"fb_user", @"fb-token", @"fbssoservice",
            @"fbssologin", @"fbsso", @"fb_session", @"fbaccesstoken",
            @"com.facebook", @"group.com.facebook", @"43aqtk3442.com.facebook",
            @"messenger.com", @"fb.com", @"facebook.com",
            @"dbl", @"devicebasedlogin", @"device_based_login", @"savedaccount",
            @"saved_account", @"accountswitcher", @"account_switcher", @"fbsaved",
            @"fbsaveduser", @"fbaccountstore", @"msysstorage", @"metaplatforms",
            @"continueas", @"lastloggedin", @"last_user",
            @"family_device", @"machine_id", @"fb_device_id", @"anonymousid"
        ];
        for (NSString *needle in needles) {
            if ([blob containsString:needle]) {
                return YES;
            }
        }
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return [blob containsString:@"shopee"] || [blob containsString:@"beeasy"] ||
               [blob containsString:@"shopeepay"] || [blob containsString:@"sea.sgo"];
    }
    if ([low hasPrefix:@"com.apple."]) {
        if (ChengIOSBundleIsSafari(bundleID)) {
            return [blob containsString:@"safari"] || [blob containsString:@"webkit"] || [blob containsString:@"mobilesafari"];
        }
        return NO;
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"musically"] ||
        [low containsString:@"aweme"] || [low containsString:@"bytedance"]) {
        NSArray<NSString *> *needles = @[
            @"tiktok", @"musically", @"zhiliao", @"aweme", @"bytedance",
            @"musical.ly", @"ttaccount", @"tt_token", @"tt_passport",
            @"aweme_passport", @"com.zhiliaoapp", @"com.ss.iphone",
            @"group.com.zhiliaoapp", @"odin_tt", @"openudid", @"krypton"
        ];
        for (NSString *needle in needles) {
            if ([blob containsString:needle]) {
                return YES;
            }
        }
    }
    NSArray<NSString *> *parts = [low componentsSeparatedByString:@"."];
    if (parts.count >= 2) {
        NSString *vendor = [NSString stringWithFormat:@"%@.%@", parts[0], parts[1]];
        if ([blob containsString:vendor]) {
            return YES;
        }
    }
    return NO;
}

static void CIKeychainSQLSettle(void);
static BOOL CIKeychainAgrpIsForeignMeta(NSString *agrp, NSString *bundleID);
static BOOL CIKeychainAgrpMatchesBundle(NSString *agrp, NSString *bundleID);

static BOOL CIKeychainAgrpMatchesBundle(NSString *agrp, NSString *bundleID) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (low.length == 0 || CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
        return NO;
    }
    if ([low containsString:bundleID.lowercaseString]) {
        return YES;
    }
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        if ([low hasPrefix:@"43aqtk3442.com.facebook"]) {
            return YES;
        }
        if ([low containsString:@"com.facebook"] || [low containsString:@"msysstorage"] ||
            [low containsString:@"metaplatforms"]) {
            return YES;
        }
        if ([low containsString:@"messenger"] && ![low containsString:@"instagram"]) {
            return YES;
        }
        return NO;
    }
    return CIKeychainTextMatchesBundle(low, bundleID);
}

static BOOL CIIsRootProcess(void) {
    return geteuid() == 0;
}

static BOOL CIInHelperProcess(void) {
    return getenv("CHENG_ROOT_HELPER") != NULL;
}

static BOOL CIInDaemonProcess(void) {
    return getenv("CHENG_DAEMON") != NULL;
}

static NSArray<NSString *> *CIWorkRootCandidates(void) {
    return @[
        @"/var/tmp/ChengIOS",
        @"/private/var/tmp/ChengIOS",
        @"/tmp/ChengIOS",
        @"/var/mobile/tmp/ChengIOS",
        @"/var/mobile/Documents/ChengIOS/.work",
        @"/var/mobile/Library/Caches/ChengIOS/.work",
        @"/var/mobile/Media/ChengIOS/.work",
        @"/private/var/mobile/Media/ChengIOS/.work"
    ];
}

static void CIChmodWorld(NSString *path, int mode) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (raw) {
        chmod(raw, mode);
        lchown(raw, kCIMobileUID, kCIMobileGID);
    }
}

static BOOL CIEnsureWorldDir(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL dir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&dir] || !dir) {
        return NO;
    }
    CIChmodWorld(path, 0777);
    NSString *cur = path;
    for (int i = 0; i < 4; i++) {
        NSString *base = cur.lastPathComponent;
        if ([base isEqualToString:@"ChengIOS"] || [base isEqualToString:@".work"] ||
            [base isEqualToString:@"inbox"] || [base isEqualToString:@"kcaccess"]) {
            CIChmodWorld(cur, 0777);
        }
        NSString *parent = [cur stringByDeletingLastPathComponent];
        if (parent.length == 0 || [parent isEqualToString:cur] || [parent isEqualToString:@"/"]) {
            break;
        }
        cur = parent;
    }
    return YES;
}

static BOOL CIWritePlist(NSDictionary *dict, NSString *path) {
    if (![dict isKindOfClass:[NSDictionary class]] || path.length == 0) {
        return NO;
    }
    NSString *parent = [path stringByDeletingLastPathComponent];
    CIEnsureWorldDir(parent);
    if ([dict writeToFile:path atomically:YES]) {
        CIChmodWorld(path, 0666);
        return YES;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if ([dict writeToFile:path atomically:NO]) {
        CIChmodWorld(path, 0666);
        return YES;
    }
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&err];
    if ([data isKindOfClass:[NSData class]] && data.length > 0 && [data writeToFile:path atomically:NO]) {
        CIChmodWorld(path, 0666);
        return YES;
    }
    if ([data isKindOfClass:[NSData class]] && data.length > 0) {
        FILE *fp = fopen(path.fileSystemRepresentation, "wb");
        if (fp) {
            size_t n = fwrite(data.bytes, 1, data.length, fp);
            fclose(fp);
            if (n == data.length) {
                CIChmodWorld(path, 0666);
                return YES;
            }
        }
    }
    return NO;
}

static BOOL CIProbeWriteDir(NSString *dir) {
    if (!CIEnsureWorldDir(dir)) {
        return NO;
    }
    NSString *inbox = [dir stringByAppendingPathComponent:@"inbox"];
    if (!CIEnsureWorldDir(inbox)) {
        return NO;
    }
    NSString *probe = [inbox stringByAppendingPathComponent:[NSString stringWithFormat:@".probe-%d-%u", getpid(), arc4random()]];
    BOOL ok = CIWritePlist(@{@"ok": @YES, @"uid": @(geteuid())}, probe);
    [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
    return ok;
}

static NSString *gCIWorkRootCached = nil;

static NSArray<NSString *> *CIAllWritableWorkRoots(BOOL create) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in CIWorkRootCandidates()) {
        if (cand.length == 0 || [seen containsObject:cand]) {
            continue;
        }
        [seen addObject:cand];
        if (create) {
            if (CIProbeWriteDir(cand)) {
                [out addObject:cand];
            }
            continue;
        }
        BOOL dir = NO;
        if ([fm fileExistsAtPath:cand isDirectory:&dir] && dir) {
            [out addObject:cand];
        }
    }
    return out;
}

static NSString *CIWorkRootDir(BOOL create) {
    if (create && gCIWorkRootCached.length > 0 && CIProbeWriteDir(gCIWorkRootCached)) {
        return gCIWorkRootCached;
    }
    NSArray<NSString *> *roots = CIAllWritableWorkRoots(create);
    if (roots.count > 0) {
        if (create) {
            gCIWorkRootCached = roots.firstObject;
        }
        return roots.firstObject;
    }
    NSString *fallback = CIWorkRootCandidates().firstObject;
    if (create) {
        CIEnsureWorldDir(fallback);
        CIEnsureWorldDir([fallback stringByAppendingPathComponent:@"inbox"]);
        gCIWorkRootCached = fallback;
    }
    return fallback;
}

static NSString *CIInboxDir(BOOL create) {
    NSString *root = CIWorkRootDir(create);
    if (root.length == 0) {
        return nil;
    }
    NSString *inbox = [root stringByAppendingPathComponent:@"inbox"];
    CIEnsureWorldDir(inbox);
    return inbox;
}

static NSArray<NSString *> *CIAllInboxDirs(BOOL create) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *root in CIAllWritableWorkRoots(create)) {
        NSString *inbox = [root stringByAppendingPathComponent:@"inbox"];
        if (create) {
            CIEnsureWorldDir(inbox);
        }
        if (inbox.length > 0) {
            [out addObject:inbox];
        }
    }
    if (out.count == 0) {
        NSString *inbox = CIInboxDir(create);
        if (inbox.length > 0) {
            [out addObject:inbox];
        }
    }
    return out;
}

static BOOL CIAliveAtRoot(NSString *root) {
    if (root.length == 0) {
        return NO;
    }
    NSString *path = [root stringByAppendingPathComponent:@"daemon.alive"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mod = attrs[NSFileModificationDate];
    if (![mod isKindOfClass:[NSDate class]]) {
        return NO;
    }
    return [[NSDate date] timeIntervalSinceDate:mod] < 12.0;
}

static BOOL CIDaemonIsAlive(void) {
    for (NSString *root in CIWorkRootCandidates()) {
        if (CIAliveAtRoot(root)) {
            return YES;
        }
    }
    return NO;
}

static NSString *CIRootHelperPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/usr/local/bin/chengiosroot",
        @"/usr/local/bin/chengiosroot",
        @"/var/jb/usr/bin/chengiosroot",
        @"/usr/bin/chengiosroot"
    ];
    for (NSString *path in cands) {
        if (access(path.fileSystemRepresentation, X_OK) == 0) {
            return path;
        }
    }
    return nil;
}

static BOOL CIRemoteIsRootOK(NSDictionary *remote) {
    if (![remote isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    if (![remote[@"ok"] boolValue]) {
        return NO;
    }
    id uidObj = remote[@"uid"];
    if (![uidObj isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    return [uidObj integerValue] == 0;
}

static NSDictionary *CIFailRemote(NSString *message) {
    return @{
        @"ok": @NO,
        @"uid": @(geteuid()),
        @"error": message ?: @"error"
    };
}

static NSDictionary *CISpawnHelperOp(NSDictionary *input, NSError **error) {
    NSString *helper = CIRootHelperPath();
    if (helper.length == 0) {
        return CIFailRemote(@"no helper");
    }
    NSString *op = input[@"op"];
    if (op.length == 0) {
        return CIFailRemote(@"no op");
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stamp = [NSString stringWithFormat:@"%ld-%u", (long)[[NSDate date] timeIntervalSince1970], arc4random()];
    NSString *inPath = nil;
    NSString *outPath = nil;
    NSArray<NSString *> *inboxes = CIAllInboxDirs(YES);
    if (inboxes.count == 0) {
        inboxes = @[ CIInboxDir(YES) ?: @"/var/tmp/ChengIOS/inbox" ];
    }
    for (NSString *inbox in inboxes) {
        if (inbox.length == 0) {
            continue;
        }
        CIEnsureWorldDir(inbox);
        NSString *tryIn = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-spawn-in.plist"]];
        NSString *tryOut = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-spawn-out.plist"]];
        [fm removeItemAtPath:tryIn error:nil];
        [fm removeItemAtPath:tryOut error:nil];
        if (CIWritePlist(input, tryIn)) {
            inPath = tryIn;
            outPath = tryOut;
            break;
        }
        [fm removeItemAtPath:tryIn error:nil];
    }
    if (inPath.length == 0 || outPath.length == 0) {
        if (error) {
            *error = CIError(2, @"Khong ghi duoc input cho root helper.");
        }
        return CIFailRemote(@"input");
    }
    pid_t pid = 0;
    const char *args[] = {
        helper.UTF8String,
        op.UTF8String,
        inPath.fileSystemRepresentation,
        outPath.fileSystemRepresentation,
        NULL
    };
    NSMutableArray<NSString *> *envLines = [NSMutableArray array];
    if (environ) {
        for (char **e = environ; *e; e++) {
            [envLines addObject:[NSString stringWithUTF8String:*e]];
        }
    }
    [envLines addObject:@"CHENG_ROOT_HELPER=1"];
    char **envp = (char **)calloc(envLines.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < envLines.count; i++) {
        envp[i] = (char *)[envLines[i] UTF8String];
    }
    int spawned = posix_spawn(&pid, helper.fileSystemRepresentation, NULL, NULL, (char *const *)args, envp);
    free(envp);
    if (spawned != 0) {
        [fm removeItemAtPath:inPath error:nil];
        if (error) {
            *error = CIError(2, [NSString stringWithFormat:@"posix_spawn chengiosroot fail (%d).", spawned]);
        }
        return CIFailRemote(@"spawn");
    }
    int status = 0;
    waitpid(pid, &status, 0);
    NSDictionary *out = [NSDictionary dictionaryWithContentsOfFile:outPath];
    [fm removeItemAtPath:inPath error:nil];
    [fm removeItemAtPath:outPath error:nil];
    if (![out isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = CIError(2, @"chengiosroot khong tra ket qua.");
        }
        return CIFailRemote(@"no output");
    }
    return out;
}

static NSDictionary *CIRunDaemonOp(NSDictionary *input, NSError **error) {
    if (!CIDaemonIsAlive()) {
        [NSThread sleepForTimeInterval:0.2];
    }
    if (!CIDaemonIsAlive()) {
        if (error) {
            *error = CIError(2, @"chengiosroot daemon chua chay. Cai 1.2.53, Respring, mo app ChengIOS.");
        }
        return @{@"ok": @NO, @"uid": @(geteuid()), @"daemon": @NO, @"error": @"daemon not running"};
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stamp = [NSString stringWithFormat:@"%ld-%u", (long)[[NSDate date] timeIntervalSince1970], arc4random()];
    NSString *inPath = nil;
    NSString *outPath = nil;
    NSArray<NSString *> *inboxes = CIAllInboxDirs(YES);
    if (inboxes.count == 0) {
        inboxes = @[ CIInboxDir(YES) ?: @"/var/tmp/ChengIOS/inbox" ];
    }
    for (NSString *inbox in inboxes) {
        if (inbox.length == 0) {
            continue;
        }
        CIEnsureWorldDir(inbox);
        NSString *tryIn = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-in.plist"]];
        NSString *tryOut = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-out.plist"]];
        [fm removeItemAtPath:tryIn error:nil];
        [fm removeItemAtPath:tryOut error:nil];
        if (CIWritePlist(input, tryIn)) {
            inPath = tryIn;
            outPath = tryOut;
            break;
        }
        [fm removeItemAtPath:tryIn error:nil];
    }
    if (inPath.length == 0 || outPath.length == 0) {
        if (error) {
            *error = CIError(2, @"Khong ghi duoc job cho root daemon.");
        }
        return @{@"ok": @NO, @"uid": @(geteuid()), @"error": @"input", @"daemon": @YES};
    }
    NSDate *start = [NSDate date];
    while ([[NSDate date] timeIntervalSinceDate:start] < 900.0) {
        NSDictionary *out = [NSDictionary dictionaryWithContentsOfFile:outPath];
        if ([out isKindOfClass:[NSDictionary class]]) {
            [fm removeItemAtPath:inPath error:nil];
            [fm removeItemAtPath:outPath error:nil];
            return out;
        }
        if (!CIDaemonIsAlive()) {
            break;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    [fm removeItemAtPath:inPath error:nil];
    if (error) {
        *error = CIError(2, @"Root daemon timeout. Facebook data lon: thu lai, giu app ChengIOS mo.");
    }
    return @{@"ok": @NO, @"uid": @(geteuid()), @"error": @"daemon timeout", @"daemon": @YES};
}

static NSDictionary *CIRunRootOp(NSDictionary *input, NSError **error) {
    if (CIIsRootProcess() || CIInHelperProcess()) {
        return nil;
    }
    NSError *spawnErr = nil;
    NSDictionary *spawned = CISpawnHelperOp(input, &spawnErr);
    if (CIRemoteIsRootOK(spawned)) {
        if (error && spawnErr) {
            *error = spawnErr;
        }
        return spawned;
    }
    NSError *daemonErr = nil;
    NSDictionary *daemon = CIRunDaemonOp(input, &daemonErr);
    if (CIRemoteIsRootOK(daemon)) {
        if (error && daemonErr) {
            *error = daemonErr;
        }
        return daemon;
    }
    if (error) {
        if (daemonErr) {
            *error = daemonErr;
        } else if (spawnErr) {
            *error = spawnErr;
        } else {
            *error = CIError(2, @"chengiosroot khong chay duoc.");
        }
    }
    if ([daemon isKindOfClass:[NSDictionary class]]) {
        return daemon;
    }
    if ([spawned isKindOfClass:[NSDictionary class]]) {
        return spawned;
    }
    return CIFailRemote(@"helper");
}

static NSString *gCIKeychainSQLLastPath = nil;
static BOOL gCIKeychainSQLLastOpen = NO;
static NSString *gCIKeychainSQLCopyDir = nil;

static NSString *CIKeychainSQLPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in cands) {
        if ([fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static void CIAddOwnerRW(NSString *path) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (!raw) {
        return;
    }
    struct stat st;
    if (stat(raw, &st) == 0) {
        chmod(raw, st.st_mode | S_IRUSR | S_IWUSR);
    } else {
        chmod(raw, 0600);
    }
}

static void CIKeychainSQLChmodAll(void) {
    NSString *path = CIKeychainSQLPath();
    if (path.length == 0) {
        return;
    }
    CIAddOwnerRW(path);
    CIAddOwnerRW([path stringByAppendingString:@"-wal"]);
    CIAddOwnerRW([path stringByAppendingString:@"-shm"]);
}

static BOOL CIKeychainSQLAgrpProtected(NSString *agrp, NSString *bundleID) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (low.length == 0) {
        return NO;
    }
    if ([low isEqualToString:@"43aqtk3442"]) {
        return YES;
    }
    NSArray<NSString *> *blocked = @[
        @"apple", @"lockdown-identities", @"com.apple.security.sos",
        @"com.apple.cfnetwork", @"com.apple.identities", @"com.apple.certificates",
        @"protectedcloudstorage", @"com.apple.security.oauth"
    ];
    if ([blocked containsObject:low]) {
        return YES;
    }
    if ([low hasPrefix:@"com.apple."]) {
        if (ChengIOSBundleIsSafari(bundleID) &&
            ([low containsString:@"safari"] || [low containsString:@"webkit"] || [low containsString:@"mobilesafari"])) {
            return NO;
        }
        if (CIKeychainTextMatchesBundle(low, bundleID)) {
            return NO;
        }
        return YES;
    }
    return NO;
}

static sqlite3 *CIKeychainSQLOpenPath(NSString *path, BOOL write) {
    if (path.length == 0) {
        return NULL;
    }
    sqlite3 *db = NULL;
    int flags = write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, flags, NULL) != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        return NULL;
    }
    sqlite3_busy_timeout(db, gCIFastErase ? 600 : 15000);
    sqlite3_exec(db, "PRAGMA cipher_memory_security = OFF;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", NULL, NULL, NULL);
    gCIKeychainSQLLastOpen = YES;
    gCIKeychainSQLLastPath = path;
    return db;
}

static sqlite3 *CIKeychainSQLOpen(BOOL write) {
    gCIKeychainSQLLastOpen = NO;
    gCIKeychainSQLLastPath = CIKeychainSQLPath();
    if (gCIKeychainSQLLastPath.length == 0 || geteuid() != 0) {
        return NULL;
    }
    CIKeychainSQLChmodAll();
    if (write) {
        if (!gCIFastErase) {
            CIKeychainSQLSettle();
        }
        return CIKeychainSQLOpenPath(gCIKeychainSQLLastPath, YES);
    }
    return CIKeychainSQLOpenPath(gCIKeychainSQLLastPath, NO);
}

static void CIKeychainSQLClose(sqlite3 *db) {
    if (db) {
        sqlite3_close(db);
    }
    if (gCIKeychainSQLCopyDir.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:gCIKeychainSQLCopyDir error:nil];
        gCIKeychainSQLCopyDir = nil;
    }
}

static NSDictionary *CIKeychainSQLRowCols(sqlite3_stmt *stmt) {
    NSMutableDictionary *cols = [NSMutableDictionary dictionary];
    int n = sqlite3_column_count(stmt);
    for (int i = 0; i < n; i++) {
        const char *name = sqlite3_column_name(stmt, i);
        if (!name) {
            continue;
        }
        NSString *key = [NSString stringWithUTF8String:name];
        if ([key caseInsensitiveCompare:@"rowid"] == NSOrderedSame) {
            continue;
        }
        int type = sqlite3_column_type(stmt, i);
        if (type == SQLITE_NULL) {
            continue;
        }
        if (type == SQLITE_INTEGER) {
            cols[key] = @(sqlite3_column_int64(stmt, i));
        } else if (type == SQLITE_FLOAT) {
            cols[key] = @(sqlite3_column_double(stmt, i));
        } else if (type == SQLITE_BLOB) {
            const void *blob = sqlite3_column_blob(stmt, i);
            int len = sqlite3_column_bytes(stmt, i);
            if (blob && len > 0) {
                cols[key] = [NSData dataWithBytes:blob length:(NSUInteger)len];
            }
        } else {
            const unsigned char *txt = sqlite3_column_text(stmt, i);
            if (txt) {
                cols[key] = [NSString stringWithUTF8String:(const char *)txt];
            }
        }
    }
    return cols;
}

static NSString *CIKeychainSQLRowBlob(NSDictionary *cols) {
    NSMutableArray *parts = [NSMutableArray array];
    [cols enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        (void)stop;
        if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, obj]];
        } else if ([obj isKindOfClass:[NSData class]]) {
            NSData *data = obj;
            if (data.length > 0 && data.length < 4096) {
                NSString *asText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (asText.length > 0) {
                    [parts addObject:asText];
                }
            }
        }
    }];
    return [parts componentsJoinedByString:@" "];
}

static BOOL CIKeychainSQLRowMatchesBundle(NSDictionary *cols, NSString *bundleID) {
    if (![cols isKindOfClass:[NSDictionary class]] || bundleID.length == 0) {
        return NO;
    }
    id agrpValue = CIKeychainSQLBackupValue(cols, @"agrp");
    NSString *agrp = [agrpValue isKindOfClass:[NSString class]] ? agrpValue : [agrpValue description] ?: @"";
    if (CIKeychainSQLAgrpProtected(agrp, bundleID)) {
        return NO;
    }
    if (CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
        return NO;
    }
    if (CIKeychainAgrpMatchesBundle(agrp, bundleID)) {
        return YES;
    }
    return CIKeychainTextMatchesBundle(CIKeychainSQLRowBlob(cols), bundleID);
}


static NSArray<NSString *> *CIKeychainSQLTables(void) {
    return @[@"genp", @"inet", @"keys", @"cert"];
}

static NSArray<NSString *> *CIKeychainSQLListAgrps(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (geteuid() != 0) {
        return out;
    }
    sqlite3 *db = CIKeychainSQLOpen(NO);
    if (!db) {
        return out;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *table in CIKeychainSQLTables()) {
        NSDictionary *schema = CIKeychainSQLTableColumns(db, table);
        NSString *agrp = CIKeychainSQLActualColumn(schema, @"agrp");
        if (agrp.length == 0) {
            continue;
        }
        NSString *sql = [NSString stringWithFormat:@"SELECT DISTINCT %@ FROM %@", CIKeychainSQLQuoteIdentifier(agrp), CIKeychainSQLQuoteIdentifier(table)];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (!txt) {
                continue;
            }
            NSString *value = [NSString stringWithUTF8String:(const char *)txt];
            if (value.length > 0 && ![seen containsObject:value]) {
                [seen addObject:value];
                [out addObject:value];
            }
        }
        sqlite3_finalize(stmt);
    }
    CIKeychainSQLClose(db);
    return out;
}

static NSArray<NSDictionary *> *CIKeychainSQLDumpForBundle(NSString *bundleID) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (bundleID.length == 0 || geteuid() != 0) {
        return out;
    }
    sqlite3 *db = CIKeychainSQLOpen(NO);
    if (!db) {
        return out;
    }
    NSArray<NSString *> *agrps = CIKeychainCollectAgrps(bundleID);
    void (^addRow)(NSString *, sqlite3_stmt *) = ^(NSString *table, sqlite3_stmt *stmt) {
        NSDictionary *cols = CIKeychainSQLRowCols(stmt);
        if (CIKeychainSQLRowMatchesBundle(cols, bundleID)) {
            [out addObject:@{ @"source": @"sqlite", @"table": table, @"cols": cols }];
        }
    };
    for (NSString *table in CIKeychainSQLTables()) {
        NSDictionary *schema = CIKeychainSQLTableColumns(db, table);
        NSString *agrpCol = CIKeychainSQLActualColumn(schema, @"agrp");
        NSString *sql = nil;
        if (agrpCol.length > 0 && agrps.count > 0) {
            sql = [NSString stringWithFormat:@"SELECT rowid, * FROM %@ WHERE %@=?", CIKeychainSQLQuoteIdentifier(table), CIKeychainSQLQuoteIdentifier(agrpCol)];
        } else {
            sql = [NSString stringWithFormat:@"SELECT rowid, * FROM %@", CIKeychainSQLQuoteIdentifier(table)];
        }
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        if (agrpCol.length > 0 && agrps.count > 0) {
            for (NSString *agrp in agrps) {
                sqlite3_reset(stmt);
                sqlite3_clear_bindings(stmt);
                sqlite3_bind_text(stmt, 1, agrp.UTF8String, -1, SQLITE_TRANSIENT);
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    addRow(table, stmt);
                }
            }
        } else {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                addRow(table, stmt);
            }
        }
        sqlite3_finalize(stmt);
    }
    CIKeychainSQLClose(db);
    return out;
}

static void CIKeychainSQLSettle(void) {
    CIRunKillall(@"securityd");
    CIRunKillall(@"secd");
    [NSThread sleepForTimeInterval:0.05];
}

static NSUInteger CIKeychainSQLWipeForBundle(NSString *bundleID) {
    if (bundleID.length == 0 || geteuid() != 0) {
        return 0;
    }
    sqlite3 *db = CIKeychainSQLOpen(YES);
    if (!db) {
        return 0;
    }
    NSUInteger removed = 0;
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    NSArray<NSString *> *tables = CIKeychainSQLTables();
    NSArray<NSString *> *agrps = CIKeychainCollectAgrps(bundleID);
    NSString *low = bundleID.lowercaseString;
    NSMutableArray<NSString *> *likes = [NSMutableArray array];
    BOOL shopeeWipe = [low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."];
    if (shopeeWipe) {
        [likes addObjectsFromArray:@[@"%shopee%", @"%beeasy%", @"%shopeepay%"]];
    }
    if ([low hasPrefix:@"com.facebook."] || [low containsString:@"facebook"]) {
        [likes addObjectsFromArray:@[
            @"%facebook%", @"%fbsdk%", @"%43aqtk3442.com.facebook%",
            @"%family_device_id%", @"%fb_device_id%", @"%anonymousid%"
        ]];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] || [low containsString:@"aweme"]) {
        [likes addObjectsFromArray:@[
            @"%tiktok%", @"%zhiliao%", @"%musically%", @"%aweme%", @"%bytedance%",
            @"%com.ss.iphone%", @"%passport%", @"%odin_tt%", @"%openudid%",
            @"%krypton%", @"%msdk_guid%"
        ]];
    }
    for (NSString *table in tables) {
        for (NSString *agrp in agrps) {
            NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE agrp=?", table];
            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
                continue;
            }
            sqlite3_bind_text(stmt, 1, agrp.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_DONE) {
                removed += (NSUInteger)sqlite3_changes(db);
            }
            sqlite3_finalize(stmt);
        }
        for (NSString *like in likes) {
            NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE agrp LIKE ? OR svce LIKE ? OR acct LIKE ?", table];
            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
                continue;
            }
            sqlite3_bind_text(stmt, 1, like.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, like.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 3, like.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_DONE) {
                removed += (NSUInteger)sqlite3_changes(db);
            }
            sqlite3_finalize(stmt);
        }
        if (shopeeWipe) {
            LSApplicationProxy *proxy = CIProxy(bundleID);
            NSDictionary *ents = [proxy respondsToSelector:@selector(entitlements)] ? proxy.entitlements : nil;
            NSString *appId = [ents[@"application-identifier"] isKindOfClass:[NSString class]] ? ents[@"application-identifier"] : bundleID;
            NSString *team = CITeamIDFromAppID(appId) ?: @"";
            NSArray<NSString *> *track = @[
                @"%appsflyer%", @"%adjust%", @"%firebase%", @"%google.iid%",
                @"%tongdun%", @"%trustdecision%", @"%fmdevice%", @"%blackbox%",
                @"%tdid%", @"%umeng%", @"%talkingdata%", @"%seclink%", @"%device_fingerprint%"
            ];
            for (NSString *like in track) {
                NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE (svce LIKE ? OR acct LIKE ? OR IFNULL(labl,'') LIKE ?) AND (agrp LIKE ? OR agrp LIKE ? OR agrp LIKE ? OR agrp LIKE ?)", table];
                sqlite3_stmt *stmt = NULL;
                if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
                    sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE (svce LIKE ? OR acct LIKE ?) AND (agrp LIKE ? OR agrp LIKE ? OR agrp LIKE ? OR agrp LIKE ?)", table];
                    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
                        continue;
                    }
                    sqlite3_bind_text(stmt, 1, like.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 2, like.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 3, "%shopee%", -1, SQLITE_STATIC);
                    sqlite3_bind_text(stmt, 4, "%beeasy%", -1, SQLITE_STATIC);
                    sqlite3_bind_text(stmt, 5, [NSString stringWithFormat:@"%%%@%%", team].UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 6, [NSString stringWithFormat:@"%%%@%%", bundleID].UTF8String, -1, SQLITE_TRANSIENT);
                } else {
                    sqlite3_bind_text(stmt, 1, like.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 2, like.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 3, like.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 4, "%shopee%", -1, SQLITE_STATIC);
                    sqlite3_bind_text(stmt, 5, "%beeasy%", -1, SQLITE_STATIC);
                    sqlite3_bind_text(stmt, 6, [NSString stringWithFormat:@"%%%@%%", team].UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 7, [NSString stringWithFormat:@"%%%@%%", bundleID].UTF8String, -1, SQLITE_TRANSIENT);
                }
                if (sqlite3_step(stmt) == SQLITE_DONE) {
                    removed += (NSUInteger)sqlite3_changes(db);
                }
                sqlite3_finalize(stmt);
            }
        }
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    CIKeychainSQLClose(db);
    if (!gCIFastErase) {
        CIKeychainSQLSettle();
    }
    return removed;
}

static NSString *CIKeychainSQLRowSignature(NSDictionary *row) {
    if (![row isKindOfClass:[NSDictionary class]]) {
        return @"";
    }
    NSString *table = [row[@"table"] isKindOfClass:[NSString class]] ? row[@"table"] : @"";
    NSDictionary *cols = [row[@"cols"] isKindOfClass:[NSDictionary class]] ? row[@"cols"] : @{};
    id agrpValue = CIKeychainSQLBackupValue(cols, @"agrp");
    id lablValue = CIKeychainSQLBackupValue(cols, @"labl");
    id svceValue = CIKeychainSQLBackupValue(cols, @"svce");
    id acctValue = CIKeychainSQLBackupValue(cols, @"acct");
    NSString *agrp = [agrpValue isKindOfClass:[NSString class]] ? agrpValue : [agrpValue description] ?: @"";
    if ([table isEqualToString:@"keys"] || [table isEqualToString:@"cert"]) {
        NSString *labl = [lablValue isKindOfClass:[NSString class]] ? lablValue : [lablValue description] ?: @"";
        return [NSString stringWithFormat:@"%@|%@|%@", table, agrp, labl];
    }
    NSString *svce = [svceValue isKindOfClass:[NSString class]] ? svceValue : [svceValue description] ?: @"";
    NSString *acct = [acctValue isKindOfClass:[NSString class]] ? acctValue : [acctValue description] ?: @"";
    return [NSString stringWithFormat:@"%@|%@|%@|%@", table, agrp, svce, acct];
}

static BOOL CIKeychainSQLValueHasData(id value) {
    if ([value isKindOfClass:[NSData class]]) {
        return [value length] > 0;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [value length] > 0;
    }
    return NO;
}

static NSString *CIKeychainSQLCanonicalColumn(NSString *key) {
    NSString *low = key.lowercaseString ?: @"";
    if ([low isEqualToString:@"agrp"] || [low isEqualToString:@"v_agrp"] || [low isEqualToString:@"accessgroup"]) {
        return @"agrp";
    }
    if ([low isEqualToString:@"svce"] || [low isEqualToString:@"v_svce"] || [low isEqualToString:@"service"]) {
        return @"svce";
    }
    if ([low isEqualToString:@"acct"] || [low isEqualToString:@"v_acct"] || [low isEqualToString:@"account"]) {
        return @"acct";
    }
    if ([low isEqualToString:@"labl"] || [low isEqualToString:@"v_labl"] || [low isEqualToString:@"label"]) {
        return @"labl";
    }
    if ([low isEqualToString:@"data"] || [low isEqualToString:@"v_data"] ||
        [low isEqualToString:@"blob"] || [low isEqualToString:@"value"] ||
        [low isEqualToString:@"v_blob"] || [low isEqualToString:@"v_value"]) {
        return @"data";
    }
    return low.length > 0 ? low : nil;
}

static NSString *CIKeychainSQLQuoteIdentifier(NSString *value) {
    if (value.length == 0) {
        return @"\"\"";
    }
    return [NSString stringWithFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

static NSDictionary<NSString *, NSString *> *CIKeychainSQLTableColumns(sqlite3 *db, NSString *table) {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    if (!db || table.length == 0) {
        return out;
    }
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", CIKeychainSQLQuoteIdentifier(table)];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        return out;
    }
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(stmt, 1);
        if (!name) {
            continue;
        }
        NSString *column = [NSString stringWithUTF8String:(const char *)name];
        if (column.length > 0) {
            out[column.lowercaseString] = column;
        }
    }
    sqlite3_finalize(stmt);
    return out;
}

static NSString *CIKeychainSQLActualColumn(NSDictionary<NSString *, NSString *> *schema, NSString *canonical) {
    if (![schema isKindOfClass:[NSDictionary class]] || canonical.length == 0) {
        return nil;
    }
    NSString *exact = schema[canonical.lowercaseString];
    if (exact.length > 0) {
        return exact;
    }
    NSArray<NSString *> *aliases = nil;
    if ([canonical isEqualToString:@"agrp"]) {
        aliases = @[@"v_agrp", @"accessgroup"];
    } else if ([canonical isEqualToString:@"svce"]) {
        aliases = @[@"v_svce", @"service"];
    } else if ([canonical isEqualToString:@"acct"]) {
        aliases = @[@"v_acct", @"account"];
    } else if ([canonical isEqualToString:@"labl"]) {
        aliases = @[@"v_labl", @"label"];
    } else if ([canonical isEqualToString:@"data"]) {
        aliases = @[@"v_data", @"blob", @"value", @"v_blob", @"v_value"];
    }
    for (NSString *alias in aliases) {
        NSString *actual = schema[alias];
        if (actual.length > 0) {
            return actual;
        }
    }
    return nil;
}

static id CIKeychainSQLBackupValue(NSDictionary *cols, NSString *canonical) {
    if (![cols isKindOfClass:[NSDictionary class]] || canonical.length == 0) {
        return nil;
    }
    id fallback = nil;
    for (NSString *key in cols) {
        if (![key isKindOfClass:[NSString class]] || ![[CIKeychainSQLCanonicalColumn(key) lowercaseString] isEqualToString:canonical.lowercaseString]) {
            continue;
        }
        id value = cols[key];
        if (CIKeychainSQLValueHasData(value)) {
            return value;
        }
        if (!fallback) {
            fallback = value;
        }
    }
    return fallback;
}

static BOOL CIKeychainSQLRowHasData(NSDictionary *row) {
    NSDictionary *cols = [row[@"cols"] isKindOfClass:[NSDictionary class]] ? row[@"cols"] : nil;
    return CIKeychainSQLValueHasData(CIKeychainSQLBackupValue(cols, @"data"));
}

static void CIKeychainSQLAddUniqueRow(NSMutableArray<NSDictionary *> *out, NSDictionary *row) {
    if (![row isKindOfClass:[NSDictionary class]] || ![out isKindOfClass:[NSMutableArray class]]) {
        return;
    }
    NSString *sig = CIKeychainSQLRowSignature(row);
    if (sig.length == 0) {
        return;
    }
    for (NSUInteger i = 0; i < out.count; i++) {
        if ([CIKeychainSQLRowSignature(out[i]) isEqualToString:sig]) {
            if (CIKeychainSQLRowHasData(row) && !CIKeychainSQLRowHasData(out[i])) {
                out[i] = row;
            }
            return;
        }
    }
    [out addObject:row];
}

static NSUInteger CIKeychainSQLRestoreRows(NSArray *rows) {
    if (![rows isKindOfClass:[NSArray class]] || geteuid() != 0) {
        return 0;
    }
    CIKeychainSQLSettle();
    sqlite3 *db = CIKeychainSQLOpen(YES);
    if (!db) {
        return 0;
    }
    NSUInteger added = 0;
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *table = [row[@"table"] isKindOfClass:[NSString class]] ? row[@"table"] : nil;
        NSDictionary *cols = [row[@"cols"] isKindOfClass:[NSDictionary class]] ? row[@"cols"] : nil;
        if (![table isEqualToString:@"genp"] && ![table isEqualToString:@"inet"] &&
            ![table isEqualToString:@"keys"] && ![table isEqualToString:@"cert"]) {
            continue;
        }
        if (cols.count == 0) {
            continue;
        }
        NSDictionary<NSString *, NSString *> *schema = CIKeychainSQLTableColumns(db, table);
        if (schema.count == 0) {
            continue;
        }
        NSMutableDictionary<NSString *, id> *mapped = [NSMutableDictionary dictionary];
        for (NSString *key in cols) {
            if (![key isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *actual = schema[key.lowercaseString];
            if (actual.length == 0) {
                NSString *canonical = CIKeychainSQLCanonicalColumn(key);
                actual = CIKeychainSQLActualColumn(schema, canonical);
            }
            if (actual.length == 0) {
                continue;
            }
            id value = cols[key];
            id old = mapped[actual];
            if (!old || (!CIKeychainSQLValueHasData(old) && CIKeychainSQLValueHasData(value))) {
                mapped[actual] = value ?: [NSNull null];
            }
        }
        if (mapped.count == 0) {
            continue;
        }
        NSString *agrpCol = CIKeychainSQLActualColumn(schema, @"agrp");
        NSString *svceCol = CIKeychainSQLActualColumn(schema, @"svce");
        NSString *acctCol = CIKeychainSQLActualColumn(schema, @"acct");
        NSString *lablCol = CIKeychainSQLActualColumn(schema, @"labl");
        NSString *agrp = [CIKeychainSQLBackupValue(cols, @"agrp") isKindOfClass:[NSString class]] ? CIKeychainSQLBackupValue(cols, @"agrp") : @"";
        NSString *svce = [CIKeychainSQLBackupValue(cols, @"svce") isKindOfClass:[NSString class]] ? CIKeychainSQLBackupValue(cols, @"svce") : @"";
        NSString *acct = [CIKeychainSQLBackupValue(cols, @"acct") isKindOfClass:[NSString class]] ? CIKeychainSQLBackupValue(cols, @"acct") : @"";
        NSString *labl = [CIKeychainSQLBackupValue(cols, @"labl") isKindOfClass:[NSString class]] ? CIKeychainSQLBackupValue(cols, @"labl") : @"";

        NSMutableString *deleteSQL = [NSMutableString stringWithFormat:@"DELETE FROM %@ WHERE ", CIKeychainSQLQuoteIdentifier(table)];
        NSMutableArray<NSString *> *where = [NSMutableArray array];
        NSMutableArray<NSString *> *whereValues = [NSMutableArray array];
        if (agrpCol.length > 0) { [where addObject:[NSString stringWithFormat:@"IFNULL(%@,'')=?", CIKeychainSQLQuoteIdentifier(agrpCol)]]; [whereValues addObject:agrp]; }
        if ([table isEqualToString:@"keys"] || [table isEqualToString:@"cert"]) {
            if (lablCol.length > 0) { [where addObject:[NSString stringWithFormat:@"IFNULL(%@,'')=?", CIKeychainSQLQuoteIdentifier(lablCol)]]; [whereValues addObject:labl]; }
        } else {
            if (svceCol.length > 0) { [where addObject:[NSString stringWithFormat:@"IFNULL(%@,'')=?", CIKeychainSQLQuoteIdentifier(svceCol)]]; [whereValues addObject:svce]; }
            if (acctCol.length > 0) { [where addObject:[NSString stringWithFormat:@"IFNULL(%@,'')=?", CIKeychainSQLQuoteIdentifier(acctCol)]]; [whereValues addObject:acct]; }
        }
        if (where.count > 0) {
            [deleteSQL appendString:[where componentsJoinedByString:@" AND "]];
            sqlite3_stmt *delStmt = NULL;
            if (sqlite3_prepare_v2(db, deleteSQL.UTF8String, -1, &delStmt, NULL) == SQLITE_OK) {
                int bind = 1;
                for (NSString *value in whereValues) {
                    sqlite3_bind_text(delStmt, bind++, value.UTF8String ?: "", -1, SQLITE_TRANSIENT);
                }
                sqlite3_step(delStmt);
                sqlite3_finalize(delStmt);
            }
        }

        NSArray<NSString *> *keys = [mapped.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *quoted = [NSMutableArray arrayWithCapacity:keys.count];
        NSMutableArray *qs = [NSMutableArray arrayWithCapacity:keys.count];
        for (NSString *key in keys) {
            [quoted addObject:CIKeychainSQLQuoteIdentifier(key)];
            [qs addObject:@"?"];
        }
        NSString *sql = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (%@) VALUES (%@)",
                         CIKeychainSQLQuoteIdentifier(table),
                         [quoted componentsJoinedByString:@","],
                         [qs componentsJoinedByString:@","]];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        int bind = 1;
        for (NSString *key in keys) {
            id val = mapped[key];
            if (val == [NSNull null] || !val) {
                sqlite3_bind_null(stmt, bind);
            } else if ([val isKindOfClass:[NSData class]]) {
                NSData *data = val;
                sqlite3_bind_blob(stmt, bind, data.bytes, (int)data.length, SQLITE_TRANSIENT);
            } else if ([val isKindOfClass:[NSNumber class]]) {
                sqlite3_bind_int64(stmt, bind, [val longLongValue]);
            } else if ([val isKindOfClass:[NSString class]]) {
                sqlite3_bind_text(stmt, bind, [val UTF8String], -1, SQLITE_TRANSIENT);
            } else {
                sqlite3_bind_null(stmt, bind);
            }
            bind += 1;
        }
        if (sqlite3_step(stmt) == SQLITE_DONE) {
            added += 1;
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    CIKeychainSQLClose(db);
    CIKeychainSQLSettle();
    return added;
}

static void CIKeychainDeleteMatching(id secClass, NSString *bundleID) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        return;
    }
    NSArray *items = CFBridgingRelease(result);
    if (![items isKindOfClass:[NSArray class]]) {
        return;
    }
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *blob = [NSString stringWithFormat:@"%@ %@ %@ %@ %@",
                          item[(__bridge id)kSecAttrService] ?: @"",
                          item[(__bridge id)kSecAttrAccount] ?: @"",
                          item[(__bridge id)kSecAttrAccessGroup] ?: @"",
                          item[(__bridge id)kSecAttrLabel] ?: @"",
                          item[(__bridge id)kSecAttrServer] ?: @""];
        if (!CIKeychainTextMatchesBundle(blob, bundleID)) {
            continue;
        }
        NSMutableDictionary *del = [@{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
        } mutableCopy];
        for (id key in @[
            (__bridge id)kSecAttrService,
            (__bridge id)kSecAttrAccount,
            (__bridge id)kSecAttrAccessGroup,
            (__bridge id)kSecAttrLabel,
            (__bridge id)kSecAttrServer
        ]) {
            id value = item[key];
            if (value) {
                del[key] = value;
            }
        }
        SecItemDelete((__bridge CFDictionaryRef)del);
    }
}

static NSString *CITeamIDFromAppID(NSString *value) {
    if (value.length < 12) {
        return nil;
    }
    NSRange dot = [value rangeOfString:@"."];
    if (dot.location < 8 || dot.location > 12) {
        return nil;
    }
    NSString *team = [value substringToIndex:dot.location];
    for (NSUInteger i = 0; i < team.length; i++) {
        unichar c = [team characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        if (!ok) {
            return nil;
        }
    }
    return team;
}

static NSArray<NSString *> *CICompanionBundleIDs(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    if ([low isEqualToString:@"com.facebook.facebook"] || [low hasPrefix:@"com.facebook.facebook."]) {
        return @[
            @"com.facebook.Messenger",
            @"com.facebook.Facebook.lite",
            @"com.facebook.MessengerLite",
            @"com.facebook.Video"
        ];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return CIKnownShopeeBundles();
    }
    if ([low hasPrefix:@"com.zhiliaoapp."] || [low containsString:@"tiktok"] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] ||
        [low containsString:@"musically"] || [low containsString:@"bytedance"]) {
        return @[
            @"com.ss.iphone.ugc.Aweme",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go"
        ];
    }
    return @[];
}

static NSDictionary<NSString *, NSString *> *CIScanContainersMatching(NSArray<NSString *> *roots, BOOL (^pred)(NSString *ident)) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    if (!pred) {
        return map;
    }
    for (NSString *root in roots) {
        NSDictionary<NSString *, NSString *> *index = CIContainerIndexForRoot(root);
        [index enumerateKeysAndObjectsUsingBlock:^(NSString *ident, NSString *dir, BOOL *stop) {
            (void)stop;
            if (!map[ident] && pred(ident)) {
                map[ident] = dir;
            }
        }];
    }
    return map;
}

static NSArray<NSString *> *CIFacebookExtraGroups(void) {
    return @[
        @"group.com.facebook.Facebook",
        @"group.com.facebook.family",
        @"group.com.facebook.Messenger",
        @"group.com.facebook.Facebook.widget",
        @"group.com.facebook.mlite",
        @"group.com.facebook.platform",
        @"group.com.facebook.msysstorage",
        @"group.com.metaplatforms.family"
    ];
}

static NSDictionary<NSString *, NSString *> *CIAllGroupPaths(NSString *bundleID) {
    NSDictionary *baseGroups = CIGroupPaths(bundleID);
    NSMutableDictionary<NSString *, NSString *> *map = [baseGroups mutableCopy];
    if (!map) {
        map = [NSMutableDictionary dictionary];
    }
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Shared/AppGroup"
    ];
    BOOL fb = CIBundleIsFacebookFamily(bundleID);
    BOOL shopee = [bundleID.lowercaseString containsString:@"shopee"] || [bundleID.lowercaseString hasPrefix:@"com.beeasy."];
    BOOL tiktok = [bundleID.lowercaseString containsString:@"tiktok"] || [bundleID.lowercaseString hasPrefix:@"com.zhiliaoapp."] ||
                  [bundleID.lowercaseString hasPrefix:@"com.ss.iphone."] || [bundleID.lowercaseString containsString:@"aweme"];
    NSDictionary *scanned = CIScanContainersMatching(roots, ^BOOL(NSString *ident) {
        if (ident.length == 0 || map[ident]) {
            return NO;
        }
        NSString *low = ident.lowercaseString;
        if (fb) {
            if ([low containsString:@"instagram"] || [low containsString:@"burbn"] ||
                [low containsString:@"whatsapp"] || [low containsString:@"threads"]) {
                return NO;
            }
            return [low containsString:@"facebook"] || [low containsString:@"messenger"] ||
                   [low containsString:@"msysstorage"] || [low containsString:@"metaplatforms"];
        }
        if (shopee) {
            return [low containsString:@"shopee"] || [low containsString:@"beeasy"];
        }
        if (tiktok) {
            return [low containsString:@"zhiliao"] || [low containsString:@"tiktok"] ||
                   [low containsString:@"musically"] || [low containsString:@"aweme"] ||
                   [low containsString:@"bytedance"];
        }
        return NO;
    });
    [map addEntriesFromDictionary:scanned];
    NSMutableArray<NSString *> *extra = [NSMutableArray array];
    if (fb) {
        [extra addObjectsFromArray:CIFacebookExtraGroups()];
    }
    if (shopee) {
        [extra addObjectsFromArray:@[
            @"group.com.shopee.vn",
            @"group.com.shopee.SG",
            @"group.com.shopee.id",
            @"group.com.shopee.my",
            @"group.com.shopee.th",
            @"group.com.shopee.tw",
            @"group.com.shopee.ph",
            @"group.com.shopee.intlseller",
            @"group.com.beeasy.marketplace.vn",
            @"group.com.shopeepay.vn"
        ]];
    }
    if (tiktok) {
        [extra addObjectsFromArray:@[
            @"group.com.zhiliaoapp.musically",
            @"group.com.zhiliaoapp.musically.go",
            @"group.com.ss.iphone.ugc.Aweme",
            @"group.com.bytedance.tiktok"
        ]];
    }
    for (NSString *gid in extra) {
        if (map[gid].length > 0) {
            continue;
        }
        NSString *path = CIScanContainer(roots, gid);
        if (path.length > 0) {
            map[gid] = path;
        }
    }
    return map;
}

static NSDictionary<NSString *, NSString *> *CIPluginPaths(NSString *bundleID) {
    NSString *prefix = [bundleID stringByAppendingString:@"."];
    NSArray *companions = CICompanionBundleIDs(bundleID);
    return CIScanContainersMatching(@[
        @"/var/mobile/Containers/Data/PluginKitPlugin",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin"
    ], ^BOOL(NSString *ident) {
        if ([ident isEqualToString:bundleID] || [ident hasPrefix:prefix]) {
            return YES;
        }
        for (NSString *other in companions) {
            if ([ident isEqualToString:other] || [ident hasPrefix:[other stringByAppendingString:@"."]]) {
                return YES;
            }
        }
        return ChengIOSBundleIsSafari(bundleID) && (
            [ident.lowercaseString containsString:@"safari"] ||
            [ident.lowercaseString hasPrefix:@"com.apple.webkit"]
        );
    });
}

static NSArray<NSString *> *CISafariLibraryPaths(void) {
    return @[
        @"/var/mobile/Library/Safari",
        @"/private/var/mobile/Library/Safari",
        @"/var/mobile/Library/Cookies",
        @"/private/var/mobile/Library/Cookies",
        @"/var/mobile/Library/WebKit",
        @"/private/var/mobile/Library/WebKit",
        @"/var/mobile/Library/HTTPStorages",
        @"/private/var/mobile/Library/HTTPStorages",
        @"/var/mobile/Library/Caches/com.apple.mobilesafari",
        @"/private/var/mobile/Library/Caches/com.apple.mobilesafari",
        @"/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/private/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/var/mobile/Library/Caches/com.apple.WebKit.Networking",
        @"/private/var/mobile/Library/Caches/WebKit",
        @"/var/mobile/Library/Caches/com.apple.Safari",
        @"/var/mobile/Library/SafariSafeBrowsing",
        @"/var/mobile/Library/Preferences/com.apple.mobilesafari.plist",
        @"/private/var/mobile/Library/Preferences/com.apple.mobilesafari.plist",
        @"/var/mobile/Library/Preferences/com.apple.Safari.plist",
        @"/var/mobile/Library/Preferences/com.apple.SafariViewService.plist",
        @"/var/mobile/Library/Saved Application State/com.apple.mobilesafari.savedState",
        @"/var/mobile/Library/SplashBoard/Snapshots/com.apple.mobilesafari",
        @"/var/mobile/Library/SplashBoard/Snapshots/sceneID:com.apple.mobilesafari"
    ];
}

static void CIKillSafariProcesses(void) {
    NSArray<NSString *> *names = @[
        @"MobileSafari", @"SafariViewService",
        @"com.apple.WebKit.WebContent", @"com.apple.WebKit.Networking",
        @"com.apple.WebKit.GPU"
    ];
    for (NSString *name in names) {
        CIRunKillall(name);
    }
    CITerminateBundle(@"com.apple.mobilesafari");
    CITerminateBundle(@"com.apple.SafariViewService");
}

static NSString *CISecClassName(id cls) {
    if (cls == (__bridge id)kSecClassInternetPassword) {
        return @"inet";
    }
    if (cls == (__bridge id)kSecClassKey) {
        return @"keys";
    }
    if (cls == (__bridge id)kSecClassCertificate) {
        return @"cert";
    }
    if (cls == (__bridge id)kSecClassIdentity) {
        return @"idnt";
    }
    return @"genp";
}

static id CISecClassFromName(NSString *name) {
    if ([name isEqualToString:@"inet"]) {
        return (__bridge id)kSecClassInternetPassword;
    }
    if ([name isEqualToString:@"keys"]) {
        return (__bridge id)kSecClassKey;
    }
    if ([name isEqualToString:@"cert"]) {
        return (__bridge id)kSecClassCertificate;
    }
    if ([name isEqualToString:@"idnt"]) {
        return (__bridge id)kSecClassIdentity;
    }
    return (__bridge id)kSecClassGenericPassword;
}

static id CIPlistSafe(id value) {
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]] ||
        [value isKindOfClass:[NSData class]]) {
        return value;
    }
    return nil;
}

static NSArray<NSDictionary *> *CIKeychainCopyItems(id secClass, BOOL withData) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @(withData),
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    } mutableCopy];
    query[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUISkip;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        [query removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
        result = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        return @[];
    }
    NSArray *items = CFBridgingRelease(result);
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

static NSDictionary *CIKeychainRowFromItem(id secClass, NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"class"] = CISecClassName(secClass);
    NSDictionary *map = @{
        @"service": (__bridge id)kSecAttrService,
        @"account": (__bridge id)kSecAttrAccount,
        @"accessGroup": (__bridge id)kSecAttrAccessGroup,
        @"label": (__bridge id)kSecAttrLabel,
        @"server": (__bridge id)kSecAttrServer,
        @"protocol": (__bridge id)kSecAttrProtocol,
        @"path": (__bridge id)kSecAttrPath,
        @"accessible": (__bridge id)kSecAttrAccessible
    };
    [map enumerateKeysAndObjectsUsingBlock:^(NSString *key, id secKey, BOOL *stop) {
        (void)stop;
        id value = CIPlistSafe(item[secKey]);
        if (value) {
            row[key] = value;
        }
    }];
    id port = item[(__bridge id)kSecAttrPort];
    if ([port isKindOfClass:[NSNumber class]]) {
        row[@"port"] = port;
    }
    id sync = item[(__bridge id)kSecAttrSynchronizable];
    if ([sync isKindOfClass:[NSNumber class]]) {
        row[@"synchronizable"] = sync;
    }
    NSData *data = item[(__bridge id)kSecValueData];
    if ([data isKindOfClass:[NSData class]] && data.length > 0) {
        row[@"data"] = [data base64EncodedStringWithOptions:0];
    }
    NSData *generic = item[(__bridge id)kSecAttrGeneric];
    if ([generic isKindOfClass:[NSData class]] && generic.length > 0) {
        row[@"generic"] = [generic base64EncodedStringWithOptions:0];
    }
    NSData *tag = item[(__bridge id)kSecAttrApplicationTag];
    if ([tag isKindOfClass:[NSData class]] && tag.length > 0) {
        row[@"applicationTag"] = [tag base64EncodedStringWithOptions:0];
    }
    NSData *albl = item[(__bridge id)kSecAttrApplicationLabel];
    if ([albl isKindOfClass:[NSData class]] && albl.length > 0) {
        row[@"applicationLabel"] = [albl base64EncodedStringWithOptions:0];
    }
    id keyClass = CIPlistSafe(item[(__bridge id)kSecAttrKeyClass]);
    if (keyClass) {
        row[@"keyClass"] = keyClass;
    }
    id keyType = CIPlistSafe(item[(__bridge id)kSecAttrKeyType]);
    if (keyType) {
        row[@"keyType"] = keyType;
    }
    id keySize = item[(__bridge id)kSecAttrKeySizeInBits];
    if ([keySize isKindOfClass:[NSNumber class]]) {
        row[@"keySize"] = keySize;
    }
    return row;
}

static BOOL CIKeychainItemMatchesBundle(NSDictionary *item, NSString *bundleID) {
    if (![item isKindOfClass:[NSDictionary class]] || bundleID.length == 0) {
        return NO;
    }
    NSString *agrp = item[(__bridge id)kSecAttrAccessGroup] ?: item[@"accessGroup"] ?: @"";
    if ([agrp isKindOfClass:[NSString class]] && CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
        return NO;
    }
    if ([agrp isKindOfClass:[NSString class]] && CIKeychainAgrpMatchesBundle(agrp, bundleID)) {
        return YES;
    }
    NSString *blob = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
                      item[(__bridge id)kSecAttrService] ?: item[@"service"] ?: @"",
                      item[(__bridge id)kSecAttrAccount] ?: item[@"account"] ?: @"",
                      item[(__bridge id)kSecAttrAccessGroup] ?: item[@"accessGroup"] ?: @"",
                      item[(__bridge id)kSecAttrLabel] ?: item[@"label"] ?: @"",
                      item[(__bridge id)kSecAttrServer] ?: item[@"server"] ?: @"",
                      item[(__bridge id)kSecAttrPath] ?: item[@"path"] ?: @""];
    return CIKeychainTextMatchesBundle(blob, bundleID);
}

static NSString *CIKeychainRowSig(NSDictionary *row) {
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
            row[@"class"] ?: @"",
            row[@"service"] ?: @"",
            row[@"account"] ?: @"",
            row[@"accessGroup"] ?: @"",
            row[@"label"] ?: @"",
            row[@"server"] ?: @"",
            row[@"applicationTag"] ?: @""];
}

static BOOL CIKeychainRowHasData(NSDictionary *row) {
    return [row[@"data"] isKindOfClass:[NSString class]] && [row[@"data"] length] > 0;
}

static NSUInteger CIKeychainCountWithData(NSArray *rows) {
    NSUInteger n = 0;
    for (NSDictionary *row in rows) {
        if ([row isKindOfClass:[NSDictionary class]] && CIKeychainRowHasData(row)) {
            n += 1;
        }
    }
    return n;
}

static void CIKeychainAddUniqueRow(NSMutableArray<NSDictionary *> *out, NSDictionary *row) {
    if (![row isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString *sig = CIKeychainRowSig(row);
    for (NSUInteger i = 0; i < out.count; i++) {
        if ([CIKeychainRowSig(out[i]) isEqualToString:sig]) {
            if (CIKeychainRowHasData(row) && !CIKeychainRowHasData(out[i])) {
                out[i] = row;
            }
            return;
        }
    }
    [out addObject:row];
}

static NSArray<NSDictionary *> *CIKeychainCopyItemsFiltered(id secClass, NSDictionary *extra, BOOL withData) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @(withData),
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    } mutableCopy];
    query[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUISkip;
    [query addEntriesFromDictionary:extra ?: @{}];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        [query removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
        result = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        return @[];
    }
    NSArray *items = CFBridgingRelease(result);
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}


static NSString *gCILdidPath = nil;
static NSString *gCIKCSignedError = nil;
static NSUInteger gCIKCAgrpCount = 0;
static NSUInteger gCIKCSignedCount = 0;
static NSUInteger gCIKCSignedCountTotal = 0;
static NSUInteger gCIKCWithData = 0;
static NSUInteger gCIKCFailed = 0;
static NSUInteger gCIKCSkipped = 0;
static NSInteger gCIKCSignedUID = -1;
static BOOL gCIKCSignedOK = NO;

static int CISpawnWait(NSString *path, NSArray<NSString *> *args) {
    if (path.length == 0) {
        return -1;
    }
    const char *bin = path.fileSystemRepresentation;
    if (!bin || access(bin, X_OK) != 0) {
        return -1;
    }
    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    if (args.count > 0) {
        [all addObjectsFromArray:args];
    }
    char **argv = (char **)calloc(all.count + 1, sizeof(char *));
    if (!argv) {
        return -1;
    }
    for (NSUInteger i = 0; i < all.count; i++) {
        const char *raw = all[i].fileSystemRepresentation ?: all[i].UTF8String;
        argv[i] = raw ? strdup(raw) : strdup("");
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, bin, NULL, NULL, argv, environ);
    for (NSUInteger i = 0; i < all.count; i++) {
        free(argv[i]);
    }
    free(argv);
    if (rc != 0) {
        return -1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

static NSString *CILdidPath(void) {
    if (gCILdidPath.length > 0) {
        return gCILdidPath;
    }
    NSArray<NSString *> *cands = @[
        @"/usr/libexec/am/ldid",
        @"/usr/bin/ldid",
        @"/usr/local/bin/ldid",
        @"/usr/libexec/ldid",
        @"/bin/ldid",
        @"/var/jb/usr/libexec/am/ldid",
        @"/var/jb/usr/bin/ldid",
        @"/var/jb/usr/local/bin/ldid",
        @"/var/jb/usr/libexec/ldid",
        @"/var/jb/bin/ldid"
    ];
    for (NSString *path in cands) {
        if (access(path.fileSystemRepresentation, X_OK) == 0) {
            gCILdidPath = path;
            return path;
        }
    }
    gCILdidPath = @"";
    return nil;
}

static NSString *CIKCAccessPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/usr/local/bin/chengioskc",
        @"/usr/local/bin/chengioskc",
        @"/var/jb/usr/bin/chengioskc",
        @"/usr/bin/chengioskc"
    ];
    for (NSString *path in cands) {
        if (access(path.fileSystemRepresentation, X_OK) == 0) {
            return path;
        }
    }
    return nil;
}

static NSArray<NSString *> *CIKeychainCollectAgrps(NSString *bundleID) {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *value) {
        if (![value isKindOfClass:[NSString class]] || value.length == 0) {
            return;
        }
        if ([value isEqualToString:@"*"] || [value hasSuffix:@".*"]) {
            return;
        }
        if ([seen containsObject:value]) {
            return;
        }
        [seen addObject:value];
        [groups addObject:value];
    };
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *ents = nil;
    if ([proxy respondsToSelector:@selector(entitlements)]) {
        ents = proxy.entitlements;
    }
    if ([ents isKindOfClass:[NSDictionary class]]) {
        id kag = ents[@"keychain-access-groups"];
        if ([kag isKindOfClass:[NSArray class]]) {
            for (id group in kag) {
                add(group);
            }
        }
        id appId = ents[@"application-identifier"];
        add(appId);
        id appGroups = ents[@"com.apple.security.application-groups"];
        if ([appGroups isKindOfClass:[NSArray class]]) {
            for (id group in appGroups) {
                add(group);
            }
        }
    }
    add(bundleID);
    for (NSString *agrp in CIKeychainSQLListAgrps()) {
        if (CIKeychainSQLAgrpProtected(agrp, bundleID) || CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
            continue;
        }
        if (CIKeychainAgrpMatchesBundle(agrp, bundleID) || CIKeychainTextMatchesBundle(agrp, bundleID)) {
            add(agrp);
        }
    }
    NSString *low = bundleID.lowercaseString;
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        for (NSString *value in @[
            @"com.facebook.Facebook",
            @"group.com.facebook.Facebook",
            @"group.com.facebook.family",
            @"group.com.facebook.Messenger",
            @"group.com.facebook.Facebook.widget",
            @"group.com.facebook.mlite",
            @"group.com.facebook.platform",
            @"group.com.facebook.msysstorage",
            @"group.com.metaplatforms.family",
            @"43AQTK3442.com.facebook.Facebook",
            @"43AQTK3442.com.facebook.internal",
            @"43AQTK3442.com.facebook.Messenger"
        ]) {
            add(value);
        }
        for (NSString *agrp in CIKeychainSQLListAgrps()) {
            NSString *alow = agrp.lowercaseString ?: @"";
            if ([alow hasPrefix:@"43aqtk3442.com.facebook"] ||
                ([alow containsString:@"com.facebook"] && ![alow containsString:@"instagram"] && ![alow containsString:@"whatsapp"] && ![alow containsString:@"burbn"])) {
                add(agrp);
            }
        }
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        for (NSString *value in @[
            @"group.com.shopee.vn",
            @"group.com.shopee.SG",
            @"group.com.beeasy.marketplace.vn"
        ]) {
            add(value);
        }
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"]) {
        for (NSString *value in @[
            @"group.com.zhiliaoapp.musically",
            @"group.com.zhiliaoapp.musically.go",
            @"group.com.ss.iphone.ugc.Aweme",
            @"group.com.bytedance.tiktok",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go"
        ]) {
            add(value);
        }
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        for (NSString *value in @[
            @"com.apple.mobilesafari",
            @"group.com.apple.Safari",
            @"group.com.apple.safari"
        ]) {
            add(value);
        }
    }
    id appID = ents[@"application-identifier"];
    NSString *team = CITeamIDFromAppID([appID isKindOfClass:[NSString class]] ? appID : nil);
    if (team.length > 0) {
        add([NSString stringWithFormat:@"%@.%@", team, bundleID]);
    }
    gCIKCAgrpCount = groups.count;
    return groups;
}

static NSString *CIKeychainAccessGroupSuffix(NSString *group) {
    if (![group isKindOfClass:[NSString class]] || group.length == 0) {
        return @"";
    }
    if ([group hasPrefix:@"group."] || [group hasPrefix:@"com.apple."]) {
        return group.lowercaseString;
    }
    NSRange dot = [group rangeOfString:@"."];
    if (dot.location == NSNotFound || dot.location + 1 >= group.length) {
        return group.lowercaseString;
    }
    return [[group substringFromIndex:dot.location + 1] lowercaseString];
}

static NSString *CIKeychainMappedAccessGroup(NSString *backupGroup, NSArray<NSString *> *currentGroups) {
    if (![backupGroup isKindOfClass:[NSString class]] || backupGroup.length == 0) {
        return backupGroup;
    }
    for (NSString *current in currentGroups) {
        if ([current isKindOfClass:[NSString class]] && [current isEqualToString:backupGroup]) {
            return current;
        }
    }
    // A keychain access group can carry the App Store team prefix.  Keep the
    // logical suffix and replace only that prefix with the one currently
    // granted to the installed app.  Never remap Apple/group namespaces.
    NSString *oldSuffix = CIKeychainAccessGroupSuffix(backupGroup);
    if (oldSuffix.length == 0 || [backupGroup hasPrefix:@"group."] || [backupGroup hasPrefix:@"com.apple."]) {
        return backupGroup;
    }
    for (NSString *current in currentGroups) {
        if (![current isKindOfClass:[NSString class]] || current.length == 0 ||
            [current hasPrefix:@"group."] || [current hasPrefix:@"com.apple."]) {
            continue;
        }
        NSString *currentSuffix = CIKeychainAccessGroupSuffix(current);
        if ([currentSuffix isEqualToString:oldSuffix]) {
            return current;
        }
    }
    return backupGroup;
}

static NSArray<NSDictionary *> *CIRemapSignedKeychainRows(NSArray *rows, NSArray<NSString *> *currentGroups) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSMutableDictionary *copy = [row mutableCopy];
        NSString *oldGroup = [copy[@"accessGroup"] isKindOfClass:[NSString class]] ? copy[@"accessGroup"] : nil;
        NSString *mapped = CIKeychainMappedAccessGroup(oldGroup, currentGroups);
        if (mapped.length > 0) {
            copy[@"accessGroup"] = mapped;
        }
        [out addObject:copy];
    }
    return out;
}

static NSArray<NSDictionary *> *CIRemapSQLKeychainRows(NSArray *rows, NSArray<NSString *> *currentGroups) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSMutableDictionary *copy = [row mutableCopy];
        NSDictionary *sourceCols = [copy[@"cols"] isKindOfClass:[NSDictionary class]] ? copy[@"cols"] : nil;
        if (sourceCols.count > 0) {
            NSMutableDictionary *cols = [sourceCols mutableCopy];
            NSString *oldGroup = [CIKeychainSQLBackupValue(cols, @"agrp") isKindOfClass:[NSString class]] ? CIKeychainSQLBackupValue(cols, @"agrp") : nil;
            NSString *mapped = CIKeychainMappedAccessGroup(oldGroup, currentGroups);
            if (mapped.length > 0 && oldGroup.length > 0 && ![mapped isEqualToString:oldGroup]) {
                for (NSString *key in [cols.allKeys copy]) {
                    if ([[CIKeychainSQLCanonicalColumn(key) lowercaseString] isEqualToString:@"agrp"]) {
                        cols[key] = mapped;
                    }
                }
            }
            copy[@"cols"] = cols;
        }
        [out addObject:copy];
    }
    return out;
}

static NSString *CIKCWorkCopyDir(void) {
    NSString *root = CIWorkRootDir(YES);
    if (root.length == 0) {
        root = @"/var/tmp";
    }
    NSString *dir = [root stringByAppendingPathComponent:@"kcaccess"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    CIChmodWorld(dir, 0777);
    return dir;
}

static BOOL CIKeychainWriteEntitlements(NSString *path, NSArray<NSString *> *agrps, NSString *appId, NSArray<NSString *> *appGroups) {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *agrp in agrps) {
        if (agrp.length == 0 || [agrp isEqualToString:@"*"] || [seen containsObject:agrp]) {
            continue;
        }
        [seen addObject:agrp];
        [groups addObject:agrp];
    }
    if (groups.count == 0) {
        [groups addObject:@"com.vinhnv2507.chengioskc"];
    }
    NSString *ident = appId;
    if (ident.length == 0) {
        for (NSString *agrp in groups) {
            if ([agrp hasPrefix:@"group."] || [agrp hasPrefix:@"com.apple."] || [agrp isEqualToString:@"apple"] || [agrp isEqualToString:@"lockdown-identities"]) {
                continue;
            }
            if ([agrp containsString:@"."]) {
                ident = agrp;
                break;
            }
        }
    }
    if (ident.length == 0) {
        ident = @"com.vinhnv2507.chengioskc";
    }
    NSMutableDictionary *ent = [@{
        @"application-identifier": ident,
        @"keychain-access-groups": groups,
        @"com.apple.private.security.no-container": @YES,
        @"com.apple.private.security.container-required": @NO,
        @"com.apple.private.skip-library-validation": @YES
    } mutableCopy];
    if (appGroups.count > 0) {
        ent[@"com.apple.security.application-groups"] = appGroups;
    }
    return [ent writeToFile:path atomically:YES];
}

static NSString *gCIKCSignedBinCached = nil;
static NSString *gCIKCSignedSigCached = nil;

static NSString *CIKeychainPrepareSignedBinary(NSArray<NSString *> *agrps, NSString *bundleID, NSString **errorOut) {
    gCIKCSignedError = nil;
    NSString *sig = [NSString stringWithFormat:@"%@|%@", bundleID ?: @"", [agrps componentsJoinedByString:@","]];
    if (gCIKCSignedBinCached.length > 0 && [sig isEqualToString:gCIKCSignedSigCached] &&
        access(gCIKCSignedBinCached.fileSystemRepresentation, X_OK) == 0) {
        return gCIKCSignedBinCached;
    }
    NSString *src = CIKCAccessPath();
    if (src.length == 0) {
        gCIKCSignedError = @"thieu chengioskc";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    NSString *ldid = CILdidPath();
    if (ldid.length == 0) {
        gCIKCSignedError = @"thieu ldid (cai ldid hoac Apps Manager ldid, iOS 13.5+)";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = CIKCWorkCopyDir();
    NSString *dst = [dir stringByAppendingPathComponent:@"chengioskc"];
    NSString *entPath = [dir stringByAppendingPathComponent:@"chengioskc.ent.plist"];
    [fm removeItemAtPath:dst error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:src toPath:dst error:&copyErr]) {
        gCIKCSignedError = copyErr.localizedDescription ?: @"copy chengioskc fail";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    chmod(dst.fileSystemRepresentation, 0755);
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *ents = [proxy respondsToSelector:@selector(entitlements)] ? proxy.entitlements : nil;
    NSString *appId = [ents[@"application-identifier"] isKindOfClass:[NSString class]] ? ents[@"application-identifier"] : nil;
    if (appId.length == 0) {
        for (NSString *agrp in agrps) {
            if (![agrp isKindOfClass:[NSString class]] || [agrp hasPrefix:@"group."] || [agrp hasPrefix:@"com.apple."]) {
                continue;
            }
            if (bundleID.length > 0 && [agrp hasSuffix:bundleID]) {
                appId = agrp;
                break;
            }
        }
    }
    NSMutableArray<NSString *> *appGroups = [NSMutableArray array];
    id groups = ents[@"com.apple.security.application-groups"];
    if ([groups isKindOfClass:[NSArray class]]) {
        for (id group in groups) {
            if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
                [appGroups addObject:group];
            }
        }
    }
    if (!CIKeychainWriteEntitlements(entPath, agrps, appId, appGroups)) {
        gCIKCSignedError = @"ghi entitlements fail";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    NSString *flag = [@"-S" stringByAppendingString:entPath];
    int rc = CISpawnWait(ldid, @[flag, dst]);
    if (rc != 0) {
        rc = CISpawnWait(ldid, @[@"-S", entPath, dst]);
    }
    if (rc != 0) {
        gCIKCSignedError = [NSString stringWithFormat:@"ldid -S fail (%d) %@", rc, ldid];
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    chmod(dst.fileSystemRepresentation, 0755);
    if (geteuid() == 0) {
        chown(dst.fileSystemRepresentation, 0, 0);
        chmod(dst.fileSystemRepresentation, 0755);
    }
    gCIKCSignedBinCached = dst;
    gCIKCSignedSigCached = sig;
    return dst;
}

static NSDictionary *CIKeychainRunSigned(NSString *op, NSString *bundleID, NSArray<NSString *> *agrps, NSArray *items) {
    gCIKCSignedOK = NO;
    gCIKCSignedCount = 0;
    gCIKCSignedUID = -1;
    if (geteuid() != 0) {
        gCIKCSignedError = @"uid != 0";
        return nil;
    }
    NSString *bin = CIKeychainPrepareSignedBinary(agrps, bundleID, NULL);
    if (bin.length == 0) {
        return nil;
    }
    NSString *dir = [bin stringByDeletingLastPathComponent];
    NSString *inPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-in.plist", op]];
    NSString *outPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-out.plist", op]];
    NSMutableDictionary *job = [@{
        @"op": op ?: @"",
        @"bundleID": bundleID ?: @"",
        @"agrps": agrps ?: @[]
    } mutableCopy];
    if ([items isKindOfClass:[NSArray class]]) {
        job[@"items"] = items;
    }
    [[NSFileManager defaultManager] removeItemAtPath:inPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    if (!CIWritePlist(job, inPath)) {
        gCIKCSignedError = @"ghi job kc fail";
        return nil;
    }
    chmod(inPath.fileSystemRepresentation, 0666);
    lchown(inPath.fileSystemRepresentation, 501, 501);
    chmod(outPath.fileSystemRepresentation, 0666);
    lchown(outPath.fileSystemRepresentation, 501, 501);
    int rc = CISpawnWait(bin, @[op, inPath, outPath]);
    NSDictionary *out = [NSDictionary dictionaryWithContentsOfFile:outPath];
    if (![out isKindOfClass:[NSDictionary class]]) {
        gCIKCSignedError = [NSString stringWithFormat:@"chengioskc %@ no output rc=%d", op, rc];
        return nil;
    }
    gCIKCSignedOK = [out[@"ok"] boolValue];
    gCIKCSignedCount = [out[@"count"] unsignedIntegerValue];
    gCIKCSignedCountTotal += gCIKCSignedCount;
    if ([out[@"withData"] isKindOfClass:[NSNumber class]]) {
        gCIKCWithData = [out[@"withData"] unsignedIntegerValue];
    }
    if ([out[@"failed"] isKindOfClass:[NSNumber class]]) {
        gCIKCFailed = [out[@"failed"] unsignedIntegerValue];
    }
    if ([out[@"skipped"] isKindOfClass:[NSNumber class]]) {
        gCIKCSkipped = [out[@"skipped"] unsignedIntegerValue];
    }
    id kcUid = out[@"uid"];
    if ([kcUid isKindOfClass:[NSNumber class]]) {
        gCIKCSignedUID = [kcUid integerValue];
    }
    if (!gCIKCSignedOK && [out[@"error"] isKindOfClass:[NSString class]]) {
        gCIKCSignedError = out[@"error"];
    }
    return out;
}

static NSArray<NSDictionary *> *CIKeychainSignedDump(NSString *bundleID) {
    NSArray<NSString *> *agrps = CIKeychainCollectAgrps(bundleID);
    NSDictionary *out = CIKeychainRunSigned(@"dump", bundleID, agrps, nil);
    NSArray *items = out[@"items"];
    if ([items isKindOfClass:[NSArray class]]) {
        return items;
    }
    return @[];
}

static NSUInteger CIKeychainSignedRestore(NSString *bundleID, NSArray *items) {
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        return 0;
    }
    NSMutableArray<NSString *> *agrps = [CIKeychainCollectAgrps(bundleID) mutableCopy];
    if (!agrps) {
        agrps = [NSMutableArray array];
    }

    for (NSDictionary *row in items) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *agrp = row[@"accessGroup"];
        if ([agrp isKindOfClass:[NSString class]] && agrp.length > 0 && ![agrps containsObject:agrp]) {
            [agrps addObject:agrp];
        }
    }
    NSDictionary *out = CIKeychainRunSigned(@"restore", bundleID, agrps, items);
    return [out[@"count"] unsignedIntegerValue];
}

static NSUInteger CIKeychainSignedWipe(NSString *bundleID) {
    NSArray<NSString *> *agrps = CIKeychainCollectAgrps(bundleID);
    NSDictionary *out = CIKeychainRunSigned(@"wipe", bundleID, agrps, nil);
    return [out[@"count"] unsignedIntegerValue];
}

static NSArray<NSDictionary *> *CIKeychainDumpForBundle(NSString *bundleID) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSArray *signedItems = CIKeychainSignedDump(bundleID);
    for (NSDictionary *row in signedItems) {
        CIKeychainAddUniqueRow(out, row);
    }
    // The signed helper can report success with an empty/incomplete result
    // (for example when its entitlement list is incomplete or no row contains
    // data).  Do not treat that result as authoritative; let the
    // Security.framework fallback fill the missing token-bearing items.
    if (gCIKCSignedOK && out.count > 0 && gCIKCWithData > 0) {
        return out;
    }
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity
    ];
    NSArray<NSString *> *groups = CIKeychainCollectAgrps(bundleID);
    for (id cls in classes) {
        NSArray *items = CIKeychainCopyItems(cls, YES);
        if (items.count == 0) {
            items = CIKeychainCopyItems(cls, NO);
        }
        for (NSDictionary *item in items) {
            NSString *agrp = item[(__bridge id)kSecAttrAccessGroup] ?: @"";
            if (CIKeychainAgrpMatchesBundle(agrp, bundleID) || CIKeychainItemMatchesBundle(item, bundleID)) {
                CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
            }
        }
        for (NSString *service in CIKnownKeychainServices(bundleID)) {
            NSArray *more = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrService: service}, YES);
            if (more.count == 0) {
                more = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrService: service}, NO);
            }
            for (NSDictionary *item in more) {
                CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
            }
        }
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *group in groups) {
        if ([seen containsObject:group] || [group hasSuffix:@".*"]) {
            continue;
        }
        [seen addObject:group];
        BOOL agrpOK = CIKeychainAgrpMatchesBundle(group, bundleID) || CIKeychainTextMatchesBundle(group, bundleID);
        for (id cls in classes) {
            NSArray *items = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrAccessGroup: group}, YES);
            if (items.count == 0) {
                items = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrAccessGroup: group}, NO);
            }
            for (NSDictionary *item in items) {
                if (!agrpOK && !CIKeychainItemMatchesBundle(item, bundleID)) {
                    continue;
                }
                CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
            }
        }
    }
    return out;
}

static NSUInteger __attribute__((unused)) CIKeychainRestoreItems(NSArray *rows) {
    if (![rows isKindOfClass:[NSArray class]]) {
        return 0;
    }
    NSUInteger added = 0;
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id cls = CISecClassFromName(row[@"class"]);
        NSMutableDictionary *add = [NSMutableDictionary dictionary];
        add[(__bridge id)kSecClass] = cls;
        NSDictionary *map = @{
            @"service": (__bridge id)kSecAttrService,
            @"account": (__bridge id)kSecAttrAccount,
            @"accessGroup": (__bridge id)kSecAttrAccessGroup,
            @"label": (__bridge id)kSecAttrLabel,
            @"server": (__bridge id)kSecAttrServer,
            @"protocol": (__bridge id)kSecAttrProtocol,
            @"path": (__bridge id)kSecAttrPath,
            @"accessible": (__bridge id)kSecAttrAccessible
        };
        [map enumerateKeysAndObjectsUsingBlock:^(NSString *key, id secKey, BOOL *stop) {
            (void)stop;
            id value = row[key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                add[secKey] = value;
            }
        }];
        if ([row[@"port"] isKindOfClass:[NSNumber class]]) {
            add[(__bridge id)kSecAttrPort] = row[@"port"];
        }
        if ([row[@"synchronizable"] isKindOfClass:[NSNumber class]]) {
            add[(__bridge id)kSecAttrSynchronizable] = row[@"synchronizable"];
        }
        NSString *data64 = row[@"data"];
        if ([data64 isKindOfClass:[NSString class]] && data64.length > 0) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:data64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (data.length > 0) {
                add[(__bridge id)kSecValueData] = data;
            }
        }
        NSString *generic64 = row[@"generic"];
        if ([generic64 isKindOfClass:[NSString class]] && generic64.length > 0) {
            NSData *generic = [[NSData alloc] initWithBase64EncodedString:generic64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (generic.length > 0) {
                add[(__bridge id)kSecAttrGeneric] = generic;
            }
        }
        if (!add[(__bridge id)kSecAttrAccessible]) {
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        }
        NSString *agrp = row[@"accessGroup"];
        if ([agrp isKindOfClass:[NSString class]] && [agrp.lowercaseString hasPrefix:@"com.apple."] &&
            ![agrp.lowercaseString containsString:@"facebook"] &&
            ![agrp.lowercaseString containsString:@"shopee"] &&
            ![agrp.lowercaseString containsString:@"tiktok"] &&
            ![agrp.lowercaseString containsString:@"zhiliao"] &&
            ![agrp.lowercaseString containsString:@"musically"] &&
            ![agrp.lowercaseString containsString:@"aweme"]) {
            continue;
        }
        NSMutableDictionary *del = [add mutableCopy];
        [del removeObjectForKey:(__bridge id)kSecValueData];
        [del removeObjectForKey:(__bridge id)kSecAttrAccessible];
        del[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        SecItemDelete((__bridge CFDictionaryRef)del);
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (status == errSecDuplicateItem) {
            SecItemDelete((__bridge CFDictionaryRef)del);
            status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        }
        if (status == errSecSuccess) {
            added += 1;
        }
    }
    return added;
}

static BOOL CIGroupAlwaysWipe(NSString *group, NSString *bundleID) {
    NSString *glow = group.lowercaseString;
    NSString *blow = bundleID.lowercaseString;
    if ([blow hasPrefix:@"com.facebook."] || [blow hasPrefix:@"com.meta."]) {
        if ([glow containsString:@"instagram"] || [glow containsString:@"burbn"] ||
            [glow containsString:@"whatsapp"] || [glow containsString:@"threads"]) {
            return NO;
        }
        return [glow containsString:@"facebook"] || [glow containsString:@"messenger"] ||
               [glow containsString:@"msysstorage"] || [glow containsString:@"metaplatforms"];
    }
    if ([blow containsString:@"shopee"] || [blow hasPrefix:@"com.beeasy."]) {
        return [glow containsString:@"shopee"] || [glow containsString:@"beeasy"];
    }
    if ([blow hasPrefix:@"com.zhiliaoapp."] || [blow containsString:@"tiktok"] ||
        [blow hasPrefix:@"com.ss.iphone."] || [blow containsString:@"aweme"]) {
        return [glow containsString:@"zhiliao"] || [glow containsString:@"tiktok"] ||
               [glow containsString:@"musically"] || [glow containsString:@"aweme"] ||
               [glow containsString:@"bytedance"];
    }
    return NO;
}

static NSArray<NSString *> *CISupportPathsForBundle(NSString *bundleID) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Library/Application Support",
        @"/private/var/mobile/Library/Application Support"
    ];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:bundleID];
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low containsString:@"facebook"]) {
        [names addObjectsFromArray:@[@"Facebook", @"com.facebook.Facebook", @"com.facebook.Messenger"]];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        [names addObjectsFromArray:@[@"Shopee", @"AppsFlyer", @"Adjust", @"Firebase", @"Tongdun", @"TrustDecision", @"FMDevice", bundleID]];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] ||
        [low containsString:@"musically"]) {
        [names addObjectsFromArray:@[
            @"TikTok", @"musically", @"Aweme", @"ByteDance",
            @"com.zhiliaoapp.musically", bundleID
        ]];
    }
    for (NSString *root in roots) {
        for (NSString *name in names) {
            [paths addObject:[root stringByAppendingPathComponent:name]];
        }
    }
    return paths;
}

static NSArray<NSString *> *CIKnownKeychainServices(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        return @[
            @"com.facebook.sdk:TokenInformation",
            @"com.facebook.sdk.TokenInformation",
            @"com.facebook.sdk.TokenInformationV2",
            @"com.facebook.sdk:FBSDKAccessToken",
            @"com.facebook.sdk.accessToken",
            @"FBSDKAccessToken",
            @"FBSDKAuthenticationToken",
            @"FBSDKAccessTokenInformation",
            @"com.facebook.auth.token",
            @"com.facebook.auth.oauth",
            @"com.facebook.Facebook",
            @"com.facebook.Messenger",
            @"com.facebook.sdk:AnonymousID",
            @"com.facebook.sdk.anonid",
            @"com.facebook.sdk.login",
            @"com.facebook.accountstore",
            @"FBAccessTokenInformationKey",
            @"kFacebookSDKAccessTokenKey",
            @"DBLAccounts",
            @"com.facebook.DBL",
            @"device_based_login",
            @"DeviceBasedLogin",
            @"FBAccountStore",
            @"FBSavedAccounts",
            @"com.facebook.accountswitcher",
            @"FBDeviceBasedLogin",
            @"saved_accounts",
            @"com.facebook.sdk.UUID",
            @"com.facebook.sdk:UUID",
            @"family_device_id",
            @"machine_id",
            @"fb_device_id",
            @"analytics_device_id",
            @"com.facebook.device_id",
            @"FBSDKAppEventsDeviceID",
            @"com.facebook.sdk.advertiserID",
            @"com.facebook.sdk:deviceID"
        ];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return @[
            @"ShopeeAccessToken",
            @"shopee_session",
            @"com.shopee.account",
            @"com.shopee.vn",
            @"com.beeasy.marketplace.vn",
            @"device_id",
            @"deviceid",
            @"deviceId",
            @"install_id",
            @"installId",
            @"uuid",
            @"UUID",
            @"appsflyer",
            @"AF_DEVICE_ID",
            @"com.appsflyer.deviceId",
            @"adjust",
            @"shopee_device",
            @"ShopeeDeviceId",
            @"did",
            @"umeng",
            @"firebase",
            @"Firebase",
            @"com.google.iid",
            @"IDFA",
            @"idfa",
            @"advertisingIdentifier",
            @"com.appsflyer.uid",
            @"com.appsflyer.AppleAppID",
            @"appsFlyerId",
            @"adjust_identifier",
            @"adj_device_id",
            @"com.adjust.sdk",
            @"FIRInstallations",
            @"com.firebase.FIRInstallations.installation-id",
            @"com.google.iid.token-cache",
            @"FMDeviceManager",
            @"FMDeviceId",
            @"blackBox",
            @"blackbox",
            @"TDID",
            @"tdid",
            @"com.tongdun.deviceid",
            @"TrustDecision",
            @"seclink",
            @"device_fingerprint",
            @"ShopeeDFP",
            @"shopee_dfp",
            @"SPDeviceId"
        ];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"]) {
        return @[
            @"TTAccount",
            @"TTAccountSession",
            @"TTAccountAuth",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go",
            @"aweme",
            @"BDAccount",
            @"tt_passport",
            @"AwemeUserDefaults",
            @"device_id",
            @"install_id",
            @"odin_tt",
            @"openudid",
            @"cdid",
            @"google_aid",
            @"tt_device_id",
            @"krypton_device_id",
            @"msdk_guid",
            @"appsflyer",
            @"adjust",
            @"idfv",
            @"idfa"
        ];
    }
    return bundleID.length ? @[ bundleID ] : @[];
}

static void CIWipeKnownKeychainServices(NSString *bundleID) {
    NSArray<NSString *> *services = CIKnownKeychainServices(bundleID);
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword
    ];
    for (NSString *service in services) {
        for (id cls in classes) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: cls,
                (__bridge id)kSecAttrService: service,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
    }
    NSString *low = bundleID.lowercaseString;
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        NSArray<NSString *> *servers = @[
            @"shopee.vn", @"shopee.com", @"shopee.sg", @"shopee.co.id", @"shopee.co.th",
            @"mall.shopee.vn", @"seller.shopee.vn"
        ];
        for (NSString *server in servers) {
            for (id cls in classes) {
                NSDictionary *query = @{
                    (__bridge id)kSecClass: cls,
                    (__bridge id)kSecAttrServer: server,
                    (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
                };
                SecItemDelete((__bridge CFDictionaryRef)query);
            }
        }
    }
    if ([low hasPrefix:@"com.facebook."] || [low containsString:@"facebook"]) {
        NSArray<NSString *> *servers = @[
            @"facebook.com", @"m.facebook.com", @"graph.facebook.com", @"www.facebook.com"
        ];
        for (NSString *server in servers) {
            for (id cls in classes) {
                NSDictionary *query = @{
                    (__bridge id)kSecClass: cls,
                    (__bridge id)kSecAttrServer: server,
                    (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
                };
                SecItemDelete((__bridge CFDictionaryRef)query);
            }
        }
    }
}

static void CIWipeKeychainForProxy(LSApplicationProxy *proxy, NSString *bundleID) {
    if (bundleID.length == 0) {
        return;
    }
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    id ents = nil;
    if ([proxy respondsToSelector:@selector(entitlements)]) {
        ents = proxy.entitlements;
    }
    if ([ents isKindOfClass:[NSDictionary class]]) {
        id kag = ents[@"keychain-access-groups"];
        if ([kag isKindOfClass:[NSArray class]]) {
            for (id group in kag) {
                if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
                    [groups addObject:group];
                }
            }
        }
        id appId = ents[@"application-identifier"];
        if ([appId isKindOfClass:[NSString class]] && [appId length] > 0) {
            [groups addObject:appId];
        }
        id appGroups = ents[@"com.apple.security.application-groups"];
        if ([appGroups isKindOfClass:[NSArray class]]) {
            for (id group in appGroups) {
                if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
                    [groups addObject:group];
                }
            }
        }
    }
    [groups addObject:bundleID];
    if ([bundleID.lowercaseString hasPrefix:@"com.facebook."]) {
        [groups addObjectsFromArray:@[
            @"com.facebook.Facebook",
            @"group.com.facebook.Facebook",
            @"group.com.facebook.family",
            @"group.com.facebook.Messenger",
            @"group.com.facebook.Facebook.widget",
            @"group.com.facebook.mlite",
            @"group.com.facebook.platform",
            @"group.com.facebook.msysstorage",
            @"group.com.metaplatforms.family",
            @"43AQTK3442.com.facebook.Facebook",
            @"43AQTK3442.com.facebook.internal",
            @"43AQTK3442.com.facebook.Messenger"
        ]];
    }
    if ([bundleID.lowercaseString containsString:@"shopee"] || [bundleID.lowercaseString hasPrefix:@"com.beeasy."]) {
        [groups addObjectsFromArray:@[
            @"group.com.shopee.vn",
            @"group.com.shopee.SG",
            @"group.com.shopee.id",
            @"group.com.shopee.my",
            @"group.com.shopee.th",
            @"group.com.shopee.tw",
            @"group.com.shopee.ph",
            @"group.com.shopee.intlseller",
            @"group.com.beeasy.marketplace.vn",
            @"group.com.shopeepay.vn"
        ]];
    }
    if ([bundleID.lowercaseString containsString:@"tiktok"] || [bundleID.lowercaseString hasPrefix:@"com.zhiliaoapp."] ||
        [bundleID.lowercaseString hasPrefix:@"com.ss.iphone."] || [bundleID.lowercaseString containsString:@"aweme"]) {
        [groups addObjectsFromArray:@[
            @"group.com.zhiliaoapp.musically",
            @"group.com.zhiliaoapp.musically.go",
            @"group.com.ss.iphone.ugc.Aweme",
            @"group.com.bytedance.tiktok",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go"
        ]];
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        [groups addObjectsFromArray:@[
            @"com.apple.mobilesafari",
            @"group.com.apple.Safari",
            @"group.com.apple.safari"
        ]];
    }
    id appID = ents[@"application-identifier"];
    NSString *team = CITeamIDFromAppID([appID isKindOfClass:[NSString class]] ? appID : nil);
    if (team.length > 0) {
        [groups addObject:[NSString stringWithFormat:@"%@.%@", team, bundleID]];
    }
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity
    ];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *group in groups) {
        if ([seen containsObject:group]) {
            continue;
        }
        [seen addObject:group];
        NSString *low = group.lowercaseString;
        if ([group hasSuffix:@".*"]) {
            continue;
        }
        if ([low hasPrefix:@"com.apple."] && ![low containsString:bundleID.lowercaseString] &&
            !ChengIOSBundleIsSafari(bundleID) && !CIKeychainTextMatchesBundle(low, bundleID)) {
            continue;
        }
        for (id cls in classes) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: cls,
                (__bridge id)kSecAttrAccessGroup: group,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
    }
    CIKeychainDeleteMatching((__bridge id)kSecClassGenericPassword, bundleID);
    CIKeychainDeleteMatching((__bridge id)kSecClassInternetPassword, bundleID);
    CIWipeKnownKeychainServices(bundleID);
}


static NSArray<NSString *> *CIAccountNeedles(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        return @[@"facebook", @"fbsdk", @"messenger.com"];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return @[@"shopee", @"beeasy"];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] || [low containsString:@"musically"]) {
        return @[@"tiktok", @"musically", @"zhiliao", @"aweme", @"bytedance"];
    }
    return @[];
}

static void CIWipeAccountsForBundle(NSString *bundleID) {
    if (gCIFastErase) {
        return;
    }
    if (bundleID.length == 0 || geteuid() != 0) {
        return;
    }
    NSArray<NSString *> *needles = CIAccountNeedles(bundleID);
    if (needles.count == 0) {
        return;
    }
    NSArray<NSString *> *cands = @[
        @"/var/mobile/Library/Accounts/Accounts3.sqlite",
        @"/private/var/mobile/Library/Accounts/Accounts3.sqlite"
    ];
    NSString *path = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in cands) {
        if ([fm fileExistsAtPath:cand]) {
            path = cand;
            break;
        }
    }
    if (path.length == 0) {
        return;
    }
    CIRunKillall(@"accountsd");
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        return;
    }
    sqlite3_busy_timeout(db, 8000);
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    NSArray<NSString *> *queries = @[
        @"SELECT a.Z_PK, ifnull(a.ZUSERNAME,''), ifnull(t.ZIDENTIFIER,'') FROM ZACCOUNT a LEFT JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK",
        @"SELECT Z_PK, ifnull(ZUSERNAME,''), ifnull(ZACCOUNTDESCRIPTION,'') FROM ZACCOUNT"
    ];
    sqlite3_stmt *stmt = NULL;
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    for (NSString *sql in queries) {
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            stmt = NULL;
            continue;
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            sqlite3_int64 pk = sqlite3_column_int64(stmt, 0);
            NSMutableString *blob = [NSMutableString string];
            int n = sqlite3_column_count(stmt);
            for (int i = 1; i < n; i++) {
                const unsigned char *txt = sqlite3_column_text(stmt, i);
                if (txt) {
                    [blob appendFormat:@"%s ", txt];
                }
            }
            NSString *low = blob.lowercaseString;
            BOOL hit = NO;
            for (NSString *needle in needles) {
                if ([low containsString:needle]) {
                    hit = YES;
                    break;
                }
            }
            if (hit) {
                [ids addObject:@(pk)];
            }
        }
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (ids.count > 0) {
            break;
        }
    }
    sqlite3_stmt *del = NULL;
    if (ids.count > 0 && sqlite3_prepare_v2(db, "DELETE FROM ZACCOUNT WHERE Z_PK=?", -1, &del, NULL) == SQLITE_OK) {
        for (NSNumber *pk in ids) {
            sqlite3_reset(del);
            sqlite3_clear_bindings(del);
            sqlite3_bind_int64(del, 1, pk.longLongValue);
            sqlite3_step(del);
        }
        sqlite3_finalize(del);
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    sqlite3_close(db);
    CIRunKillall(@"accountsd");
}

static NSDictionary *CIReadMeta(NSString *backupID) {
    NSString *dir = CIBackupDirForID(backupID);
    if (dir.length == 0) {
        return nil;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"meta.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *out = [meta isKindOfClass:[NSDictionary class]] ? [meta mutableCopy] : [NSMutableDictionary dictionary];
    out[@"id"] = backupID;
    out[@"path"] = dir;
    if (![out[@"name"] isKindOfClass:[NSString class]] || [out[@"name"] length] == 0) {
        out[@"name"] = backupID;
    }
    return out;
}

NSDictionary *ChengIOSBackupInfo(NSString *backupID) {
    return CIReadMeta(backupID);
}

NSArray<NSDictionary *> *ChengIOSListBackups(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSDictionary *> *map = [NSMutableDictionary dictionary];
    for (NSString *root in CIBackupRootCandidates()) {
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
        for (NSString *name in names) {
            if (map[name] || !CIValidBackupID(name)) {
                continue;
            }
            NSDictionary *meta = CIReadMeta(name);
            if (meta) {
                map[name] = meta;
            }
        }
    }
    NSMutableArray<NSDictionary *> *items = [map.allValues mutableCopy];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *ca = a[@"created"] ?: a[@"id"] ?: @"";
        NSString *cb = b[@"created"] ?: b[@"id"] ?: @"";
        return [cb compare:ca];
    }];
    return items;
}

NSString *ChengIOSLatestBackupID(void) {
    return ChengIOSListBackups().firstObject[@"id"];
}

static BOOL CIWriteMeta(NSString *backupID, NSDictionary *meta) {
    if (!CIValidBackupID(backupID)) {
        return NO;
    }
    NSString *dir = CIBackupDirForID(backupID);
    if (dir.length == 0) {
        dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *clean = [meta mutableCopy] ?: [NSMutableDictionary dictionary];
    [clean removeObjectForKey:@"path"];
    NSString *path = [dir stringByAppendingPathComponent:@"meta.plist"];
    return [clean writeToFile:path atomically:YES];
}

NSDictionary *ChengIOSCreateBackup(NSString *name, NSArray<NSString *> *bundleIDs, BOOL includeAppData, NSError **error) {
    if (CIIsRootProcess()) {
        CIContainerIndexClear();
    }
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(2, @"chengiosroot uid != 0");
            }
            return nil;
        }
        NSDictionary *remote = CIRunRootOp(@{
            @"op": @"backup",
            @"name": name ?: @"",
            @"includeAppData": @(includeAppData),
            @"bundles": bundleIDs ?: @[]
        }, error);
        if (remote) {
            if ([remote[@"ok"] boolValue] && [remote[@"meta"] isKindOfClass:[NSDictionary class]]) {
                return remote[@"meta"];
            }
            if (error && !*error) {
                *error = CIError(2, remote[@"error"] ?: @"Backup root helper loi.");
            }
            return nil;
        }
    }
    NSString *backupID = CINewBackupID();
    NSString *dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
        if (error && !*error) {
            *error = CIError(2, @"Khong tao duoc thu muc backup.");
        }
        return nil;
    }

    gCIKCSignedError = nil;
    gCIKCSignedCount = 0;
    gCIKCSignedCountTotal = 0;
    gCIKCWithData = 0;
    gCIKCFailed = 0;
    gCIKCSkipped = 0;
    gCIKCSignedUID = -1;
    gCIKCAgrpCount = 0;
    gCIKCSignedOK = NO;
    NSString *label = CISanitizeName(name);
    if (label.length == 0) {
        NSArray *nameBundles = includeAppData ? (bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs()) : @[];
        label = ChengIOSSuggestedBackupNameForBundles(nameBundles);
    }

    NSDictionary *prefs = ChengIOSLoadRawPrefs() ?: @{};
    NSString *profilePath = [dir stringByAppendingPathComponent:@"profile.plist"];
    [prefs writeToFile:profilePath atomically:YES];

    NSMutableArray<NSString *> *savedBundles = [NSMutableArray array];
    NSMutableArray<NSString *> *failedBundles = [NSMutableArray array];
    unsigned long long bytes = 0;
    NSUInteger keychainCount = 0;
    NSUInteger keychainWithData = 0;
    NSUInteger sqlCountTotal = 0;
    NSUInteger secCountTotal = 0;
    NSArray<NSString *> *requestedTargets = bundleIDs;
    if (includeAppData && requestedTargets.count == 0) {
        requestedTargets = ChengIOSUserSelectedBundleIDs();
    }
    NSArray<NSString *> *targets = includeAppData ? CIExpandBackupTargets(requestedTargets) : @[];
    if (includeAppData) {
        CICopyStatsReset();
        NSMutableDictionary *kcByBundle = [NSMutableDictionary dictionary];
        NSMutableDictionary *sqlByBundle = [NSMutableDictionary dictionary];
        for (NSString *bundleID in targets) {
            if (![bundleID isKindOfClass:[NSString class]] || ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            CITerminateRelatedBundles(bundleID);
        }
        [NSThread sleepForTimeInterval:0.2];
        CIRunKillall(@"cfprefsd");
        for (NSString *bundleID in targets) {
            if (![bundleID isKindOfClass:[NSString class]] || ChengIOSBundleIsProtected(bundleID)) {
                [failedBundles addObject:bundleID ?: @""];
                continue;
            }
            NSMutableArray *keychain = [(CIKeychainDumpForBundle(bundleID) ?: @[]) mutableCopy];
            NSArray *sqlItems = CIKeychainSQLDumpForBundle(bundleID) ?: @[];
            sqlCountTotal += sqlItems.count;
            kcByBundle[bundleID] = keychain ?: @[];
            sqlByBundle[bundleID] = sqlItems;
        }
        for (NSString *bundleID in targets) {
            if (![bundleID isKindOfClass:[NSString class]] || ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *dataPath = CIDataPath(bundleID);
            NSDictionary *groups = CIAllGroupPaths(bundleID);
            NSDictionary *plugins = CIPluginPaths(bundleID);
            NSArray *keychain = kcByBundle[bundleID];
            if (![keychain isKindOfClass:[NSArray class]]) {
                keychain = @[];
            }
            NSArray *sqlItems = sqlByBundle[bundleID];
            if (![sqlItems isKindOfClass:[NSArray class]]) {
                sqlItems = @[];
            }
            if (dataPath.length == 0 && groups.count == 0 && plugins.count == 0 &&
                keychain.count == 0 && sqlItems.count == 0) {
                [failedBundles addObject:bundleID];
                continue;
            }
            NSString *appDir = [[dir stringByAppendingPathComponent:@"apps"] stringByAppendingPathComponent:bundleID];
            [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];
            if (dataPath.length > 0) {
                bytes += CIBackupContainer(dataPath, [appDir stringByAppendingPathComponent:@"data"]);
            }
            for (NSString *group in groups) {
                bytes += CIBackupContainer(groups[group], [[appDir stringByAppendingPathComponent:@"groups"] stringByAppendingPathComponent:group]);
            }
            for (NSString *pluginID in plugins) {
                bytes += CIBackupContainer(plugins[pluginID], [[appDir stringByAppendingPathComponent:@"plugins"] stringByAppendingPathComponent:pluginID]);
            }
            if (keychain.count > 0) {
                NSString *kcPath = [appDir stringByAppendingPathComponent:@"keychain.plist"];
                [keychain writeToFile:kcPath atomically:YES];
                keychainCount += keychain.count;
                keychainWithData += CIKeychainCountWithData(keychain);
            }
            NSArray *sqlSaved = sqlByBundle[bundleID];
            if ([sqlSaved isKindOfClass:[NSArray class]] && sqlSaved.count > 0) {
                NSString *sqlPath = [appDir stringByAppendingPathComponent:@"keychain-sql.plist"];
                [sqlSaved writeToFile:sqlPath atomically:YES];
            }
            if (ChengIOSBundleIsSafari(bundleID)) {
                CIKillSafariProcesses();
                bytes += CICopyTree(@"/var/mobile/Library/Safari", [appDir stringByAppendingPathComponent:@"safari-library"]);
                bytes += CICopyTree(@"/var/mobile/Library/Cookies", [appDir stringByAppendingPathComponent:@"cookies"]);
                bytes += CICopyTree(@"/var/mobile/Library/WebKit", [appDir stringByAppendingPathComponent:@"webkit"]);
                bytes += CICopyTree(@"/var/mobile/Library/HTTPStorages", [appDir stringByAppendingPathComponent:@"httpstorages"]);
            }
            [savedBundles addObject:bundleID];
        }
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSMutableDictionary *meta = [@{
        @"id": backupID,
        @"name": label,
        @"created": [fmt stringFromDate:[NSDate date]],
        @"version": @"1.2.53",
        @"includeAppData": @(includeAppData),
        @"requestedBundles": includeAppData ? (requestedTargets ?: @[]) : @[],
        @"expandedBundles": includeAppData ? (targets ?: @[]) : @[],
        @"bundles": savedBundles,
        @"failedBundles": failedBundles,
        @"bytes": @(bytes),
        @"copyFiles": @(gCICopyFiles),
        @"copyFailed": @(gCICopyFailed),
        @"keychainItems": @(keychainCount),
        @"keychainWithData": @(keychainWithData),
        @"sqlOpened": @(gCIKeychainSQLLastOpen),
        @"sqlPath": gCIKeychainSQLLastPath ?: @"",
        @"sqlCount": @(sqlCountTotal),
        @"secCount": @(keychainCount),
        @"signedCount": @(gCIKCSignedCountTotal),
        @"signedOK": @(gCIKCSignedOK),
        @"agrpCount": @(gCIKCAgrpCount),
        @"kcUid": @(gCIKCSignedUID),
        @"ldid": CILdidPath() ?: @"",
        @"kcaccess": CIKCAccessPath() ?: @"",
        @"signedError": gCIKCSignedError ?: @"",
        @"asRoot": @(geteuid() == 0),
        @"uid": @(geteuid()),
        @"daemon": @(CIInDaemonProcess()),
        @"helper": CIRootHelperPath() ?: @"",
        @"profileSummary": ChengIOSProfileSummary(ChengIOSLoadSavedProfile()) ?: @""
    } mutableCopy];
    CIWriteMeta(backupID, meta);

    NSString *summaryPath = [dir stringByAppendingPathComponent:@"summary.txt"];
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@\n%@\n\n", label, meta[@"created"]];
    [text appendFormat:@"%@\n", meta[@"profileSummary"]];
    if (savedBundles.count > 0) {
        [text appendFormat:@"\nApps:\n%@\n", [savedBundles componentsJoinedByString:@"\n"]];
    }
    [text writeToFile:summaryPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    meta[@"path"] = dir;
    return meta;
}

BOOL ChengIOSRestoreBackup(NSString *backupID, BOOL restoreProfile, BOOL restoreAppData, NSError **error) {
    if (CIIsRootProcess()) {
        CIContainerIndexClear();
    }
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(3, @"chengiosroot uid != 0");
            }
            return NO;
        }
        NSDictionary *remote = CIRunRootOp(@{
            @"op": @"restore",
            @"backupID": backupID ?: @"",
            @"restoreProfile": @(restoreProfile),
            @"restoreAppData": @(restoreAppData)
        }, error);
        if (remote) {
            id stats = remote[@"restoreStats"];
            if ([stats isKindOfClass:[NSDictionary class]]) {
                gCILastRestoreStats = [stats mutableCopy];
            }
            if ([remote[@"ok"] boolValue]) {
                return YES;
            }
            if (error && !*error) {
                *error = CIError(3, remote[@"error"] ?: @"Restore root helper loi.");
            }
            return NO;
        }
    }
    CICopyStatsReset();
    gCILastRestoreStats = nil;
    NSDictionary *meta = CIReadMeta(backupID);
    if (!meta) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    NSString *dir = meta[@"path"];
    if (restoreProfile) {
        NSDictionary *profile = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"profile.plist"]];
        if (profile.count == 0) {
            if (error) {
                *error = CIError(3, @"Backup khong co ho so.");
            }
            return NO;
        }
        ChengIOSReplaceRawPrefs(profile);
    }
    if (restoreAppData) {
        CICopyStatsReset();
        gCILastRestoreStats = [@{
            @"backupID": backupID ?: @"",
            @"copiedBytes": @0,
            @"copiedFiles": @0,
            @"copyFailed": @0,
            @"keychainRestored": @0,
            @"keychainSignedRestored": @0,
            @"keychainSQLRestored": @0,
            @"kcUid": @-1
        } mutableCopy];
        NSString *appsDir = [dir stringByAppendingPathComponent:@"apps"];
        NSArray<NSString *> *bundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
        for (NSString *bundleID in bundles) {
            if (![bundleID isKindOfClass:[NSString class]] ||
                [bundleID containsString:@"/"] || [bundleID containsString:@".."] ||
                ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            CITerminateRelatedBundles(bundleID);
        }
        [NSThread sleepForTimeInterval:0.2];
        CIRunKillall(@"cfprefsd");
        [NSThread sleepForTimeInterval:0.05];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *bundleID in bundles) {
            if (![bundleID isKindOfClass:[NSString class]] ||
                [bundleID containsString:@"/"] || [bundleID containsString:@".."] ||
                ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *appDir = [appsDir stringByAppendingPathComponent:bundleID];
            NSString *live = CIDataPath(bundleID);
            if (live.length > 0) {
                NSString *savedData = [appDir stringByAppendingPathComponent:@"data"];
                CIRestoreContainer(savedData, live);
            }
            NSString *groupsDir = [appDir stringByAppendingPathComponent:@"groups"];
            NSArray<NSString *> *groupIDs = [fm contentsOfDirectoryAtPath:groupsDir error:nil];
            NSDictionary *liveGroups = CIAllGroupPaths(bundleID);
            for (NSString *groupID in groupIDs) {
                NSString *dest = liveGroups[groupID];
                if (dest.length == 0) {
                    dest = CIScanContainer(@[
                        @"/var/mobile/Containers/Shared/AppGroup",
                        @"/private/var/mobile/Containers/Shared/AppGroup"
                    ], groupID);
                }
                if (dest.length == 0) {
                    continue;
                }
                CIRestoreContainer([groupsDir stringByAppendingPathComponent:groupID], dest);
            }
            NSString *pluginsDir = [appDir stringByAppendingPathComponent:@"plugins"];
            NSArray<NSString *> *pluginIDs = [fm contentsOfDirectoryAtPath:pluginsDir error:nil];
            NSDictionary *livePlugins = CIPluginPaths(bundleID);
            for (NSString *pluginID in pluginIDs) {
                NSString *dest = livePlugins[pluginID];
                if (dest.length == 0) {
                    dest = CIScanContainer(@[
                        @"/var/mobile/Containers/Data/PluginKitPlugin",
                        @"/private/var/mobile/Containers/Data/PluginKitPlugin"
                    ], pluginID);
                }
                if (dest.length == 0) {
                    continue;
                }
                CIRestoreContainer([pluginsDir stringByAppendingPathComponent:pluginID], dest);
            }
            if (ChengIOSBundleIsSafari(bundleID)) {
                CIKillSafariProcesses();
                NSDictionary *safariMap = @{
                    @"safari-library": @"/var/mobile/Library/Safari",
                    @"cookies": @"/var/mobile/Library/Cookies",
                    @"webkit": @"/var/mobile/Library/WebKit",
                    @"httpstorages": @"/var/mobile/Library/HTTPStorages"
                };
                [safariMap enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *dest, BOOL *stop) {
                    (void)stop;
                    NSString *saved = [appDir stringByAppendingPathComponent:name];
                    if (![fm fileExistsAtPath:saved] || !CIPathSafeToMutate(dest)) {
                        return;
                    }
                    CIWipeContents(dest);
                    CICopyTree(saved, dest);
                    CIChownMobileR(dest);
                }];
            }
            CIRunKillall(@"cfprefsd");
            [NSThread sleepForTimeInterval:0.05];
            CITerminateRelatedBundles(bundleID);
        }

        // Restore keychain once per app family, after every data/group container
        // has been copied.  Facebook/Messenger and TikTok/Aweme share access
        // groups; wiping/restoring each companion in sequence used to erase the
        // rows restored by the previous companion.
        NSMutableSet<NSString *> *restoredFamilies = [NSMutableSet set];
        for (NSString *bundleID in bundles) {
            if (![bundleID isKindOfClass:[NSString class]] ||
                [bundleID containsString:@"/"] || [bundleID containsString:@".."] ||
                ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *family = CIKeychainRestoreFamilyKey(bundleID);
            if (family.length == 0 || [restoredFamilies containsObject:family]) {
                continue;
            }
            [restoredFamilies addObject:family];
            NSMutableArray *sqlRows = [NSMutableArray array];
            NSMutableArray *secRows = [NSMutableArray array];
            for (NSString *member in bundles) {
                if (![member isKindOfClass:[NSString class]] ||
                    ![[CIKeychainRestoreFamilyKey(member) lowercaseString] isEqualToString:family.lowercaseString]) {
                    continue;
                }
                NSString *memberDir = [appsDir stringByAppendingPathComponent:member];
                NSArray *keychainFile = [NSArray arrayWithContentsOfFile:[memberDir stringByAppendingPathComponent:@"keychain.plist"]];
                NSArray *sqlFile = [NSArray arrayWithContentsOfFile:[memberDir stringByAppendingPathComponent:@"keychain-sql.plist"]];
                if (![keychainFile isKindOfClass:[NSArray class]]) {
                    keychainFile = @[];
                }
                if (![sqlFile isKindOfClass:[NSArray class]]) {
                    sqlFile = @[];
                }
                for (NSDictionary *row in keychainFile) {
                    if (![row isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }
                    if ([row[@"source"] isEqualToString:@"sqlite"] || row[@"cols"]) {
                        CIKeychainSQLAddUniqueRow(sqlRows, row);
                    } else {
                        [secRows addObject:row];
                    }
                }
                for (NSDictionary *row in sqlFile) {
                    CIKeychainSQLAddUniqueRow(sqlRows, row);
                }
            }
            if (sqlRows.count == 0 && secRows.count == 0) {
                continue;
            }
            CITerminateRelatedBundles(bundleID);
            NSArray<NSString *> *currentGroups = CIKeychainCollectAgrps(bundleID);
            NSArray *mappedSecRows = CIRemapSignedKeychainRows(secRows, currentGroups);
            NSArray *mappedSQLRows = CIRemapSQLKeychainRows(sqlRows, currentGroups);
            CIKeychainSignedWipe(bundleID);
            CIWipeKeychainForProxy(CIProxy(bundleID), bundleID);
            CIKeychainSQLWipeForBundle(bundleID);
            CIRunKillall(@"securityd");
            CIRunKillall(@"secd");
            [NSThread sleepForTimeInterval:0.2];
            gCIKCFailed = 0;
            gCIKCSkipped = 0;
            NSUInteger sqlRestored = 0;
            NSUInteger signedRestored = 0;
            BOOL facebookOrTikTok = [family isEqualToString:@"facebook"] || [family isEqualToString:@"tiktok"];
            if (facebookOrTikTok) {
                // For Facebook/TikTok write raw rows first. securityd may
                // rebuild/flush its database, so the signed pass comes second.
                sqlRestored = mappedSQLRows.count > 0 ? CIKeychainSQLRestoreRows(mappedSQLRows) : 0;
                signedRestored = mappedSecRows.count > 0 ? CIKeychainSignedRestore(bundleID, mappedSecRows) : 0;
            } else {
                // Preserve the proven Shopee/other-app restore order.
                signedRestored = mappedSecRows.count > 0 ? CIKeychainSignedRestore(bundleID, mappedSecRows) : 0;
                sqlRestored = mappedSQLRows.count > 0 ? CIKeychainSQLRestoreRows(mappedSQLRows) : 0;
            }
            NSUInteger restored = signedRestored + sqlRestored;
            if (!gCILastRestoreStats) {
                gCILastRestoreStats = [NSMutableDictionary dictionary];
            }
            gCILastRestoreStats[@"keychainRestored"] = @([gCILastRestoreStats[@"keychainRestored"] unsignedIntegerValue] + restored);
            gCILastRestoreStats[@"keychainSignedRestored"] = @([gCILastRestoreStats[@"keychainSignedRestored"] unsignedIntegerValue] + signedRestored);
            gCILastRestoreStats[@"keychainSQLRestored"] = @([gCILastRestoreStats[@"keychainSQLRestored"] unsignedIntegerValue] + sqlRestored);
            gCILastRestoreStats[@"keychainFailed"] = @([gCILastRestoreStats[@"keychainFailed"] unsignedIntegerValue] + gCIKCFailed);
            gCILastRestoreStats[@"keychainSkipped"] = @([gCILastRestoreStats[@"keychainSkipped"] unsignedIntegerValue] + gCIKCSkipped);
            gCILastRestoreStats[@"kcUid"] = @(gCIKCSignedUID);
        }
        CIRunKillall(@"cfprefsd");
        [NSThread sleepForTimeInterval:0.05];
        if (!gCILastRestoreStats) {
            gCILastRestoreStats = [NSMutableDictionary dictionary];
        }
        gCILastRestoreStats[@"copiedBytes"] = @(gCICopyBytes);
        gCILastRestoreStats[@"copiedFiles"] = @(gCICopyFiles);
        gCILastRestoreStats[@"copyFailed"] = @(gCICopyFailed);
        NSString *statsPath = [dir stringByAppendingPathComponent:@"last-restore.plist"];
        [gCILastRestoreStats writeToFile:statsPath atomically:YES];
        if (gCICopyFiles == 0 && [meta[@"bytes"] unsignedLongLongValue] > 0) {
            if (error) {
                *error = CIError(3, @"Copy sandbox 0 file. Backup co data nhung copyfile that bai.");
            }
            return NO;
        }
    }
    return YES;
}

BOOL ChengIOSDeleteBackup(NSString *backupID, NSError **error) {
    NSString *dir = CIBackupDirForID(backupID);
    if (dir.length == 0) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    BOOL allowed = NO;
    for (NSString *root in CIBackupRootCandidates()) {
        if ([dir hasPrefix:root] && ![dir isEqualToString:root]) {
            allowed = YES;
            break;
        }
    }
    if (!allowed) {
        if (error) {
            *error = CIError(3, @"Backup ID khong hop le.");
        }
        return NO;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:dir error:error];
}

BOOL ChengIOSRenameBackup(NSString *backupID, NSString *name, NSError **error) {
    NSMutableDictionary *meta = [CIReadMeta(backupID) mutableCopy];
    if (!meta) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    NSString *label = CISanitizeName(name);
    if (label.length == 0) {
        if (error) {
            *error = CIError(1, @"Ten backup trong.");
        }
        return NO;
    }
    meta[@"name"] = label;
    [meta removeObjectForKey:@"path"];
    return CIWriteMeta(backupID, meta);
}

static void CITerminateRelatedBundles(NSString *bundleID) {
    CITerminateBundle(bundleID);
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if (![ws respondsToSelector:@selector(allInstalledApplications)]) {
        return;
    }
    NSString *prefix = [bundleID stringByAppendingString:@"."];
    NSArray *apps = [ws allInstalledApplications];
    for (id app in apps) {
        NSString *ident = nil;
        if ([app respondsToSelector:@selector(applicationIdentifier)]) {
            ident = [app applicationIdentifier];
        }
        if (ident.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
            ident = [app bundleIdentifier];
        }
        if (ident.length == 0 || [ident isEqualToString:bundleID]) {
            continue;
        }
        if ([ident hasPrefix:prefix]) {
            CITerminateBundle(ident);
        }
    }
    for (NSString *other in CICompanionBundleIDs(bundleID)) {
        CITerminateBundle(other);
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        CIKillSafariProcesses();
    }
}

static BOOL CINameLooksLikeLoginResidue(NSString *name, NSString *bundleID) {
    NSString *low = name.lowercaseString ?: @"";
    if (low.length == 0 || bundleID.length == 0) {
        return NO;
    }
    NSArray<NSString *> *needles = nil;
    NSString *blow = bundleID.lowercaseString;
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        needles = @[
            @"fb_dbl", @"dblaccounts", @"dbl_account", @"device_based_login",
            @"devicebasedlogin", @"saved_account", @"savedaccount", @"last_user",
            @"lastlogged", @"last_logged", @"accountstore", @"fbaccountstore",
            @"fbsaved", @"continueas", @"continue_as", @"login_account",
            @"logged_in_user", @"current_user", @"tokeninformation",
            @"fbaccesstoken", @"fbsdkaccesstoken", @"authenticationtoken",
            @"accountswitcher", @"account_switcher",
            @"family_device_id", @"machine_id", @"fb_device_id",
            @"analytics_device_id", @"anonymousid", @"anonymous_id",
            @"com.facebook.sdk.uuid", @"fbsdksettings"
        ];
    } else if ([blow containsString:@"shopee"] || [blow hasPrefix:@"com.beeasy."] || [blow hasPrefix:@"com.shopee."]) {
        needles = @[
            @"shopee_session", @"access_token", @"logged_in", @"account_info",
            @"user_session", @"auth_token", @"saved_account"
        ];
    } else if ([blow containsString:@"tiktok"] || [blow hasPrefix:@"com.zhiliaoapp."] ||
               [blow hasPrefix:@"com.ss.iphone."] || [blow containsString:@"aweme"] ||
               [blow containsString:@"musically"]) {
        needles = @[
            @"tt_token", @"ttaccount", @"passport", @"session", @"login_info",
            @"user_session", @"auth_token", @"saved_account",
            @"device_id", @"install_id", @"odin_tt", @"openudid", @"cdid",
            @"tt_device", @"krypton", @"google_aid", @"msdk_guid"
        ];
    }
    if (needles.count == 0) {
        return NO;
    }
    for (NSString *needle in needles) {
        if ([low containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static void CIWipeLoginResidueInTree(NSString *root, NSString *bundleID) {
    if (root.length == 0 || bundleID.length == 0 || !CIPathSafeToMutate(root)) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&dir]) {
        return;
    }
    if (!dir) {
        if (CINameLooksLikeLoginResidue(root.lastPathComponent, bundleID)) {
            CIRemoveDeep(root);
        }
        return;
    }
    NSMutableArray<NSString *> *kill = [NSMutableArray array];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        NSString *base = rel.lastPathComponent;
        if (CIIsReservedName(base)) {
            continue;
        }
        if (CINameLooksLikeLoginResidue(base, bundleID) || CINameLooksLikeLoginResidue(rel, bundleID)) {
            [kill addObject:[root stringByAppendingPathComponent:rel]];
        }
    }
    for (NSString *path in kill) {
        if (CIPathSafeToMutate(path)) {
            CIRemoveDeep(path);
        }
    }
}

static void CIWipeLoginResidueForBundle(NSString *bundleID, NSString *dataPath, NSDictionary<NSString *, NSString *> *groups, NSDictionary<NSString *, NSString *> *plugins) {
    if (bundleID.length == 0) {
        return;
    }
    CIWipeLoginResidueInTree(dataPath, bundleID);
    for (NSString *group in groups) {
        CIWipeLoginResidueInTree(groups[group], bundleID);
    }
    for (NSString *pluginID in plugins) {
        CIWipeLoginResidueInTree(plugins[pluginID], bundleID);
    }
    for (NSString *extra in CISupportPathsForBundle(bundleID)) {
        CIWipeLoginResidueInTree(extra, bundleID);
    }
    for (NSString *extra in CIExtraWipePaths(bundleID)) {
        CIWipeLoginResidueInTree(extra, bundleID);
    }
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        for (NSString *other in CICompanionBundleIDs(bundleID)) {
            CIWipeLoginResidueInTree(CIDataPath(other), other);
            NSDictionary *og = CIAllGroupPaths(other);
            for (NSString *group in og) {
                CIWipeLoginResidueInTree(og[group], other);
            }
        }
    }
}

static void CIResetVendorIdentifier(NSString *bundleID) {
    if (bundleID.length == 0 || geteuid() != 0) {
        return;
    }
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *ents = [proxy respondsToSelector:@selector(entitlements)] ? proxy.entitlements : nil;
    NSString *appId = [ents[@"application-identifier"] isKindOfClass:[NSString class]] ? ents[@"application-identifier"] : bundleID;
    NSString *team = CITeamIDFromAppID(appId);
    NSMutableArray<NSString *> *accounts = [NSMutableArray array];
    if (appId.length > 0) {
        [accounts addObject:appId];
    }
    if (bundleID.length > 0) {
        [accounts addObject:bundleID];
    }
    if (team.length > 0) {
        [accounts addObject:team];
        [accounts addObject:[NSString stringWithFormat:@"%@.%@", team, bundleID]];
    }
    NSArray *services = @[
        @"com.apple.deviceids",
        @"com.apple.identities",
        @"identifierForVendor",
        @"IDFV",
        @"idfv"
    ];
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword
    ];
    if (!gCIFastErase) {
        for (id cls in classes) {
            for (NSString *service in services) {
                NSDictionary *base = @{
                    (__bridge id)kSecClass: cls,
                    (__bridge id)kSecAttrService: service,
                    (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
                };
                for (NSString *acct in accounts) {
                    if (acct.length == 0) {
                        continue;
                    }
                    NSMutableDictionary *q = [base mutableCopy];
                    q[(__bridge id)kSecAttrAccount] = acct;
                    SecItemDelete((__bridge CFDictionaryRef)q);
                }
            }
        }
    }
    sqlite3 *db = CIKeychainSQLOpen(YES);
    if (!db) {
        return;
    }
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    NSArray<NSString *> *tables = CIKeychainSQLTables();
    for (NSString *table in tables) {
        NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE (svce=? OR svce=? OR svce=?) AND (acct=? OR acct=? OR agrp=?)", table];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        sqlite3_bind_text(stmt, 1, "com.apple.deviceids", -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 2, "com.apple.identities", -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, "identifierForVendor", -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 4, team.UTF8String ?: "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 5, bundleID.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 6, appId.UTF8String ?: "", -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        if (team.length > 0) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", team];
            NSString *sql2 = [NSString stringWithFormat:@"DELETE FROM %@ WHERE svce IN ('com.apple.deviceids','com.apple.identities','identifierForVendor') AND (acct LIKE ? OR agrp LIKE ?)", table];
            sqlite3_stmt *st2 = NULL;
            if (sqlite3_prepare_v2(db, sql2.UTF8String, -1, &st2, NULL) == SQLITE_OK) {
                sqlite3_bind_text(st2, 1, like.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(st2, 2, like.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_step(st2);
                sqlite3_finalize(st2);
            }
        }
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    CIKeychainSQLClose(db);
}

static void CIWipeNamedPasteboards(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString ?: @"";
    if (!([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."])) {
        return;
    }
    Class pb = NSClassFromString(@"UIPasteboard");
    SEL sel = NSSelectorFromString(@"removePasteboardWithName:");
    if (!pb || !sel || ![pb respondsToSelector:sel]) {
        return;
    }
    NSArray<NSString *> *names = @[
        @"com.appsflyer.pasteboard",
        @"com.appsflyer.uid",
        @"appsflyer",
        @"adjust",
        @"shopee",
        bundleID ?: @""
    ];
    for (NSString *name in names) {
        if (name.length == 0) {
            continue;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(pb, sel, name);
    }
}


static BOOL CIBundleIsTikTokFamily(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString ?: @"";
    return [low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
           [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] ||
           [low containsString:@"musically"] || [low containsString:@"bytedance"];
}

static BOOL CIBundleIsShopeeFamily(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString ?: @"";
    return [low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] ||
           [low hasPrefix:@"com.shopee."] || [low containsString:@"shopeepay"];
}

static NSArray<NSString *> *CIKnownShopeeBundles(void) {
    return @[
        @"com.beeasy.shopee.vn",
        @"com.shopee.vn",
        @"com.beeasy.marketplace.vn",
        @"com.shopee.SG",
        @"com.shopee.id",
        @"com.shopee.my",
        @"com.shopee.th",
        @"com.shopee.tw",
        @"com.shopee.ph",
        @"com.shopeepay.vn"
    ];
}

static void CIKillShopeeHard(void) {
    NSArray<NSString *> *names = @[
        @"Shopee", @"ShopeeApp", @"ShopeeVN", @"ShopeeLite", @"ShopeePay",
        @"SGShopping", @"Marketplace", @"beeasy", @"ShopeeWidget",
        @"ShopeeNotification", @"ShopeeShare"
    ];
    for (NSString *name in names) {
        CIRunKillall(name);
    }
    for (NSString *bid in CIKnownShopeeBundles()) {
        CITerminateBundle(bid);
    }
}


static BOOL CIBundleBlockedFromInjection(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString ?: @"";
    if (low.length == 0) {
        return YES;
    }
    if (CIBundleIsShopeeFamily(bundleID) ||
        [low containsString:@"shopee"] ||
        [low containsString:@"beeasy"] ||
        [low containsString:@"shopeepay"] ||
        [low hasPrefix:@"com.shopee."] ||
        [low hasPrefix:@"com.beeasy."]) {
        return YES;
    }
    if ([low isEqualToString:@"com.apple.uikit"] ||
        [low isEqualToString:@"com.apple.foundation"] ||
        [low hasPrefix:@"com.apple.webkit"]) {
        return YES;
    }
    return ChengIOSBundleIsProtected(bundleID) && !ChengIOSBundleIsSafari(bundleID);
}

static NSArray<NSString *> *CIDefaultInjectionBundles(void) {
    return @[
        @"com.apple.mobilesafari",
        @"com.facebook.Facebook",
        @"com.facebook.Messenger",
        @"com.ss.iphone.ugc.Aweme",
        @"com.zhiliaoapp.musically",
        @"com.zhiliaoapp.musically.go",
        @"com.finalwire.aida64",
        @"com.ksauxiliary.AIDA64"
    ];
}

static NSArray<NSString *> *CIInjectionFilterPlistPaths(void) {
    return @[
        @"/Library/MobileSubstrate/DynamicLibraries/ChengIOS.plist",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ChengIOS.plist",
        @"/usr/lib/TweakInject/ChengIOS.plist",
        @"/var/jb/usr/lib/TweakInject/ChengIOS.plist",
        @"/Library/TweakInject/ChengIOS.plist",
        @"/var/jb/Library/TweakInject/ChengIOS.plist"
    ];
}

static NSArray<NSString *> *CIBuildInjectionFilterBundles(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *bundleID) {
        NSString *use = ChengIOSCanonicalBundleID(bundleID) ?: bundleID;
        if (use.length == 0 || [seen containsObject:use] || CIBundleBlockedFromInjection(use)) {
            return;
        }
        [seen addObject:use];
        [out addObject:use];
    };
    BOOL any = NO;
    for (NSString *bundle in ChengIOSUserSelectedBundleIDs()) {
        if (CIBundleBlockedFromInjection(bundle)) {
            continue;
        }
        any = YES;
        add(bundle);
        if (ChengIOSBundleIsSafari(bundle)) {
            add(@"com.apple.mobilesafari");
        }
    }
    if (!any) {
        for (NSString *bundle in CIDefaultInjectionBundles()) {
            add(bundle);
        }
    }
    if (out.count == 0) {
        add(@"com.vinhnv2507.chengios.app");
        if (out.count == 0) {
            [out addObject:@"com.vinhnv2507.chengios.app"];
        }
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

static NSDictionary *CIWriteInjectionFilterPlist(NSArray<NSString *> *bundles, NSError **error) {
    NSArray<NSString *> *use = bundles.count ? bundles : CIBuildInjectionFilterBundles();
    NSDictionary *plist = @{
        @"Filter": @{
            @"Bundles": use
        }
    };
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *written = [NSMutableArray array];
    for (NSString *path in CIInjectionFilterPlistPaths()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            continue;
        }
        NSString *dylib = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"dylib"];
        if (![fm fileExistsAtPath:path] && ![fm fileExistsAtPath:dylib]) {
            continue;
        }
        if (![plist writeToFile:path atomically:YES]) {
            continue;
        }
        const char *raw = path.fileSystemRepresentation;
        if (raw) {
            chmod(raw, 0644);
            chown(raw, 0, 0);
        }
        [written addObject:path];
    }
    if (written.count == 0 && error) {
        *error = CIError(2, @"Khong ghi duoc ChengIOS.plist filter.");
    }
    return @{
        @"ok": @(written.count > 0),
        @"bundles": use ?: @[],
        @"written": written
    };
}

NSDictionary *ChengIOSSyncInjectionFilter(NSError **error) {
    NSArray<NSString *> *bundles = CIBuildInjectionFilterBundles();
    if (!CIIsRootProcess() && !CIInHelperProcess()) {
        NSDictionary *remote = CIRunRootOp(@{@"op": @"sync-filter"}, error);
        if ([remote isKindOfClass:[NSDictionary class]]) {
            return remote;
        }
    }
    return CIWriteInjectionFilterPlist(bundles, error);
}

void ChengIOSRequestInjectionFilterSync(void) {
    if (CIIsRootProcess() || CIInHelperProcess()) {
        ChengIOSSyncInjectionFilter(NULL);
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ChengIOSSyncInjectionFilter(NULL);
    });
}

static BOOL CIBundleIsSticky(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString ?: @"";
    if (low.length == 0) {
        return NO;
    }
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        return YES;
    }
    if (CIBundleIsShopeeFamily(bundleID)) {
        return YES;
    }
    return CIBundleIsTikTokFamily(bundleID);
}

static void CIKillTikTokHard(void) {
    NSArray<NSString *> *names = @[
        @"TikTok", @"Musical.ly", @"musical.ly", @"Musically", @"Aweme", @"trill",
        @"TikTokNotification", @"AwemeNotification", @"NotificationService",
        @"TikTokShare", @"AwemeShare", @"ShareExtension",
        @"TikTokWidget", @"AwemeWidget", @"WidgetExtension",
        @"BroadcastUpload", @"TikTokBroadcast", @"AwemeBroadcast",
        @"TikTokLive", @"LiveExtension"
    ];
    for (NSString *name in names) {
        CIRunKillall(name);
    }
}

static BOOL CIBundleLooksDirty(NSString *bundleID) {
    NSString *dataPath = CIDataPath(bundleID);
    NSArray<NSString *> *subs = @[
        @"Documents",
        @"Library/Preferences",
        @"Library/Cookies",
        @"Library/HTTPStorages",
        @"Library/Application Support",
        @"Library/Accounts"
    ];
    for (NSString *sub in subs) {
        if (dataPath.length > 0 && CITreeHasFiles([dataPath stringByAppendingPathComponent:sub])) {
            return YES;
        }
    }
    NSDictionary *plugins = CIPluginPaths(bundleID);
    for (NSString *pluginID in plugins) {
        NSString *path = plugins[pluginID];
        if (CITreeHasFiles([path stringByAppendingPathComponent:@"Documents"]) ||
            CITreeHasFiles([path stringByAppendingPathComponent:@"Library/Preferences"])) {
            return YES;
        }
    }
    NSDictionary *groups = CIAllGroupPaths(bundleID);
    for (NSString *group in groups) {
        if (!CIGroupAlwaysWipe(group, bundleID)) {
            continue;
        }
        NSString *path = groups[group];
        if (CITreeHasFiles([path stringByAppendingPathComponent:@"Documents"]) ||
            CITreeHasFiles([path stringByAppendingPathComponent:@"Library/Preferences"])) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *CIExpandBackupTargets(NSArray<NSString *> *bundleIDs) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *raw) {
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0) {
            return;
        }
        NSString *resolved = CIResolveBundleID(raw) ?: raw;
        if (resolved.length == 0 || [seen containsObject:resolved] || ChengIOSBundleIsProtected(resolved)) {
            return;
        }
        [seen addObject:resolved];
        [out addObject:resolved];
    };

    for (NSString *raw in bundleIDs) {
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0) {
            continue;
        }
        add(raw);
        // Facebook and TikTok keep part of the login/account state in a
        // companion container or extension.  Apps Manager backs up the app
        // family, not only the visible bundle.  Include only companions that
        // are actually installed so a Facebook backup does not pull in
        // unrelated Meta apps and a TikTok backup does not pull in arbitrary
        // ByteDance apps.
        NSString *resolved = CIResolveBundleID(raw) ?: raw;
        NSString *low = resolved.lowercaseString ?: @"";
        BOOL facebook = CIBundleIsFacebookFamily(resolved) && !CIBundleIsInstagramFamily(resolved) && !CIBundleIsWhatsAppFamily(resolved);
        BOOL tiktok = [low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
                      [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] ||
                      [low containsString:@"musically"] || [low containsString:@"bytedance"];
        if (facebook || tiktok) {
            for (NSString *companion in CICompanionBundleIDs(resolved)) {
                if (CIBundleHasContainer(companion)) {
                    add(companion);
                }
            }
        }
    }
    return out;
}

static NSArray<NSString *> *CIExpandEraseTargets(NSArray<NSString *> *bundleIDs) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *bid) {
        if (bid.length == 0 || [seen containsObject:bid]) {
            return;
        }
        [seen addObject:bid];
        [out addObject:bid];
    };
    BOOL wantTikTok = NO;
    BOOL wantShopee = NO;
    for (NSString *raw in bundleIDs) {
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0) {
            continue;
        }
        NSString *resolved = CIResolveBundleID(raw);
        add(resolved);
        if (CIBundleIsTikTokFamily(raw) || CIBundleIsTikTokFamily(resolved) ||
            [raw.lowercaseString hasPrefix:@"com.ss.iphone."] ||
            [raw.lowercaseString hasPrefix:@"com.zhiliaoapp."]) {
            wantTikTok = YES;
        }
        if (CIBundleIsShopeeFamily(raw) || CIBundleIsShopeeFamily(resolved) ||
            [raw.lowercaseString hasPrefix:@"com.beeasy."] ||
            [raw.lowercaseString hasPrefix:@"com.shopee."] ||
            [raw.lowercaseString containsString:@"shopee"]) {
            wantShopee = YES;
        }
        for (NSString *other in CICompanionBundleIDs(resolved)) {
            if (CIBundleHasContainer(other)) {
                add(other);
            }
        }
    }
    if (wantTikTok) {
        for (NSString *cand in @[@"com.ss.iphone.ugc.Aweme", @"com.zhiliaoapp.musically", @"com.zhiliaoapp.musically.go"]) {
            if (CIBundleHasContainer(cand)) {
                add(cand);
            }
        }
        for (NSString *root in CIDataContainerRoots()) {
            NSDictionary<NSString *, NSString *> *index = CIContainerIndexForRoot(root);
            for (NSString *ident in index) {
                if (CIBundleIsTikTokFamily(ident)) {
                    add(ident);
                }
            }
        }
    }
    if (wantShopee) {
        for (NSString *cand in CIKnownShopeeBundles()) {
            if (CIBundleHasContainer(cand)) {
                add(cand);
            }
        }
        for (NSString *root in CIDataContainerRoots()) {
            NSDictionary<NSString *, NSString *> *index = CIContainerIndexForRoot(root);
            for (NSString *ident in index) {
                if (CIBundleIsShopeeFamily(ident)) {
                    add(ident);
                }
            }
        }
    }
    return out;
}

static NSArray<NSString *> *CIEraseOrder(NSArray<NSString *> *targets) {
    NSMutableArray<NSString *> *normal = [NSMutableArray array];
    NSMutableArray<NSString *> *sticky = [NSMutableArray array];
    for (NSString *bid in targets) {
        if (CIBundleIsSticky(bid)) {
            [sticky addObject:bid];
        } else {
            [normal addObject:bid];
        }
    }
    [sticky sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL ta = CIBundleIsTikTokFamily(a);
        BOOL tb = CIBundleIsTikTokFamily(b);
        if (ta != tb) {
            return ta ? NSOrderedDescending : NSOrderedAscending;
        }
        return [a compare:b];
    }];
    [normal addObjectsFromArray:sticky];
    return normal;
}

static void CIKillEraseTargets(NSArray<NSString *> *targets) {
    BOOL killedTikTok = NO;
    BOOL killedShopee = NO;
    for (NSString *bid in targets) {
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) {
            continue;
        }
        CISettleForDisk(bid);
        NSDictionary *plugins = CIPluginPaths(bid);
        for (NSString *pluginID in plugins) {
            CITerminateBundle(pluginID);
        }
        if (CIBundleIsTikTokFamily(bid) && !killedTikTok) {
            CIKillTikTokHard();
            killedTikTok = YES;
        }
        if (CIBundleIsShopeeFamily(bid) && !killedShopee) {
            CIKillShopeeHard();
            killedShopee = YES;
        }
    }
}
static BOOL CIEraseOne(NSString *bundleID, NSArray<NSString *> *together) {
    bundleID = CIResolveBundleID(bundleID);
    if (ChengIOSBundleIsProtected(bundleID)) {
        return NO;
    }
    CISettleForDisk(bundleID);
    NSDictionary *pluginsEarly = CIPluginPaths(bundleID);
    for (NSString *pluginID in pluginsEarly) {
        CITerminateBundle(pluginID);
    }
    BOOL ok = NO;
    NSString *dataPath = CIDataPath(bundleID);
    if (dataPath.length > 0) {
        ok = CIEmptyContainer(dataPath) || ok;
        if (!ok) {
            CISettleForDisk(bundleID);
            ok = CIEmptyContainer(dataPath) || ok;
        }
    }

    NSString *eraseLow = bundleID.lowercaseString;
    BOOL wipeFamily = [eraseLow hasPrefix:@"com.facebook."] || [eraseLow hasPrefix:@"com.meta."] ||
                      [eraseLow containsString:@"shopee"] || [eraseLow hasPrefix:@"com.beeasy."] ||
                      [eraseLow hasPrefix:@"com.zhiliaoapp."] || [eraseLow containsString:@"tiktok"] ||
                      [eraseLow hasPrefix:@"com.ss.iphone."] || [eraseLow containsString:@"aweme"];
    if (wipeFamily) {
        for (NSString *other in CICompanionBundleIDs(bundleID)) {
            if ([together containsObject:other] || ChengIOSBundleIsProtected(other)) {
                continue;
            }
            if (!CIBundleHasContainer(other)) {
                continue;
            }
            CITerminateBundle(other);
            NSString *companionData = CIDataPath(other);
            if (companionData.length > 0) {
                ok = CIEmptyContainer(companionData) || ok;
            }
        }
    }

    NSDictionary *owned = CIGroupPaths(bundleID);
    NSMutableDictionary<NSString *, NSString *> *groups = [NSMutableDictionary dictionary];
    [groups addEntriesFromDictionary:CIAllGroupPaths(bundleID)];
    for (NSString *group in groups) {
        if (!CIGroupAlwaysWipe(group, bundleID) && !owned[group] && CIGroupUsedByOtherApps(group, bundleID, together)) {
            continue;
        }
        ok = CIEmptyContainer(groups[group]) || ok;
        for (NSString *root in @[
            @"/var/mobile/Library/Preferences",
            @"/private/var/mobile/Library/Preferences"
        ]) {
            NSString *plist = [root stringByAppendingPathComponent:[group stringByAppendingString:@".plist"]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:plist] && CIPathSafeToMutate(plist)) {
                [[NSFileManager defaultManager] removeItemAtPath:plist error:nil];
            }
        }
    }
    for (NSString *extra in CIExtraWipePaths(bundleID)) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:extra] && CIPathSafeToMutate(extra)) {
            ok = CIWipeContents(extra) || ok;
        }
    }
    for (NSString *extra in CISupportPathsForBundle(bundleID)) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:extra] && CIPathSafeToMutate(extra)) {
            ok = CIWipeContents(extra) || ok;
        }
    }
    NSDictionary *plugins = CIPluginPaths(bundleID);
    for (NSString *pluginID in plugins) {
        ok = CIEmptyContainer(plugins[pluginID]) || ok;
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        CIKillSafariProcesses();
        for (NSString *path in CISafariLibraryPaths()) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path] && CIPathSafeToMutate(path)) {
                BOOL dir = NO;
                [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir];
                if (dir) {
                    ok = CIWipeContents(path) || ok;
                } else {
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                    ok = YES;
                }
            }
        }
    }
    CIKeychainSQLWipeForBundle(bundleID);
    CIWipeAccountsForBundle(bundleID);
    CIResetVendorIdentifier(bundleID);
    CIWipeNamedPasteboards(bundleID);
    if (wipeFamily) {
        for (NSString *other in CICompanionBundleIDs(bundleID)) {
            if ([together containsObject:other] || !CIBundleHasContainer(other)) {
                continue;
            }
            CIKeychainSQLWipeForBundle(other);
            CIWipeAccountsForBundle(other);
            CIResetVendorIdentifier(other);
        }
        if (ok) {
            CIWipeLoginResidueInTree(dataPath, bundleID);
            for (NSString *group in groups) {
                CIWipeLoginResidueInTree(groups[group], bundleID);
            }
            for (NSString *pluginID in plugins) {
                CIWipeLoginResidueInTree(plugins[pluginID], bundleID);
            }
        }
        if ((CIBundleIsTikTokFamily(bundleID) || CIBundleIsShopeeFamily(bundleID)) && CIBundleLooksDirty(bundleID)) {
            if (CIBundleIsTikTokFamily(bundleID)) {
                CIKillTikTokHard();
            } else {
                CIKillShopeeHard();
            }
            CISettleForDisk(bundleID);
            if (dataPath.length > 0) {
                ok = CIEmptyContainer(dataPath) || ok;
            }
            for (NSString *group in groups) {
                if (!CIGroupAlwaysWipe(group, bundleID) && !owned[group] && CIGroupUsedByOtherApps(group, bundleID, together)) {
                    continue;
                }
                ok = CIEmptyContainer(groups[group]) || ok;
            }
            for (NSString *pluginID in plugins) {
                ok = CIEmptyContainer(plugins[pluginID]) || ok;
            }
            CIKeychainSQLWipeForBundle(bundleID);
            if (dataPath.length > 0) {
                CIReemptyPrefs(dataPath);
            }
        }
    }
    CISettleAfterDisk(bundleID);
    if (CIBundleIsTikTokFamily(bundleID)) {
        CIKillTikTokHard();
        CISettleForDisk(bundleID);
    }
    if (CIBundleIsShopeeFamily(bundleID)) {
        CIKillShopeeHard();
        CISettleForDisk(bundleID);
    }
    return ok;
}

NSDictionary *ChengIOSEraseBundles(NSArray<NSString *> *bundleIDs, NSError **error) {
    NSArray<NSString *> *requested = CIExpandEraseTargets(bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs());
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(4, @"chengiosroot uid != 0");
            }
            return @{@"ok": @[], @"failed": requested.count ? requested : (bundleIDs ?: @[]), @"skipped": @[], @"error": @"uid"};
        }
        NSDictionary *remote = CIRunRootOp(@{
            @"op": @"erase",
            @"bundles": requested.count ? requested : (bundleIDs ?: @[])
        }, error);
        if (remote) {
            NSDictionary *result = remote[@"result"];
            if ([result isKindOfClass:[NSDictionary class]]) {
                NSString *remoteErr = nil;
                if ([remote[@"error"] isKindOfClass:[NSString class]]) {
                    remoteErr = remote[@"error"];
                }
                if (remoteErr.length == 0 && [result[@"error"] isKindOfClass:[NSString class]]) {
                    remoteErr = result[@"error"];
                }
                NSArray *okItems = [result[@"ok"] isKindOfClass:[NSArray class]] ? result[@"ok"] : nil;
                if (error && !*error && remoteErr.length > 0 && okItems.count == 0) {
                    *error = CIError(4, remoteErr);
                }
                return result;
            }
            if (error && !*error) {
                *error = CIError(4, remote[@"error"] ?: @"Erase root helper loi.");
            }
            return @{
                @"ok": @[],
                @"failed": bundleIDs ?: @[],
                @"skipped": @[],
                @"error": remote[@"error"] ?: @"helper"
            };
        }
    }
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];
    NSArray<NSString *> *targets = CIEraseOrder(requested.count ? requested : CIExpandEraseTargets(bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs()));
    if (targets.count == 0) {
        NSString *msg = (bundleIDs.count > 0)
            ? [NSString stringWithFormat:@"Khong resolve duoc container cho: %@. Tick lai TikTok trong Change Apps (bundle that: com.ss.iphone.ugc.Aweme / com.zhiliaoapp.musically).", [bundleIDs componentsJoinedByString:@", "]]
            : @"Chua tick app trong Change Apps. Mo Change Apps, tick TikTok/Facebook/Shopee/Safari roi bam lai.";
        if (error) {
            *error = CIError(5, msg);
        }
        return @{@"ok": ok, @"failed": failed, @"skipped": skipped, @"error": msg};
    }
    CIContainerIndexClear();
    gCIFastErase = YES;
    CIKillEraseTargets(targets);
    CIRunKillall(@"cfprefsd");
    CIRunKillall(@"securityd");
    CIRunKillall(@"secd");
    for (NSString *bundleID in targets) {
        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
            continue;
        }
        if (ChengIOSBundleIsProtected(bundleID)) {
            [skipped addObject:bundleID];
            continue;
        }
        if (CIEraseOne(bundleID, targets)) {
            [ok addObject:bundleID];
        } else {
            [failed addObject:bundleID];
        }
    }
    CIContainerIndexClear();
    CIKillEraseTargets(targets);
    CIKeychainSQLSettle();
    for (NSString *bundleID in targets) {
        if (!CIBundleIsSticky(bundleID) || ChengIOSBundleIsProtected(bundleID)) {
            continue;
        }
        if ([ok containsObject:bundleID] && !CIBundleLooksDirty(bundleID)) {
            continue;
        }
        if (CIEraseOne(bundleID, targets)) {
            if (![ok containsObject:bundleID]) {
                [ok addObject:bundleID];
            }
            [failed removeObject:bundleID];
        } else if (![ok containsObject:bundleID] && ![failed containsObject:bundleID]) {
            [failed addObject:bundleID];
        }
    }
    CIKillEraseTargets(targets);
    CIRunKillall(@"cfprefsd");
    CIRunKillall(@"securityd");
    CIRunKillall(@"secd");
    CIContainerIndexClear();
    gCIFastErase = NO;
    return @{@"ok": ok, @"failed": failed, @"skipped": skipped};
}

NSArray<NSString *> *ChengIOSInstalledUserBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if (![ws respondsToSelector:@selector(allInstalledApplications)]) {
        return out;
    }
    for (id app in [ws allInstalledApplications]) {
        NSString *ident = nil;
        if ([app respondsToSelector:@selector(applicationIdentifier)]) {
            ident = [app applicationIdentifier];
        }
        if (ident.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
            ident = [app bundleIdentifier];
        }
        if (ident.length == 0 || [seen containsObject:ident]) {
            continue;
        }
        if (ChengIOSBundleIsProtected(ident)) {
            continue;
        }
        NSString *type = nil;
        if ([app respondsToSelector:@selector(applicationType)]) {
            type = [app applicationType];
        }
        NSString *path = nil;
        if ([app respondsToSelector:@selector(bundleURL)]) {
            path = [[app bundleURL] path];
        }
        BOOL user = [type caseInsensitiveCompare:@"User"] == NSOrderedSame;
        if (!user && [path containsString:@"/Containers/Bundle/Application/"]) {
            user = YES;
        }
        if (!user) {
            continue;
        }
        [seen addObject:ident];
        [out addObject:ident];
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

NSDictionary *ChengIOSEraseSafari(NSError **error) {
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(4, @"chengiosroot uid != 0");
            }
            return @{@"ok": @[], @"failed": @[@"com.apple.mobilesafari"], @"skipped": @[], @"error": @"uid"};
        }
        NSDictionary *remote = CIRunRootOp(@{@"op": @"erase-safari"}, error);
        if (remote) {
            NSDictionary *result = remote[@"result"];
            if ([result isKindOfClass:[NSDictionary class]]) {
                return result;
            }
            if (error && !*error) {
                *error = CIError(4, remote[@"error"] ?: @"Erase safari helper loi.");
            }
            return @{
                @"ok": @[],
                @"failed": @[@"com.apple.mobilesafari"],
                @"skipped": @[],
                @"error": remote[@"error"] ?: @"helper"
            };
        }
    }
    (void)error;
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    NSArray<NSString *> *targets = @[@"com.apple.mobilesafari", @"com.apple.SafariViewService"];
    gCIFastErase = YES;
    for (NSString *bundleID in targets) {
        if (CIEraseOne(bundleID, targets)) {
            [ok addObject:bundleID];
        } else if (ChengIOSBundleIsSafari(bundleID)) {
            CIKillSafariProcesses();
            BOOL any = NO;
            for (NSString *path in CISafariLibraryPaths()) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:path] || !CIPathSafeToMutate(path)) {
                    continue;
                }
                BOOL dir = NO;
                [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir];
                if (dir) {
                    any = CIWipeContents(path) || any;
                } else {
                    any = [[NSFileManager defaultManager] removeItemAtPath:path error:nil] || any;
                }
            }
            if (any) {
                [ok addObject:bundleID];
            } else {
                [failed addObject:bundleID];
            }
        } else {
            [failed addObject:bundleID];
        }
    }
    gCIFastErase = NO;
    return @{@"ok": ok, @"failed": failed, @"skipped": @[]};
}

NSDictionary *ChengIOSEraseDeviceApps(BOOL includeSafari, NSError **error) {
    NSMutableArray<NSString *> *targets = [ChengIOSInstalledUserBundleIDs() mutableCopy];
    if (includeSafari) {
        for (NSString *safari in @[@"com.apple.mobilesafari", @"com.apple.SafariViewService"]) {
            if (![targets containsObject:safari]) {
                [targets addObject:safari];
            }
        }
    }
    NSDictionary *result = ChengIOSEraseBundles(targets, error);
    if (includeSafari) {
        NSDictionary *safari = ChengIOSEraseSafari(error);
        NSMutableArray *ok = [result[@"ok"] mutableCopy] ?: [NSMutableArray array];
        NSMutableArray *failed = [result[@"failed"] mutableCopy] ?: [NSMutableArray array];
        for (NSString *item in safari[@"ok"]) {
            if (![ok containsObject:item]) {
                [ok addObject:item];
            }
        }
        for (NSString *item in safari[@"failed"]) {
            if (![failed containsObject:item] && ![ok containsObject:item]) {
                [failed addObject:item];
            }
        }
        return @{@"ok": ok, @"failed": failed, @"skipped": result[@"skipped"] ?: @[]};
    }
    return result;
}

NSDictionary *ChengIOSEraseThenRandom(NSArray<NSString *> *bundleIDs, BOOL allDevice, BOOL randomAll, NSString *region, NSError **error) {
    NSArray<NSString *> *targets = nil;
    NSDictionary *erase = nil;
    if (allDevice) {
        erase = ChengIOSEraseDeviceApps(YES, error);
        NSMutableArray<NSString *> *mix = [NSMutableArray array];
        for (NSString *bid in (erase[@"ok"] ?: @[])) {
            [mix addObject:bid];
        }
        for (NSString *bid in (erase[@"failed"] ?: @[])) {
            if (![mix containsObject:bid]) {
                [mix addObject:bid];
            }
        }
        targets = CIExpandEraseTargets(mix.count ? mix : ChengIOSInstalledUserBundleIDs());
    } else {
        targets = CIExpandEraseTargets(bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs());
        erase = ChengIOSEraseBundles(targets, error);
    }
    CIKillEraseTargets(targets);
    NSDictionary *profile = nil;
    if (region.length > 0) {
        profile = ChengIOSRandomFullProfileInRegion(region);
    } else if (randomAll) {
        profile = ChengIOSRandomFullProfile();
    } else {
        profile = ChengIOSRandomIdentity();
    }
    if (profile.count > 0) {
        ChengIOSApplyProfile(profile);
    }
    CIKillEraseTargets(targets);
    NSMutableArray<NSString *> *rewipe = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^addRewipe)(NSString *) = ^(NSString *bid) {
        if (bid.length == 0 || [seen containsObject:bid] || ChengIOSBundleIsProtected(bid)) {
            return;
        }
        if (CIBundleIsTikTokFamily(bid) || CIBundleIsShopeeFamily(bid)) {
            [seen addObject:bid];
            [rewipe addObject:bid];
        }
    };
    for (NSString *bid in targets) {
        addRewipe(bid);
    }
    for (NSString *bid in (erase[@"ok"] ?: @[])) {
        addRewipe(bid);
    }
    NSMutableArray *ok = [erase[@"ok"] mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *failed = [erase[@"failed"] mutableCopy] ?: [NSMutableArray array];
    NSArray *skipped = erase[@"skipped"] ?: @[];
    if (rewipe.count > 0) {
        NSDictionary *again = ChengIOSEraseBundles(rewipe, error);
        for (NSString *bid in again[@"ok"] ?: @[]) {
            if (![ok containsObject:bid]) {
                [ok addObject:bid];
            }
            [failed removeObject:bid];
        }
        for (NSString *bid in again[@"failed"] ?: @[]) {
            if (![ok containsObject:bid] && ![failed containsObject:bid]) {
                [failed addObject:bid];
            }
        }
        CIKillEraseTargets(rewipe);
    }
    return @{
        @"ok": ok,
        @"failed": failed,
        @"skipped": skipped,
        @"profileSummary": ChengIOSProfileSummary(profile) ?: @""
    };
}

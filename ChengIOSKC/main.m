#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>


typedef CFDataRef (*CISecACCCopyFn)(SecAccessControlRef);
typedef SecAccessControlRef (*CISecACCCreateFn)(CFAllocatorRef, CFDataRef, CFErrorRef *);

static CISecACCCopyFn gCISecACCCopy = NULL;
static CISecACCCreateFn gCISecACCCreate = NULL;

static void CIKCLoadSPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (handle) {
            gCISecACCCopy = (CISecACCCopyFn)dlsym(handle, "SecAccessControlCopyData");
            gCISecACCCreate = (CISecACCCreateFn)dlsym(handle, "SecAccessControlCreateFromData");
        }
    });
}

static NSArray *CIKCClasses(void) {
    return @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity
    ];
}

static NSString *CIKCClassName(id cls) {
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

static id CIKCClassFromName(NSString *name) {
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

static id CIKCPlistSafe(id value) {
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        if (data.length == 0) {
            return nil;
        }
        return [data base64EncodedStringWithOptions:0];
    }
    return nil;
}

static NSString *CIKCB64(id value) {
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        if (data.length == 0) {
            return nil;
        }
        return [data base64EncodedStringWithOptions:0];
    }
    return nil;
}

static NSData *CIKCData(id value) {
    if ([value isKindOfClass:[NSData class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = value;
        if (text.length == 0) {
            return nil;
        }
        return [[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters];
    }
    return nil;
}

static NSDictionary *CIKCRowFromItem(id cls, NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"class"] = CIKCClassName(cls);
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
        id value = CIKCPlistSafe(item[secKey]);
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
    NSString *data64 = CIKCB64(item[(__bridge id)kSecValueData]);
    if (data64.length > 0) {
        row[@"data"] = data64;
    }
    NSString *generic64 = CIKCB64(item[(__bridge id)kSecAttrGeneric]);
    if (generic64.length > 0) {
        row[@"generic"] = generic64;
    }
    NSString *tag64 = CIKCB64(item[(__bridge id)kSecAttrApplicationTag]);
    if (tag64.length > 0) {
        row[@"applicationTag"] = tag64;
    }
    NSString *albl = CIKCB64(item[(__bridge id)kSecAttrApplicationLabel]);
    if (albl.length > 0) {
        row[@"applicationLabel"] = albl;
    }
    id keyClass = CIKCPlistSafe(item[(__bridge id)kSecAttrKeyClass]);
    if (keyClass) {
        row[@"keyClass"] = keyClass;
    }
    id keyType = CIKCPlistSafe(item[(__bridge id)kSecAttrKeyType]);
    if (keyType) {
        row[@"keyType"] = keyType;
    }
    id keySize = item[(__bridge id)kSecAttrKeySizeInBits];
    if ([keySize isKindOfClass:[NSNumber class]]) {
        row[@"keySize"] = keySize;
    }
    id permanent = item[(__bridge id)kSecAttrIsPermanent];
    if ([permanent isKindOfClass:[NSNumber class]]) {
        row[@"permanent"] = permanent;
    }
    id token = CIKCPlistSafe(item[(__bridge id)kSecAttrTokenID]);
    if (token) {
        row[@"tokenID"] = token;
    }
    id accc = item[(__bridge id)kSecAttrAccessControl];
    if (accc && gCISecACCCopy) {
        CFDataRef raw = gCISecACCCopy((__bridge SecAccessControlRef)accc);
        if (raw) {
            NSString *acc64 = CIKCB64((__bridge NSData *)raw);
            if (acc64.length > 0) {
                row[@"accc"] = acc64;
            }
            CFRelease(raw);
        }
    }
    return row;
}

static NSString *CIKCRowSig(NSDictionary *row) {
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
            row[@"class"] ?: @"",
            row[@"accessGroup"] ?: @"",
            row[@"service"] ?: @"",
            row[@"account"] ?: @"",
            row[@"label"] ?: @"",
            row[@"server"] ?: @"",
            row[@"applicationTag"] ?: @""];
}

static void CIKCAddUnique(NSMutableArray<NSDictionary *> *out, NSMutableSet<NSString *> *seen, NSDictionary *row) {
    if (![row isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString *sig = CIKCRowSig(row);
    if ([seen containsObject:sig]) {
        for (NSUInteger i = 0; i < out.count; i++) {
            if ([CIKCRowSig(out[i]) isEqualToString:sig]) {
                BOOL newData = [row[@"data"] isKindOfClass:[NSString class]] && [row[@"data"] length] > 0;
                BOOL oldData = [out[i][@"data"] isKindOfClass:[NSString class]] && [out[i][@"data"] length] > 0;
                if (newData && !oldData) {
                    out[i] = row;
                }
                return;
            }
        }
        return;
    }
    [seen addObject:sig];
    [out addObject:row];
}

static void CIKCApplyAuthUI(NSMutableDictionary *query) {
    query[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUISkip;
}

static NSMutableDictionary *CIKCBaseQuery(id cls, BOOL withData) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: cls,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @(withData),
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    } mutableCopy];
    CIKCApplyAuthUI(query);
    return query;
}

static NSArray *CIKCCopy(id cls, NSDictionary *extra, BOOL withData) {
    NSMutableDictionary *query = CIKCBaseQuery(cls, withData);
    if ([extra isKindOfClass:[NSDictionary class]]) {
        [query addEntriesFromDictionary:extra];
    }
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
    if ((status != errSecSuccess || !result) && withData) {
        if (result) {
            CFRelease(result);
        }
        return CIKCCopy(cls, extra, NO);
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

static BOOL CIKCSkipApple(NSString *agrp);

static NSDictionary *CIKCFillData(id cls, NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) {
        return item;
    }
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: cls,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    } mutableCopy];
    CIKCApplyAuthUI(query);
    NSArray *keys = @[
        (__bridge id)kSecAttrAccessGroup,
        (__bridge id)kSecAttrAccount,
        (__bridge id)kSecAttrService,
        (__bridge id)kSecAttrLabel,
        (__bridge id)kSecAttrServer,
        (__bridge id)kSecAttrProtocol,
        (__bridge id)kSecAttrPath,
        (__bridge id)kSecAttrApplicationTag
    ];
    for (id key in keys) {
        id value = item[key];
        if (value) {
            query[key] = value;
        }
    }
    id sync = item[(__bridge id)kSecAttrSynchronizable];
    if ([sync isKindOfClass:[NSNumber class]]) {
        query[(__bridge id)kSecAttrSynchronizable] = sync;
    }
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
        return item;
    }
    NSDictionary *full = CFBridgingRelease(result);
    return [full isKindOfClass:[NSDictionary class]] ? full : item;
}

static NSArray *CIKCDump(NSArray<NSString *> *agrps) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    NSMutableSet<NSString *> *seenGrp = [NSMutableSet set];
    NSMutableSet<NSString *> *allowedGrp = [NSMutableSet set];
    for (NSString *agrp in agrps) {
        if (![agrp isKindOfClass:[NSString class]] || agrp.length == 0 || [agrp isEqualToString:@"*"] || [seenGrp containsObject:agrp]) {
            continue;
        }
        [seenGrp addObject:agrp];
        [allowedGrp addObject:agrp.lowercaseString];
        [groups addObject:agrp];
    }
    for (id cls in CIKCClasses()) {
        NSMutableArray<NSDictionary *> *attrs = [NSMutableArray array];
        void (^collect)(NSDictionary *) = ^(NSDictionary *extra) {
            for (NSDictionary *item in CIKCCopy(cls, extra, NO)) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    [attrs addObject:item];
                }
            }
        };
        if (groups.count == 0) {
            collect(nil);
        } else {
            for (NSString *agrp in groups) {
                collect(@{(__bridge id)kSecAttrAccessGroup: agrp});
            }
            collect(nil);
        }
        for (NSDictionary *item in attrs) {
            NSString *agrp = item[(__bridge id)kSecAttrAccessGroup];
            if (CIKCSkipApple(agrp)) {
                continue;
            }
            // collect(nil) is kept as an iOS compatibility fallback, but do
            // not serialize another app's keychain into this app backup.
            if (allowedGrp.count > 0 && (![agrp isKindOfClass:[NSString class]] || ![allowedGrp containsObject:agrp.lowercaseString])) {
                continue;
            }
            NSDictionary *full = CIKCFillData(cls, item);
            CIKCAddUnique(out, seen, CIKCRowFromItem(cls, full ?: item));
        }
    }
    return out;
}

static BOOL CIKCSkipApple(NSString *agrp) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (![low hasPrefix:@"com.apple."]) {
        return NO;
    }
    if ([low containsString:@"safari"] || [low containsString:@"webkit"] || [low containsString:@"mobilesafari"]) {
        return NO;
    }
    return YES;
}

static NSUInteger CIKCWipe(NSArray<NSString *> *agrps) {
    NSUInteger n = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *agrp in agrps) {
        if (![agrp isKindOfClass:[NSString class]] || agrp.length == 0 || [agrp isEqualToString:@"*"] || [seen containsObject:agrp]) {
            continue;
        }
        if (CIKCSkipApple(agrp)) {
            continue;
        }
        [seen addObject:agrp];
        for (id cls in CIKCClasses()) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: cls,
                (__bridge id)kSecAttrAccessGroup: agrp,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            };
            OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
            if (status == errSecSuccess) {
                n += 1;
            }
            NSMutableDictionary *plain = [query mutableCopy];
            [plain removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
            status = SecItemDelete((__bridge CFDictionaryRef)plain);
            if (status == errSecSuccess) {
                n += 1;
            }
        }
    }
    return n;
}

static NSMutableDictionary *CIKCAddDict(NSDictionary *row) {
    NSMutableDictionary *add = [NSMutableDictionary dictionary];
    add[(__bridge id)kSecClass] = CIKCClassFromName(row[@"class"]);
    NSDictionary *map = @{
        @"service": (__bridge id)kSecAttrService,
        @"account": (__bridge id)kSecAttrAccount,
        @"accessGroup": (__bridge id)kSecAttrAccessGroup,
        @"label": (__bridge id)kSecAttrLabel,
        @"server": (__bridge id)kSecAttrServer,
        @"protocol": (__bridge id)kSecAttrProtocol,
        @"path": (__bridge id)kSecAttrPath
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
    NSData *data = CIKCData(row[@"data"]);
    if (data.length > 0) {
        add[(__bridge id)kSecValueData] = data;
    }
    NSData *generic = CIKCData(row[@"generic"]);
    if (generic.length > 0) {
        add[(__bridge id)kSecAttrGeneric] = generic;
    }
    NSData *tag = CIKCData(row[@"applicationTag"]);
    if (tag.length > 0) {
        add[(__bridge id)kSecAttrApplicationTag] = tag;
    }
    NSData *albl = CIKCData(row[@"applicationLabel"]);
    if (albl.length > 0) {
        add[(__bridge id)kSecAttrApplicationLabel] = albl;
    }
    if ([row[@"keyClass"] isKindOfClass:[NSString class]] || [row[@"keyClass"] isKindOfClass:[NSNumber class]]) {
        add[(__bridge id)kSecAttrKeyClass] = row[@"keyClass"];
    }
    if ([row[@"keyType"] isKindOfClass:[NSString class]] || [row[@"keyType"] isKindOfClass:[NSNumber class]]) {
        add[(__bridge id)kSecAttrKeyType] = row[@"keyType"];
    }
    if ([row[@"keySize"] isKindOfClass:[NSNumber class]]) {
        add[(__bridge id)kSecAttrKeySizeInBits] = row[@"keySize"];
    }
    if ([row[@"permanent"] isKindOfClass:[NSNumber class]]) {
        add[(__bridge id)kSecAttrIsPermanent] = row[@"permanent"];
    }
    NSString *acc64 = row[@"accc"];
    BOOL usedACL = NO;
    if ([acc64 isKindOfClass:[NSString class]] && acc64.length > 0 && gCISecACCCreate) {
        NSData *acc = CIKCData(acc64);
        if (acc.length > 0) {
            CFErrorRef err = NULL;
            SecAccessControlRef accc = gCISecACCCreate(kCFAllocatorDefault, (__bridge CFDataRef)acc, &err);
            if (err) {
                CFRelease(err);
            }
            if (accc) {
                add[(__bridge id)kSecAttrAccessControl] = (__bridge id)accc;
                usedACL = YES;
            }
        }
    }
    if (!usedACL) {
        id accessible = row[@"accessible"];
        if ([accessible isKindOfClass:[NSString class]] && [accessible length] > 0) {
            add[(__bridge id)kSecAttrAccessible] = accessible;
        } else {
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        }
    }
    return add;
}

static NSUInteger gCIKCSkipped = 0;
static NSUInteger gCIKCFailed = 0;

static OSStatus CIKCTryAdd(NSMutableDictionary *add, NSMutableDictionary *del) {
    SecItemDelete((__bridge CFDictionaryRef)del);
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status == errSecDuplicateItem) {
        SecItemDelete((__bridge CFDictionaryRef)del);
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    return status;
}

static NSUInteger CIKCRestore(NSArray *rows) {
    NSUInteger added = 0;
    gCIKCSkipped = 0;
    gCIKCFailed = 0;
    if (![rows isKindOfClass:[NSArray class]]) {
        return 0;
    }
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *agrp = row[@"accessGroup"];
        if (CIKCSkipApple(agrp)) {
            continue;
        }
        NSString *data64 = row[@"data"];
        BOOL hasData = [data64 isKindOfClass:[NSString class]] && data64.length > 0;
        if (!hasData) {
            gCIKCSkipped += 1;
            continue;
        }
        NSString *token = [row[@"tokenID"] isKindOfClass:[NSString class]] ? row[@"tokenID"] : @"";
        if ([token.lowercaseString containsString:@"setoken"] || [token.lowercaseString containsString:@"secureenclave"]) {
            gCIKCSkipped += 1;
            continue;
        }
        NSMutableDictionary *add = CIKCAddDict(row);
        NSMutableDictionary *del = [add mutableCopy];
        [del removeObjectForKey:(__bridge id)kSecValueData];
        [del removeObjectForKey:(__bridge id)kSecAttrAccessible];
        [del removeObjectForKey:(__bridge id)kSecAttrAccessControl];
        [del removeObjectForKey:(__bridge id)kSecAttrGeneric];
        [del removeObjectForKey:(__bridge id)kSecAttrApplicationTag];
        [del removeObjectForKey:(__bridge id)kSecAttrApplicationLabel];
        [del removeObjectForKey:(__bridge id)kSecAttrKeyClass];
        [del removeObjectForKey:(__bridge id)kSecAttrKeyType];
        [del removeObjectForKey:(__bridge id)kSecAttrKeySizeInBits];
        [del removeObjectForKey:(__bridge id)kSecAttrIsPermanent];
        del[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        OSStatus status = CIKCTryAdd(add, del);
        if (status != errSecSuccess && add[(__bridge id)kSecAttrAccessControl]) {
            [add removeObjectForKey:(__bridge id)kSecAttrAccessControl];
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
            status = CIKCTryAdd(add, del);
        }
        if (status != errSecSuccess) {
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
            [add removeObjectForKey:(__bridge id)kSecAttrAccessControl];
            status = CIKCTryAdd(add, del);
        }
        if (status == errSecSuccess) {
            added += 1;
        } else {
            gCIKCFailed += 1;
        }
    }
    return added;
}

static NSDictionary *CIKCRead(NSString *path) {
    NSDictionary *job = [NSDictionary dictionaryWithContentsOfFile:path];
    return [job isKindOfClass:[NSDictionary class]] ? job : @{};
}

static int CIKCWrite(NSString *path, NSDictionary *out) {
    if (![out writeToFile:path atomically:YES]) {
        return 3;
    }
    chmod(path.fileSystemRepresentation, 0666);
    return [out[@"ok"] boolValue] ? 0 : 1;
}

static void CIKCDropMobile(void) {
    struct passwd *pw = getpwnam("mobile");
    uid_t uid = pw ? pw->pw_uid : (uid_t)501;
    gid_t gid = pw ? pw->pw_gid : (gid_t)501;
    if (pw && pw->pw_name) {
        initgroups(pw->pw_name, gid);
    }
    setgid(gid);
    setuid(uid);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CIKCLoadSPI();
        CIKCDropMobile();
        if (argc < 4) {
            fprintf(stderr, "usage: chengioskc <dump|restore|wipe> <in.plist> <out.plist>\n");
            return 2;
        }
        NSString *op = [NSString stringWithUTF8String:argv[1]];
        NSString *inPath = [NSString stringWithUTF8String:argv[2]];
        NSString *outPath = [NSString stringWithUTF8String:argv[3]];
        NSDictionary *job = CIKCRead(inPath);
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"ok"] = @NO;
        out[@"uid"] = @(geteuid());
        out[@"op"] = op ?: @"";
        NSArray *agrps = [job[@"agrps"] isKindOfClass:[NSArray class]] ? job[@"agrps"] : @[];
        out[@"agrpCount"] = @(agrps.count);
        if ([op isEqualToString:@"dump"]) {
            NSArray *items = CIKCDump(agrps);
            NSUInteger withData = 0;
            for (NSDictionary *row in items) {
                if ([row isKindOfClass:[NSDictionary class]] && [row[@"data"] isKindOfClass:[NSString class]] && [row[@"data"] length] > 0) {
                    withData += 1;
                }
            }
            out[@"items"] = items ?: @[];
            out[@"count"] = @(items.count);
            out[@"withData"] = @(withData);
            out[@"ok"] = @YES;
        } else if ([op isEqualToString:@"restore"]) {
            NSArray *items = [job[@"items"] isKindOfClass:[NSArray class]] ? job[@"items"] : @[];
            NSUInteger n = CIKCRestore(items);
            out[@"count"] = @(n);
            out[@"skipped"] = @(gCIKCSkipped);
            out[@"failed"] = @(gCIKCFailed);
            out[@"ok"] = @YES;
        } else if ([op isEqualToString:@"wipe"]) {
            NSUInteger n = CIKCWipe(agrps);
            out[@"count"] = @(n);
            out[@"ok"] = @YES;
        } else {
            out[@"error"] = @"bad op";
        }
        return CIKCWrite(outPath, out);
    }
}

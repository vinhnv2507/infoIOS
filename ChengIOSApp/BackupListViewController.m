#import "BackupListViewController.h"
#import "../ChengIOSPrefs/ChengIOSBackup.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

@interface BackupListViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@property (nonatomic, strong) UIAlertController *busyAlert;
@end

static void CIPresent(UIViewController *host, NSString *title, NSString *message);

@interface ChengIOSAppPickController : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *bundles;
@property (nonatomic, strong) NSMutableIndexSet *picked;
@property (nonatomic, copy) NSString *doneTitle;
@property (nonatomic, copy) void (^onDone)(NSArray<NSString *> *bundles);
- (instancetype)initWithBundles:(NSArray<NSString *> *)bundles title:(NSString *)title doneTitle:(NSString *)doneTitle;
@end

@implementation ChengIOSAppPickController

- (instancetype)initWithBundles:(NSArray<NSString *> *)bundles title:(NSString *)title doneTitle:(NSString *)doneTitle {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _bundles = [bundles copy] ?: @[];
        _picked = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _bundles.count)];
        _doneTitle = doneTitle.length ? [doneTitle copy] : @"OK";
        self.title = title.length ? title : @"Chon app";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Huy"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(cancelPick)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.doneTitle
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(confirmPick)];
}

- (void)cancelPick {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray<NSString *> *)pickedBundles {
    NSMutableArray *out = [NSMutableArray array];
    [self.picked enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop;
        if (idx < self.bundles.count) {
            [out addObject:self.bundles[idx]];
        }
    }];
    return out;
}

- (void)confirmPick {
    NSArray *picked = [self pickedBundles];
    if (picked.count == 0) {
        CIPresent(self, @"Chua tick app", @"Tick 1, 2, 3 app hoac tat ca. Danh sach lay tu Change Apps.");
        return;
    }
    void (^cb)(NSArray *) = self.onDone;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) {
            cb(picked);
        }
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 2 : (NSInteger)self.bundles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Lua chon" : @"App da tick";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return nil;
    }
    return @"Tick 1, 2, 3 hoac tat ca. Ten backup se gom ten app.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"p"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"p"];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    }
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Chon tat ca";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu app", (unsigned long)self.bundles.count];
            cell.accessoryType = (self.picked.count == self.bundles.count && self.bundles.count > 0) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"Bo chon tat ca";
            cell.detailTextLabel.text = @"Phai tick lai app muon backup";
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        return cell;
    }
    NSString *bid = self.bundles[indexPath.row];
    cell.textLabel.text = ChengIOSBundleDisplayName(bid);
    cell.detailTextLabel.text = bid;
    cell.accessoryType = [self.picked containsIndex:(NSUInteger)indexPath.row] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            self.picked = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.bundles.count)];
        } else {
            self.picked = [NSMutableIndexSet indexSet];
        }
        [tableView reloadData];
        return;
    }
    NSUInteger idx = (NSUInteger)indexPath.row;
    if ([self.picked containsIndex:idx]) {
        [self.picked removeIndex:idx];
    } else {
        [self.picked addIndex:idx];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath, [NSIndexPath indexPathForRow:0 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

@end

@implementation BackupListViewController

static NSString *CIQuery(NSURL *url, NSString *name) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) {
            return item.value;
        }
    }
    return nil;
}

static BOOL CIFlag(NSURL *url, NSArray<NSString *> *names) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] != NSOrderedSame) {
                continue;
            }
            if (item.value.length == 0 || [item.value isEqualToString:@"1"] ||
                [item.value caseInsensitiveCompare:@"true"] == NSOrderedSame ||
                [item.value caseInsensitiveCompare:@"yes"] == NSOrderedSame) {
                return YES;
            }
        }
    }
    return NO;
}

static NSString *CIToken(NSURL *url) {
    if (!url) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (url.host.length > 0) {
        [parts addObject:url.host.lowercaseString];
    }
    for (NSString *piece in [url.path componentsSeparatedByString:@"/"]) {
        if (piece.length == 0 || [piece isEqualToString:@"x-callback-url"] || [piece isEqualToString:@"x-callback"]) {
            continue;
        }
        [parts addObject:piece.lowercaseString];
    }
    return [[parts componentsJoinedByString:@"-"] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

static NSArray<NSString *> *CIBundlesFromQuery(NSURL *url) {
    NSString *raw = CIQuery(url, @"bundle") ?: CIQuery(url, @"app") ?: CIQuery(url, @"apps") ?: @"";
    if (raw.length == 0) {
        return @[];
    }
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",+ "]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [out addObject:part];
        }
    }
    return out;
}

static NSString *CIJoinTitles(NSArray *bundles) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id item in bundles) {
        if (![item isKindOfClass:[NSString class]] || [item length] == 0) {
            continue;
        }
        [parts addObject:ChengIOSBundleDisplayTitle(item)];
    }
    return [parts componentsJoinedByString:@", "];
}

static void CIPresent(UIViewController *host, NSString *title, NSString *message) {
    if (!host) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static NSString *CIBytesString(unsigned long long bytes) {
    if (bytes < 1024) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    }
    if (bytes < 1024ull * 1024ull) {
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    }
    return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
}

static NSString *CIResultText(NSDictionary *meta, NSError *error, NSString *fallbackOK) {
    if (error) {
        return ChengIOSBackupErrorMessage(error);
    }
    NSMutableString *text = [NSMutableString string];
    [text appendString:fallbackOK];
    if ([meta[@"name"] length]) {
        [text appendFormat:@"\nTen: %@", meta[@"name"]];
    }
    if ([meta[@"id"] length]) {
        [text appendFormat:@"\nID: %@", meta[@"id"]];
    }
    if (meta[@"bytes"]) {
        [text appendFormat:@"\nData: %@", CIBytesString([meta[@"bytes"] unsignedLongLongValue])];
    }
    if (meta[@"copyFiles"] || meta[@"copyFailed"]) {
        [text appendFormat:@"\nFiles: %@  fail %@", meta[@"copyFiles"] ?: @0, meta[@"copyFailed"] ?: @0];
        if ([meta[@"copyFailed"] unsignedIntegerValue] > 0) {
            [text appendString:@"\nCanh bao: copy that bai mot so file. Restore co the thieu data."];
        }
        if ([meta[@"includeAppData"] boolValue] && [meta[@"bytes"] unsignedLongLongValue] == 0) {
            [text appendString:@"\nCanh bao: Data 0 byte. Backup sandbox that bai, restore se khong co login."];
        }
    }
    NSArray *bundles = meta[@"bundles"];
    if ([bundles isKindOfClass:[NSArray class]] && bundles.count > 0) {
        [text appendFormat:@"\nApp: %@", [bundles componentsJoinedByString:@", "]];
    }
    NSArray *failed = meta[@"failedBundles"];
    if ([failed isKindOfClass:[NSArray class]] && failed.count > 0) {
        [text appendFormat:@"\nBo qua: %@", [failed componentsJoinedByString:@", "]];
    }
    if (meta[@"keychainItems"]) {
        [text appendFormat:@"\nKeychain: %@ item", meta[@"keychainItems"]];
        if (meta[@"keychainWithData"]) {
            [text appendFormat:@"  withData %@", meta[@"keychainWithData"]];
        }
        if (meta[@"signedCount"]) {
            [text appendFormat:@"  signed %@", meta[@"signedCount"]];
        }
        if (meta[@"agrpCount"]) {
            [text appendFormat:@"  agrp %@", meta[@"agrpCount"]];
        }
        if ([meta[@"ldid"] isKindOfClass:[NSString class]] && [meta[@"ldid"] length] > 0) {
            [text appendFormat:@"\nldid: %@", meta[@"ldid"]];
        }
        if ([meta[@"signedError"] isKindOfClass:[NSString class]] && [meta[@"signedError"] length] > 0) {
            [text appendFormat:@"\nKC loi: %@", meta[@"signedError"]];
        }
        if ([meta[@"includeAppData"] boolValue] && [meta[@"keychainItems"] unsignedIntegerValue] == 0) {
            [text appendString:@"\nCanh bao: Keychain 0. Cai ldid (Apps Manager ldid / Procursus). Can Keychain N>0, withData N>0, kcUid 501. Cai 1.2.53, cai ldid, Respring, roi tao backup MOI khi app dang login. Backup cu khong co Caches/tmp/companion co the khong giu login."];
        } else if ([meta[@"includeAppData"] boolValue] && [meta[@"keychainWithData"] unsignedIntegerValue] == 0) {
            [text appendString:@"\nCanh bao: Keychain khong co data. Restore se mat login. Cai ldid, Respring va backup lai khi dang login bang 1.2.53."];
        }
    }
    if (meta[@"asRoot"]) {
        [text appendFormat:@"\nRoot helper: %@", [meta[@"asRoot"] boolValue] ? @"CO" : @"KHONG"];
        if (meta[@"uid"]) {
            [text appendFormat:@"\n uid %@", meta[@"uid"]];
        }
        if (meta[@"kcUid"]) {
            [text appendFormat:@"  kcUid %@", meta[@"kcUid"]];
            if ([meta[@"kcUid"] integerValue] != 501 && [meta[@"includeAppData"] boolValue]) {
                [text appendString:@"\nCanh bao: kcUid != 501, SecItem khong vao keychain mobile. Restore se mat login."];
            }
        }
        if (meta[@"daemon"]) {
            [text appendFormat:@"  Daemon: %@", [meta[@"daemon"] boolValue] ? @"CO" : @"KHONG"];
        }
        if (meta[@"sqlCount"]) {
            id secCount = meta[@"secCount"];
            if (!secCount) {
                secCount = @0;
            }
            [text appendFormat:@"\nSQL: %@  SecItem: %@", meta[@"sqlCount"], secCount];
        }
        if (![meta[@"asRoot"] boolValue]) {
            [text appendString:@"\nCanh bao: chua chay root. Cai 1.2.20, Respring, backup lai tu app ChengIOS (daemon CO, kcUid 501). Can ldid."];
        }
    } else if ([meta[@"includeAppData"] boolValue]) {
        [text appendString:@"\nRoot helper: KHONG (ban backup cu). Restore co the mat login."];
    }
    [text appendFormat:@"\nThu muc: %@", ChengIOSBackupRoot()];
    return text;
}

static void CIPresentMaybeRespring(UIViewController *host, NSString *title, NSString *message, BOOL respring);
static void CIRunBusyEx(UIViewController *host, NSString *title, void (^work)(void (^done)(NSString *resultTitle, NSString *message, BOOL respring)));

static void CIRespringSoon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ChengIOSRequestRespring();
    });
}

static void CIPresentMaybeRespring(UIViewController *host, NSString *title, NSString *message, BOOL respring) {
    if (!respring) {
        CIPresent(host, title, message);
        return;
    }
    NSString *text = message.length ? [message stringByAppendingString:@"\n\nDang Respring..."] : @"Dang Respring...";
    if (!host) {
        CIRespringSoon();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:alert animated:YES completion:^{
        CIRespringSoon();
    }];
}

static void CIRunBusyEx(UIViewController *host, NSString *title, void (^work)(void (^done)(NSString *resultTitle, NSString *message, BOOL respring))) {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:title
                                                                  message:@"Giu app ChengIOS mo. Facebook co the mat vai phut."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:busy animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            work(^(NSString *resultTitle, NSString *message, BOOL respring) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [busy dismissViewControllerAnimated:YES completion:^{
                        CIPresentMaybeRespring(host, resultTitle, message, respring);
                    }];
                });
            });
        });
    }];
}

static void CIRunBusy(UIViewController *host, NSString *title, void (^work)(void (^done)(NSString *resultTitle, NSString *message))) {
    CIRunBusyEx(host, title, ^(void (^done)(NSString *resultTitle, NSString *message, BOOL respring)) {
        work(^(NSString *resultTitle, NSString *message) {
            done(resultTitle, message, NO);
        });
    });
}


static void CIPresentAppPicker(UIViewController *host, NSString *title, NSString *doneTitle, NSArray<NSString *> *bundles, void (^onDone)(NSArray<NSString *> *picked)) {
    if (!host) {
        return;
    }
    if (bundles.count == 0) {
        CIPresent(host, @"Chua chon app", @"Mo Change Apps, tick TikTok / Facebook / Shopee / Safari, roi bam lai.");
        return;
    }
    ChengIOSAppPickController *pick = [[ChengIOSAppPickController alloc] initWithBundles:bundles title:title doneTitle:doneTitle];
    pick.onDone = onDone;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pick];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    [host presentViewController:nav animated:YES completion:nil];
}

static NSString *CIFormatEraseRandomText(NSDictionary *result, NSError *error) {
    NSMutableString *msg = [NSMutableString string];
    NSArray *ok = result[@"ok"];
    NSArray *failed = result[@"failed"];
    NSArray *skipped = result[@"skipped"];
    if (ok.count) {
        [msg appendFormat:@"Da xoa: %@\n", CIJoinTitles(ok)];
    }
    if (failed.count) {
        [msg appendFormat:@"Loi: %@\n", CIJoinTitles(failed)];
    }
    if (skipped.count) {
        [msg appendFormat:@"Bo qua: %@\n", CIJoinTitles(skipped)];
    }
    if ([result[@"profileSummary"] length]) {
        [msg appendFormat:@"\n%@\n", result[@"profileSummary"]];
    }
    if (error && (msg.length == 0 || ok.count == 0)) {
        if (msg.length) {
            [msg appendString:@"\n"];
        }
        [msg appendString:ChengIOSBackupErrorMessage(error)];
    }
    if (msg.length == 0 && [result[@"error"] isKindOfClass:[NSString class]]) {
        [msg appendString:result[@"error"]];
    }
    if (msg.length == 0) {
        [msg appendString:@"Force-quit app roi mo lai."];
    }
    if (ok.count) {
        [msg appendString:@"\nForce-quit Shopee/TikTok/Facebook roi mo lai."];
    }
    return msg;
}

void ChengIOSRunCreateBackup(UIViewController *host, NSString *name, BOOL includeAppData, NSArray<NSString *> *bundleIDs, BOOL silent) {
    void (^go)(void) = ^{
        CIRunBusy(host, includeAppData ? @"Dang backup ho so + data" : @"Dang backup ho so", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            NSArray *bundles = includeAppData ? (bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs()) : @[];
            NSDictionary *meta = ChengIOSCreateBackup(name, bundles, includeAppData, &error);
            NSString *title = error ? @"Backup loi" : @"Da backup";
            done(title, CIResultText(meta, error, includeAppData ? @"Da luu ho so + data + keychain. Can Keychain > 0, Root CO / uid 0 (Daemon CO) de restore con login." : @"Da luu ho so ChengIOS."));
        });
    };
    if (silent) {
        go();
        return;
    }
    NSArray *nameBundles = includeAppData ? (bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs()) : @[];
    NSString *message = includeAppData
        ? [NSString stringWithFormat:@"Luu ho so + data + keychain cua %lu app. App se bi kill. Can dang nhap san. Ten backup se gom ten app.", (unsigned long)nameBundles.count]
        : @"Luu ho so gia lap hien tai (model/iOS/GPS/Wi-Fi...).";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:includeAppData ? @"Backup ho so + data" : @"Backup ho so"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name.length ? name : ChengIOSSuggestedBackupNameForBundles(nameBundles);
        field.placeholder = @"Ten backup";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Backup" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *typed = alert.textFields.firstObject.text;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ChengIOSRunCreateBackup(host, typed, includeAppData, bundleIDs, YES);
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

static void ChengIOSRunPickBackup(UIViewController *host, NSString *name, BOOL silent) {
    NSArray *all = ChengIOSUserSelectedBundleIDs();
    if (all.count == 0) {
        CIPresent(host, @"Chua chon app", @"Mo Change Apps, tick TikTok / Facebook / Shopee / Safari, roi bam Backup lai.");
        return;
    }
    if (silent) {
        ChengIOSRunCreateBackup(host, name, YES, all, YES);
        return;
    }
    CIPresentAppPicker(host, @"Backup ho so + data", @"Backup", all, ^(NSArray<NSString *> *picked) {
        ChengIOSRunCreateBackup(host, name, YES, picked, NO);
    });
}

static void ChengIOSRunBackupEraseRandom(UIViewController *host, NSString *name, NSArray<NSString *> *bundleIDs, BOOL silent, BOOL respring) {
    NSArray *fallback = ChengIOSUserSelectedBundleIDs();
    void (^go)(NSString *, NSArray *) = ^(NSString *useName, NSArray *list) {
        CIRunBusyEx(host, @"Backup + xoa + random", ^(void (^done)(NSString *, NSString *, BOOL)) {
            NSError *error = nil;
            NSDictionary *meta = ChengIOSCreateBackup(useName, list, YES, &error);
            if (!meta || error) {
                done(@"Backup loi", ChengIOSBackupErrorMessage(error), NO);
                return;
            }
            NSError *eraseError = nil;
            NSDictionary *result = ChengIOSEraseThenRandom(list, NO, YES, nil, &eraseError);
            NSMutableString *msg = [NSMutableString string];
            [msg appendString:CIResultText(meta, nil, @"Da backup ho so + data.")];
            [msg appendString:@"\n\n"];
            [msg appendString:CIFormatEraseRandomText(result, eraseError)];
            BOOL didChange = [result[@"profileSummary"] length] > 0;
            done(@"Da backup + xoa + random", msg, respring && didChange);
        });
    };
    void (^afterPick)(NSArray *) = ^(NSArray *list) {
        if (list.count == 0) {
            CIPresent(host, @"Chua chon app", @"Mo Change Apps, tick TikTok / Facebook / Shopee / Safari, roi bam lai.");
            return;
        }
        if (silent) {
            go(name.length ? name : ChengIOSSuggestedBackupNameForBundles(list), list);
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup + Xoa + Random + Respring"
                                                                       message:[NSString stringWithFormat:@"Backup ho so + data %lu app, xoa data app do, Random Toan Bo theo IP, roi Respring. Khong undo.", (unsigned long)list.count]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = name.length ? name : ChengIOSSuggestedBackupNameForBundles(list);
            field.placeholder = @"Ten backup";
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Chay" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            NSString *typed = alert.textFields.firstObject.text;
            NSArray *captured = list;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                go(typed, captured);
            });
        }]];
        [host presentViewController:alert animated:YES completion:nil];
    };
    if (silent) {
        NSArray *list = bundleIDs.count ? bundleIDs : fallback;
        afterPick(list);
        return;
    }
    if (bundleIDs.count > 0) {
        afterPick(bundleIDs);
        return;
    }
    CIPresentAppPicker(host, @"Backup + Xoa + Random", @"Tiep", fallback, afterPick);
}

void ChengIOSRunRestore(UIViewController *host, NSString *backupID, BOOL restoreProfile, BOOL restoreAppData, BOOL silent) {
    if (backupID.length == 0) {
        CIPresent(host, @"Restore loi", @"Thieu backup id.");
        return;
    }
    void (^go)(void) = ^{
        CIRunBusy(host, @"Dang restore", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            BOOL ok = ChengIOSRestoreBackup(backupID, restoreProfile, restoreAppData, &error);
            NSDictionary *meta = ChengIOSBackupInfo(backupID);
            NSString *msg = error ? ChengIOSBackupErrorMessage(error) : (ok ? @"Da restore sandbox + keychain. Force-quit Facebook/Shopee/TikTok roi mo lai. Facebook/TikTok can backup MOI bang 1.2.53 khi dang login; backup cu khong du Caches/tmp/companion. Can Data>0, Keychain withData>0, kcUid 501." : @"Restore that bai.");
            NSDictionary *stats = ChengIOSLastRestoreStats();
            if (stats.count > 0) {
                msg = [NSString stringWithFormat:@"%@\nFiles %@  fail %@  bytes %@\nKeychain restored %@  signed %@  SQL %@  fail %@  skip %@  kcUid %@",
                       msg,
                       stats[@"copiedFiles"] ?: @0,
                       stats[@"copyFailed"] ?: @0,
                       stats[@"copiedBytes"] ?: @0,
                       stats[@"keychainRestored"] ?: @0,
                       stats[@"keychainSignedRestored"] ?: @0,
                       stats[@"keychainSQLRestored"] ?: @0,
                       stats[@"keychainFailed"] ?: @0,
                       stats[@"keychainSkipped"] ?: @0,
                       stats[@"kcUid"] ?: @"?"];
            }
            if (!error && [meta[@"name"] length]) {
                msg = [NSString stringWithFormat:@"%@\n%@", meta[@"name"], msg];
            }
            done(ok ? @"Da restore" : @"Restore loi", msg);
        });
    };
    if (silent) {
        go();
        return;
    }
    NSDictionary *meta = ChengIOSBackupInfo(backupID);
    NSString *message = [NSString stringWithFormat:@"%@\nProfile: %@\nData app: %@",
                         meta[@"name"] ?: backupID,
                         restoreProfile ? @"CO" : @"khong",
                         restoreAppData ? @"CO (ghi de sandbox)" : @"khong"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore backup"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go();
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

void ChengIOSRunErase(UIViewController *host, NSArray<NSString *> *bundleIDs, BOOL silent) {
    NSArray *fallback = ChengIOSUserSelectedBundleIDs();
    void (^go)(NSArray *) = ^(NSArray *list) {
        CIRunBusy(host, @"Dang xoa data app", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            NSDictionary *result = ChengIOSEraseBundles(list, &error);
            NSMutableString *msg = [NSMutableString string];
            NSArray *ok = result[@"ok"];
            NSArray *failed = result[@"failed"];
            NSArray *skipped = result[@"skipped"];
            if (ok.count) {
                [msg appendFormat:@"Da xoa: %@\n", CIJoinTitles(ok)];
            }
            if (failed.count) {
                [msg appendFormat:@"Loi: %@\n", CIJoinTitles(failed)];
            }
            if (skipped.count) {
                [msg appendFormat:@"Bo qua (he thong): %@\n", CIJoinTitles(skipped)];
            }
            if (error && (msg.length == 0 || ok.count == 0)) {
                if (msg.length) {
                    [msg appendString:@"\n"];
                }
                [msg appendString:ChengIOSBackupErrorMessage(error)];
            }
            if (msg.length == 0 && [result[@"error"] isKindOfClass:[NSString class]]) {
                [msg appendString:result[@"error"]];
            }
            if (ok.count) {
                [msg appendString:@"\nDa xoa sandbox + group + plugin + keychain SQL. Force-quit app, doi, dung mo ngay."];
            } else if (msg.length == 0) {
                if (list.count == 0) {
                    [msg appendString:@"Chua tick app trong Change Apps. Mo Change Apps, tick TikTok/Facebook/Shopee/Safari roi bam lai."];
                } else {
                    [msg appendFormat:@"Khong xoa duoc. App da chon: %@. Respring, mo lai ChengIOS, tick lai app neu mat dau tick.", CIJoinTitles(list)];
                }
            }
            done(ok.count ? @"Da xoa data" : @"Xoa data", msg);
        });
    };
    NSArray *targets = bundleIDs.count ? bundleIDs : fallback;
    if (targets.count == 0) {
        CIPresent(host, @"Chua chon app", @"Mo Change Apps, tick TikTok / Facebook / Shopee / Safari, roi bam Xoa lai.\nNeu vua Random ma mat dau tick thi tick lai 1 lan.");
        return;
    }
    if (silent) {
        go(targets);
        return;
    }
    if (bundleIDs.count == 0 && fallback.count > 1) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Xoa sach data app"
                                                                       message:@"Chon 1 app hoac xoa tat ca app user da chon. Khong undo neu chua backup."
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Xoa TAT CA app da chon" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                go(fallback);
            });
        }]];
        for (NSString *bundle in fallback) {
            NSString *captured = [bundle copy];
            [sheet addAction:[UIAlertAction actionWithTitle:ChengIOSBundleDisplayTitle(captured) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    go(@[captured]);
                });
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
        UIPopoverPresentationController *pop = sheet.popoverPresentationController;
        if (pop) {
            pop.sourceView = host.view;
            pop.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
            pop.permittedArrowDirections = 0;
        }
        [host presentViewController:sheet animated:YES completion:nil];
        return;
    }
    NSMutableArray *titleLines = [NSMutableArray array];
    for (NSString *bid in targets) {
        [titleLines addObject:ChengIOSBundleDisplayTitle(bid)];
    }
    NSString *list = titleLines.count ? [titleLines componentsJoinedByString:@"\n"] : @"(khong co app user nao duoc chon)";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoa sach data app"
                                                                   message:[NSString stringWithFormat:@"Kill app roi xoa sandbox:\n%@\n\nKhong undo neu chua backup.", list]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoa" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go(targets);
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}


static NSString *CIEraseResultText(NSDictionary *result, NSError *error, NSString *okTitle) {
    NSMutableString *msg = [NSMutableString string];
    NSArray *ok = result[@"ok"];
    NSArray *failed = result[@"failed"];
    NSArray *skipped = result[@"skipped"];
    if (ok.count) {
        [msg appendFormat:@"Da xoa: %@\n", CIJoinTitles(ok)];
    }
    if (failed.count) {
        [msg appendFormat:@"Loi: %@\n", CIJoinTitles(failed)];
    }
    if (skipped.count) {
        [msg appendFormat:@"Bo qua: %@\n", CIJoinTitles(skipped)];
    }
    if ([result[@"profileSummary"] length]) {
        [msg appendFormat:@"\n%@\n", result[@"profileSummary"]];
    }
    if (error && msg.length == 0) {
        [msg appendString:ChengIOSBackupErrorMessage(error)];
    }
    if (msg.length == 0) {
        [msg appendString:okTitle ?: @"Xong."];
    }
    return msg;
}

void ChengIOSRunEraseSafari(UIViewController *host, BOOL silent) {
    void (^go)(void) = ^{
        CIRunBusy(host, @"Dang xoa Safari", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            NSDictionary *result = ChengIOSEraseSafari(&error);
            done(result[@"ok"] ? @"Da xoa Safari" : @"Xoa Safari", CIEraseResultText(result, error, @"Da xoa history/cookies/website data. Password iCloud Keychain khong bi xoa."));
        });
    };
    if (silent) {
        go();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoa sach Safari"
                                                                   message:@"Xoa history, cookies, website data, tab. Giong Safari moi cai. Khong xoa mat khau iCloud Keychain."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoa Safari" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go();
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

void ChengIOSRunEraseDevice(UIViewController *host, BOOL silent) {
    void (^go)(void) = ^{
        CIRunBusy(host, @"Dang xoa data toan bo app", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            NSDictionary *result = ChengIOSEraseDeviceApps(YES, &error);
            done(@"Da xoa data may", CIEraseResultText(result, error, @"Da xoa data app user + Safari. Khong phai Restore iOS. Jailbreak / anh / tin nhan / Apple ID van con."));
        });
    };
    if (silent) {
        go();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoa data toan may"
                                                                   message:@"Xoa data MOI app user + Safari (nhu moi cai app). KHONG phai factory reset iOS. Giu jailbreak, anh, tin nhan, Apple ID. Khong undo."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoa toan bo app" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go();
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

void ChengIOSRunEraseThenRandom(UIViewController *host, NSArray<NSString *> *bundleIDs, BOOL allDevice, BOOL randomAll, NSString *region, BOOL silent, BOOL respring) {
    NSArray *list = bundleIDs.count ? bundleIDs : (allDevice ? @[] : ChengIOSUserSelectedBundleIDs());
    if (!allDevice && list.count == 0) {
        CIPresent(host, @"Chua chon app", @"Mo Change Apps, tick TikTok / Facebook / Shopee / Safari, roi bam Xoa + Random lai.");
        return;
    }
    void (^go)(void) = ^{
        CIRunBusyEx(host, allDevice ? @"Xoa toan bo + random" : @"Xoa app + random", ^(void (^done)(NSString *, NSString *, BOOL)) {
            NSError *error = nil;
            NSDictionary *result = ChengIOSEraseThenRandom(list, allDevice, randomAll, region, &error);
            NSArray *ok = result[@"ok"];
            NSString *msg = CIFormatEraseRandomText(result, error);
            BOOL didChange = [result[@"profileSummary"] length] > 0;
            done(ok.count ? @"Da xoa + doi info" : @"Xoa + random", msg, respring && didChange);
        });
    };
    if (silent) {
        go();
        return;
    }
    NSString *title = allDevice ? @"Xoa toan bo + Random" : @"Xoa app da chon + Random";
    NSString *msg = allDevice
        ? @"Xoa data MOI app user + Safari, roi Random Toan Bo, roi Respring. Shopee/TikTok xoa them 1 lan sau random. KHONG phai factory reset iOS. Khong undo."
        : [NSString stringWithFormat:@"Xoa sandbox/keychain %lu app da chon, roi random info, roi Respring. Shopee/TikTok xoa them 1 lan sau random. Khong undo.", (unsigned long)list.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:randomAll ? @"Xoa + Random Toan Bo" : @"Xoa + Random Info May" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go();
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

BOOL ChengIOSHandleBackupURL(NSURL *url, UIViewController *host) {
    if (!url || !host) {
        return NO;
    }
    NSString *token = CIToken(url);
    BOOL silent = CIFlag(url, @[@"silent", @"quiet", @"x-silent"]);
    BOOL respring = !CIFlag(url, @[@"norespring", @"skip-respring"]);
    NSString *name = CIQuery(url, @"name") ?: CIQuery(url, @"title") ?: CIQuery(url, @"label");
    BOOL wantData = CIFlag(url, @[@"data", @"appdata", @"apps", @"full"]);
    NSString *backupID = CIQuery(url, @"id") ?: CIQuery(url, @"backup") ?: CIQuery(url, @"backup-id");

    NSString *region = CIQuery(url, @"region") ?: CIQuery(url, @"iso");
    if ([token containsString:@"backup-erase-random"] || [token containsString:@"backup-wipe-random"] || [token containsString:@"backup-random-erase"] || [token containsString:@"backup-xoa-random"]) {
        ChengIOSRunBackupEraseRandom(host, name, CIBundlesFromQuery(url), silent, respring);
        return YES;
    }
    if ([token containsString:@"erase-device-random"] || [token containsString:@"wipe-device-random"] || [token containsString:@"factory-random"]) {
        ChengIOSRunEraseThenRandom(host, CIBundlesFromQuery(url), YES, YES, region, silent, respring);
        return YES;
    }
    if ([token containsString:@"erase-random-all"] || [token containsString:@"wipe-random-all"] || [token containsString:@"reset-all"]) {
        ChengIOSRunEraseThenRandom(host, CIBundlesFromQuery(url), NO, YES, region, silent, respring);
        return YES;
    }
    if ([token containsString:@"erase-random"] || [token containsString:@"wipe-random"] || [token containsString:@"reset-identity"]) {
        ChengIOSRunEraseThenRandom(host, CIBundlesFromQuery(url), NO, NO, region, silent, respring);
        return YES;
    }
    if ([token containsString:@"erase-device"] || [token containsString:@"wipe-device"] || [token containsString:@"erase-all-apps"]) {
        ChengIOSRunEraseDevice(host, silent);
        return YES;
    }
    if ([token containsString:@"erase-safari"] || [token containsString:@"wipe-safari"]) {
        ChengIOSRunEraseSafari(host, silent);
        return YES;
    }
    if ([token containsString:@"backup-apps"] || [token containsString:@"backup-data"] || [token containsString:@"backup-all"] || [token containsString:@"backup-now"]) {
        NSArray *queryBundles = CIBundlesFromQuery(url);
        if (queryBundles.count > 0 || silent) {
            ChengIOSRunCreateBackup(host, name, YES, queryBundles, silent);
        } else {
            ChengIOSRunPickBackup(host, name, silent);
        }
        return YES;
    }
    if ([token containsString:@"backup-profile"] || [token containsString:@"backup-info"] || [token containsString:@"backup-hoso"]) {
        ChengIOSRunCreateBackup(host, name, NO, @[], silent);
        return YES;
    }
    if ([token isEqualToString:@"backup"] || [token isEqualToString:@"backups"] || [token containsString:@"backup-manager"] || [token containsString:@"quan-ly-backup"]) {
        if (![host isKindOfClass:[BackupListViewController class]]) {
            BackupListViewController *list = [[BackupListViewController alloc] initWithStyle:UITableViewStyleGrouped];
            [host.navigationController pushViewController:list animated:YES];
        }
        return YES;
    }
    if ([token containsString:@"restore-latest"] || [token isEqualToString:@"restorelatest"]) {
        NSString *latest = ChengIOSLatestBackupID();
        if (latest.length == 0) {
            CIPresent(host, @"Restore", @"Chua co backup.");
            return YES;
        }
        ChengIOSRunRestore(host, latest, YES, wantData, silent);
        return YES;
    }
    if ([token isEqualToString:@"restore"] || [token hasPrefix:@"restore-"]) {
        if (backupID.length == 0) {
            backupID = ChengIOSLatestBackupID();
        }
        BOOL noProfile = CIFlag(url, @[@"noprofile", @"profile-off"]);
        NSString *profileValue = CIQuery(url, @"profile");
        BOOL restoreProfile = !noProfile;
        if (profileValue.length && ([profileValue isEqualToString:@"0"] || [profileValue caseInsensitiveCompare:@"no"] == NSOrderedSame)) {
            restoreProfile = NO;
        }
        ChengIOSRunRestore(host, backupID, restoreProfile, wantData, silent);
        return YES;
    }
    if ([token containsString:@"erase-apps"] || [token containsString:@"wipe-apps"] || [token isEqualToString:@"wipe"] || [token isEqualToString:@"erase-all"] || [token isEqualToString:@"eraseall"]) {
        ChengIOSRunErase(host, CIBundlesFromQuery(url), silent);
        return YES;
    }
    if ([token isEqualToString:@"erase"] || [token isEqualToString:@"wipe-app"] || [token hasPrefix:@"erase-"]) {
        NSArray *bundles = CIBundlesFromQuery(url);
        ChengIOSRunErase(host, bundles, silent);
        return YES;
    }
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Danh sach backup";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reloadBackups)];
    [self reloadBackups];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadBackups];
}

- (void)reloadBackups {
    self.backups = ChengIOSListBackups();
    [self.tableView reloadData];
}

- (void)promptBackupIncludingAppData:(BOOL)includeAppData suggestedName:(NSString *)name silent:(BOOL)silent {
    if (includeAppData) {
        ChengIOSRunPickBackup(self, name, silent);
        return;
    }
    ChengIOSRunCreateBackup(self, name, includeAppData, nil, silent);
}

- (void)promptEraseBundles:(NSArray<NSString *> *)bundleIDs silent:(BOOL)silent {
    ChengIOSRunErase(self, bundleIDs, silent);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)MAX(self.backups.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Danh sach backup";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [NSString stringWithFormat:@"Thu muc: %@\nThao tac Backup/Xoa/Random o man hinh chinh. An 1 dong de restore, doi ten hoac xoa. Sau backup can Keychain withData>0, kcUid 501, Root CO, ldid CO.", ChengIOSBackupRoot()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"b"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"b"];
        cell.detailTextLabel.numberOfLines = 3;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    }
    if (self.backups.count == 0) {
        cell.textLabel.text = @"Chua co backup";
        cell.detailTextLabel.text = @"Dung Backup o man hinh chinh khi dang login.";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = self.backups[indexPath.row];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.text = item[@"name"] ?: item[@"id"];
    NSMutableString *detail = [NSMutableString string];
    if ([item[@"created"] length]) {
        [detail appendString:item[@"created"]];
    }
    NSArray *bundles = item[@"bundles"];
    if ([item[@"includeAppData"] boolValue] && [bundles isKindOfClass:[NSArray class]]) {
        [detail appendFormat:@"  ·  %lu app  ·  %@", (unsigned long)bundles.count, CIBytesString([item[@"bytes"] unsignedLongLongValue])];
        if (item[@"keychainItems"]) {
            [detail appendFormat:@"  ·  KC %@", item[@"keychainItems"]];
        }
        if (item[@"kcUid"]) {
            [detail appendFormat:@"  ·  kcUid %@", item[@"kcUid"]];
        }
        if (item[@"asRoot"]) {
            [detail appendFormat:@"  ·  root %@", [item[@"asRoot"] boolValue] ? @"CO" : @"KHONG"];
        }
    } else {
        [detail appendString:@"  ·  ho so"];
    }
    NSString *summary = item[@"profileSummary"];
    if ([summary isKindOfClass:[NSString class]] && summary.length > 0) {
        NSArray *lines = [summary componentsSeparatedByString:@"\n"];
        [detail appendFormat:@"\n%@", lines.firstObject];
    }
    cell.detailTextLabel.text = detail;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.backups.count == 0) {
        return;
    }
    NSDictionary *item = self.backups[indexPath.row];
    NSString *backupID = item[@"id"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item[@"name"] ?: backupID
                                                                   message:item[@"created"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore ho so" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        ChengIOSRunRestore(self, backupID, YES, NO, NO);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore ho so + data app" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        ChengIOSRunRestore(self, backupID, YES, YES, NO);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chi restore data app" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        ChengIOSRunRestore(self, backupID, NO, YES, NO);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Doi ten" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self renameBackup:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sao chep ID / path" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *text = [NSString stringWithFormat:@"%@\nchengios://restore?id=%@\n%@", item[@"name"], backupID, item[@"path"]];
        [UIPasteboard generalPasteboard].string = text;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Xoa backup nay" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (ChengIOSDeleteBackup(backupID, &error)) {
            [self reloadBackups];
        } else {
            CIPresent(self, @"Xoa backup loi", ChengIOSBackupErrorMessage(error));
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = tableView;
        pop.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)renameBackup:(NSDictionary *)item {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Doi ten backup"
                                                                   message:item[@"id"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = item[@"name"];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Luu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (ChengIOSRenameBackup(item[@"id"], alert.textFields.firstObject.text, &error)) {
            [self reloadBackups];
        } else {
            CIPresent(self, @"Doi ten loi", ChengIOSBackupErrorMessage(error));
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return self.backups.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle != UITableViewCellEditingStyleDelete || self.backups.count == 0) {
        return;
    }
    NSString *backupID = self.backups[indexPath.row][@"id"];
    ChengIOSDeleteBackup(backupID, nil);
    [self reloadBackups];
}

@end

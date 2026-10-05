//
//  bridge.m  —  MGHelper 桥接模块（v0.2.0）
//
//  背景（2026-10-05 诊断实锤）：
//    TrollStore 安装时会把我们嵌的 entitlements **整份替换**成它自己的模板
//    （只剩 application-identifier/get-task-allow/container-required/keychain-access-groups），
//    所以 App 运行时被钉死在自己容器里 —— no-sandbox / app group / 写别人容器 全部无望。
//
//    但 App 在沙盒内**能写自己的容器**：MG7Store.directory 在 /var/mobile/Library 被拒后
//    会自动回退到 <App容器>/Documents/，于是 config.plist / snapshot.json 就落在那里。
//    小组件读的是 <小组件容器>/Library/MG7Share/。
//
//    本模块就是这个「桥」：以 root 身份（launchd 启动，不受沙盒限制）定期把这两个文件
//    从 App 容器搬进小组件容器。小组件一旦拿到 config（含 token/VIN），
//    **它自己就会联网拉车况**（它本来就有网络权限），彻底不依赖 entitlements。
//
//  用法：
//    mghelper bridge          常驻循环（由 LaunchDaemon 拉起）
//    mghelper bridge-once     只同步一次后退出（手动排查用）
//
//  日志：/var/mobile/Library/MG7Widget/bridge.log（Filza 可看）
//

#import <Foundation/Foundation.h>

static NSString *const kAppBundleID    = @"com.banliren.mg7widget";
static NSString *const kWidgetBundleID = @"com.banliren.mg7widget.widget";
static NSString *const kStatusDir      = @"/var/mobile/Library/MG7Widget";
static NSString *const kLogPath        = @"/var/mobile/Library/MG7Widget/bridge.log";
static NSString *const kShareSubdir    = @"Library/MG7Share";
static const int       kPollSeconds    = 3;
static const unsigned long long kLogCap = 256 * 1024;   // 日志上限，超了截断重来

#pragma mark - 小工具

/// 容器目录里的元数据（iOS 16 上是 .com.apple.mobile_container_manager.metadata.plist）
static NSString *containerIdentifier(NSString *container) {
    for (NSString *name in @[@".com.apple.mobile_container_manager.metadata.plist",
                             @".com.apple.containermanagerd.metadata.plist"]) {
        NSString *p = [container stringByAppendingPathComponent:name];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            NSString *ident = d[@"MCMMetadataIdentifier"];
            if (!ident) {   // 兜底：描述串里带 bundle id 特征也算命中
                NSString *desc = d.description ?: @"";
                if ([desc containsString:@"com.banliren.mg7widget"]) ident = desc;
            }
            if (ident) return ident;
        }
    }
    return nil;
}

/// 列出 base 下所有容器里 identifier == wantID 的容器路径
static NSArray<NSString *> *containersMatching(NSString *base, NSString *wantID,
                                               NSMutableArray<NSString *> *seen) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
    if (!entries) return out;   // 目录不存在或无权限：静默跳过（PluginKitExtension 在 iOS16 上就不存在）
    for (NSString *e in entries) {
        if ([e hasPrefix:@"."]) continue;
        NSString *c = [base stringByAppendingPathComponent:e];
        NSString *ident = containerIdentifier(c);
        if (ident && [ident isEqualToString:wantID]) {
            [out addObject:c];
            if (seen) [seen addObject:c.lastPathComponent];
        }
    }
    return out;
}

/// 写日志（幂等；超上限则截断）
static void bridgeLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kStatusDir withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions: @0755} error:nil];

    NSDictionary *attr = [fm attributesOfItemAtPath:kLogPath error:nil];
    if (attr && [attr[NSFileSize] unsignedLongLongValue] > kLogCap) {
        [@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:kLogPath error:nil];
}

/// 源文件有变化才拷贝；返回 YES 表示本次真的写了
static BOOL syncFile(NSString *src, NSString *dst) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *sa = [fm attributesOfItemAtPath:src error:nil];
    if (!sa) return NO;                       // 源不存在：跳过
    NSDictionary *da = [fm attributesOfItemAtPath:dst error:nil];
    if (da
        && [sa[NSFileSize] isEqual:da[NSFileSize]]
        && [[sa fileModificationDate] isEqual:[da fileModificationDate]]) {
        return NO;                            // 大小+修改时间一致：认为无需搬
    }
    [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:src toPath:dst error:&err]) {
        bridgeLog(@"✗ 拷贝失败 %@ -> %@ : %@", src.lastPathComponent, dst, err.localizedDescription);
        return NO;
    }
    // 小组件进程是 mobile 身份；顺手设置属主/权限/数据保护（保证锁屏后小组件也能读）
    [fm setAttributes:@{NSFilePosixPermissions: @0644,
                        NSFileOwnerAccountName: @"mobile",
                        NSFileGroupOwnerAccountName: @"mobile",
                        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
          ofItemAtPath:dst error:nil];
    bridgeLog(@"✓ 已桥接 %@ (%llu B)", dst, [sa[NSFileSize] unsignedLongLongValue]);
    return YES;
}

#pragma mark - 一次同步

/// 单次同步；detail 输出本次概况，changed 输出是否发生写入
static int bridgeSyncOnce(NSMutableString *detail, BOOL *changed) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kStatusDir withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions: @0755} error:nil];

    NSMutableArray<NSString *> *appIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *widgetIDs = [NSMutableArray array];

    NSArray *apps = containersMatching(@"/var/mobile/Containers/Data/Application",
                                       kAppBundleID, appIDs);
    NSMutableArray *widgets = [NSMutableArray array];
    [widgets addObjectsFromArray:containersMatching(
        @"/var/mobile/Containers/Data/PluginKitPlugin", kWidgetBundleID, widgetIDs)];
    [widgets addObjectsFromArray:containersMatching(
        @"/var/mobile/Containers/Data/PluginKitExtension", kWidgetBundleID, widgetIDs)];
    // 去重（两个根目录扫描结果可能重复）
    widgets = [[[NSSet setWithArray:widgets] allObjects] mutableCopy];

    if (detail) {
        [detail appendFormat:@"app容器=%lu widget容器=%lu",
                             (unsigned long)apps.count, (unsigned long)widgets.count];
    }
    if (apps.count == 0 || widgets.count == 0) {
        return 0;   // 容器还没就绪（App 没装/没开过，或小组件还没加到桌面）：下轮再看
    }

    // 源目录优先级：App 自己的 Documents（沙盒回退落点）→ Library/MG7Share → 老共享目录
    NSMutableArray<NSString *> *srcDirs = [NSMutableArray array];
    for (NSString *app in apps) {
        [srcDirs addObject:[app stringByAppendingPathComponent:@"Documents"]];
        [srcDirs addObject:[app stringByAppendingPathComponent:kShareSubdir]];
    }
    [srcDirs addObject:kStatusDir];

    BOOL wrote = NO;
    for (NSString *w in widgets) {
        NSString *destDir = [w stringByAppendingPathComponent:kShareSubdir];
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0755} error:nil];
        [fm setAttributes:@{NSFilePosixPermissions: @0755,
                            NSFileOwnerAccountName: @"mobile",
                            NSFileGroupOwnerAccountName: @"mobile"}
              ofItemAtPath:destDir error:nil];

        for (NSString *file in @[@"config.plist", @"snapshot.json"]) {
            for (NSString *sd in srcDirs) {
                NSString *src = [sd stringByAppendingPathComponent:file];
                if (![fm fileExistsAtPath:src]) continue;
                NSString *dst = [destDir stringByAppendingPathComponent:file];
                if (syncFile(src, dst)) wrote = YES;
                break;   // 每个文件只取优先级最高的那份源
            }
        }
    }
    if (changed) *changed = wrote;
    return (int)widgets.count;
}

#pragma mark - 对外入口

int bridgeRunOnce(void) {
    @autoreleasepool {
        NSMutableString *detail = [NSMutableString string];
        BOOL changed = NO;
        id n = @(bridgeSyncOnce(detail, &changed));
        (void)n;
        NSString *stamp = changed ? @"（有更新）" : @"（无变化）";
        printf("%s %s\n", detail.UTF8String, stamp.UTF8String);
        bridgeLog(@"单次同步: %@ %@", detail, stamp);
    }
    return 0;
}

int bridgeRunForever(void) {
    @autoreleasepool {
        bridgeLog(@"=== 桥接守护启动 v0.2.0 (uid=%d) app=%@ widget=%@ ===",
                  getuid(), kAppBundleID, kWidgetBundleID);
        printf("[mghelper] bridge daemon up (uid=%d), poll=%ds\n", getuid(), kPollSeconds);
        fflush(stdout);
    }

    unsigned long long cycle = 0;
    unsigned long long lastHeartbeat = 0;
    while (1) {
        @autoreleasepool {
            cycle++;
            NSMutableString *detail = [NSMutableString string];
            BOOL changed = NO;
            bridgeSyncOnce(detail, &changed);

            time_t now = time(NULL);
            if (changed || now - (time_t)lastHeartbeat >= 600) {   // 有变化或每 10 分钟记一次心跳
                lastHeartbeat = (unsigned long long)now;
                if (cycle > 1 || changed) {
                    bridgeLog(@"%@ %@", changed ? @"同步" : @"心跳", detail);
                }
            }
        }
        sleep(kPollSeconds);
    }
    return 0;
}

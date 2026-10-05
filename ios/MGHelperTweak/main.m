//
//  main.m  —  MGHelper v0.1.1
//  越狱辅助工具：自动从 MG Live 沙盒捞 ACCESS_TOKEN，写入共享层，
//  免去每次手动抓包填 token。
//
//  v0.1.1 改动：
//   - 不再依赖猜测的 bundle id，改为全容器全量扫描（token 形如 xxx-prod_SAIC，特征唯一）
//   - 数据容器路径 /var/mobile/Containers/Data/Application 不再用 jbroot() 包裹
//     （roothide 的 jbroot 只映射引导区；用户数据区包 jbroot 反而指向不存在路径）
//   - 二进制文件用 Latin1 无损转换后扫描（SQLite/二进制缓存里藏的 token 也能捞到）
//   - 新增 diag 模式：打印所有容器 bundle id 清单，便于远程确认 MG Live 真实 bundle id
//
//  用法：
//   mghelper          扫描并写 token 到 /var/mobile/Library/MGLiveWidget/token_raw.txt
//   mghelper diag     同上，另打印全部容器 bundle id + 扫描统计
//   mghelper dump     打印已保存的 token
//

#import <Foundation/Foundation.h>

// v0.2.0 桥接模块（bridge.m）
extern int bridgeRunOnce(void);
extern int bridgeRunForever(void);

#define SHARED_DIR  @"/var/mobile/Library/MGLiveWidget"

static int g_scannedContainers = 0;
static int g_scannedFiles = 0;

static NSString *metaBundleID(NSString *containerPath) {
    NSString *plist = [containerPath stringByAppendingPathComponent:
                       @".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:plist];
    return d[@"MCMMetadataIdentifier"];
}

/// 在目录里递归找形如 *-prod_SAIC 的 token；outPath 返回命中文件路径
static NSString *findTokenInDirectory(NSString *dir, NSInteger depth, NSString **outPath) {
    if (depth <= 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!items) return nil;
    for (NSString *it in items) {
        NSString *p = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        [fm fileExistsAtPath:p isDirectory:&isDir];
        if (isDir) {
            NSString *found = findTokenInDirectory(p, depth - 1, outPath);
            if (found) return found;
            continue;
        }
        // >8MB 的文件（地图缓存/视频等）不可能藏 token，跳过
        NSNumber *sz = [fm attributesOfItemAtPath:p error:nil][NSFileSize];
        if (sz && sz.longLongValue > 8 * 1024 * 1024) continue;

        NSData *data = [NSData dataWithContentsOfFile:p];
        if (!data || data.length < 32) continue;
        g_scannedFiles++;

        // Latin1：字节→字符 1:1 无损映射，任何二进制（SQLite/缓存/二进制plist）都能扫
        // token 是纯 ASCII，不会被编码转换破坏
        NSString *txt = [[NSString alloc] initWithData:data
                                             encoding:NSISOLatin1StringEncoding];
        if (!txt) continue;

        // 匹配 xxx-prod_SAIC（16 位以上前缀）
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"[A-Za-z0-9_\\-\\.]{16,}-prod_SAIC"
                                 options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:txt
                                                 options:0
                                                   range:NSMakeRange(0, txt.length)];
        if (m) {
            if (outPath) *outPath = p;
            return [txt substringWithRange:m.range];
        }
    }
    return nil;
}

#pragma mark - 主逻辑

static int refreshToken(BOOL diag) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:SHARED_DIR
  withIntermediateDirectories:YES attributes:nil error:nil];

    // 用户数据区：roothide 下真实路径原样存在，不需要 jbroot()
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:base error:nil];
    NSLog(@"[MGHelper] 数据容器数量: %@",
          uuids ? [NSString stringWithFormat:@"%lu", (unsigned long)uuids.count]
                : @"路径不可读!");

    if (diag) {
        NSLog(@"[MGHelper] ---- 全部容器 bundle id ----");
        for (NSString *u in uuids) {
            NSString *c = [base stringByAppendingPathComponent:u];
            NSLog(@"[MGHelper]   %@ -> %@", u, metaBundleID(c) ?: @"(无meta)");
        }
        NSLog(@"[MGHelper] ----------------------------");
    }

    // ---- 快路径：先挑出疑似 MG Live 的容器，优先只扫它们 ----
    // 不解任何文件内容，只读 metadata plist，毫秒级完成
    NSMutableArray<NSString *> *priority = [NSMutableArray array];
    NSMutableArray<NSString *> *others   = [NSMutableArray array];
    for (NSString *u in uuids) {
        NSString *c = [base stringByAppendingPathComponent:u];
        NSString *bid = metaBundleID(c) ?: @"";
        NSString *low = bid.lowercaseString;
        // 命中任一特征词即视为疑似 MG Live
        BOOL hit = [low containsString:@"saic"] || [low containsString:@"mglive"]
                || [low containsString:@"mg-live"] || [low containsString:@"ebanma"]
                || ([low containsString:@"mg"] && [low containsString:@"live"]);
        if (hit) {
            [priority addObject:u];
            NSLog(@"[MGHelper] ★ 优先扫描疑似容器: %@ -> %@", u, bid);
        } else {
            [others addObject:u];
        }
    }
    NSLog(@"[MGHelper] 疑似 MG Live 容器 %lu 个，其余 %lu 个",
          (unsigned long)priority.count, (unsigned long)others.count);

    // 先扫疑似容器（通常 1 个，秒出结果）
    NSArray *order = [priority arrayByAddingObjectsFromArray:others];
    for (NSString *u in order) {
        @autoreleasepool {
            NSString *container = [base stringByAppendingPathComponent:u];
            g_scannedContainers++;
            NSString *foundPath = nil;
            NSString *token = findTokenInDirectory(container, 7, &foundPath);
            if (token) {
                NSString *bundle = metaBundleID(container) ?: @"unknown";
                NSString *out = [SHARED_DIR stringByAppendingPathComponent:@"token_raw.txt"];
                [token writeToFile:out atomically:YES
                          encoding:NSUTF8StringEncoding error:nil];
                [fm setAttributes:@{NSFilePosixPermissions: @0600}
                       ofItemAtPath:out error:nil];
                // 附带元信息，便于确认 MG Live 真实 bundle id 和 token 存储位置
                NSString *meta = [NSString stringWithFormat:
                    @"bundle=%@\nfile=%@\ngrabbed=%@\n",
                    bundle, foundPath,
                    [NSDate dateWithTimeIntervalSinceNow:8*3600]];
                [meta writeToFile:[SHARED_DIR stringByAppendingPathComponent:@"token_meta.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:nil];

                NSLog(@"[MGHelper] ✓ 找到 token!");
                NSLog(@"[MGHelper]   bundle: %@", bundle);
                NSLog(@"[MGHelper]   文件:   %@", foundPath);
                NSLog(@"[MGHelper]   尾部:   ...%@",
                      [token substringFromIndex:token.length - 16]);
                return 0;
            }
            // 每扫完一个疑似容器就报进度，避免用户以为卡死
            if (g_scannedContainers % 20 == 0) {
                NSLog(@"[MGHelper] 进度 %d/%lu 容器, %d 文件...",
                      g_scannedContainers, (unsigned long)order.count, g_scannedFiles);
            }
        }
    }
    NSLog(@"[MGHelper] token NOT found（扫了 %d 个容器 / %d 个文件）",
          g_scannedContainers, g_scannedFiles);
    NSLog(@"[MGHelper] 若容器数为 0 或 MG Live 刚登录，请先打开 MG Live 再跑一次");
    return 1;
}

static int dumpToken(void) {
    NSString *out = [SHARED_DIR stringByAppendingPathComponent:@"token_raw.txt"];
    NSString *t = [NSString stringWithContentsOfFile:out
                                            encoding:NSUTF8StringEncoding error:nil];
    printf("%s\n", t ? t.UTF8String : "(none)");
    return t ? 0 : 1;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        setuid(0); setgid(0);
        if (argc > 1 && strcmp(argv[1], "dump") == 0) return dumpToken();
        if (argc > 1 && strcmp(argv[1], "diag") == 0) return refreshToken(YES);
        // v0.2.0: 桥接模式（由 LaunchDaemon 以 root 拉起，把 App 容器的
        // config.plist / snapshot.json 搬进小组件容器，绕开 TrollStore 的沙盒限制）
        if (argc > 1 && strcmp(argv[1], "bridge") == 0) return bridgeRunForever();
        if (argc > 1 && strcmp(argv[1], "bridge-once") == 0) return bridgeRunOnce();
        return refreshToken(NO);
    }
}

//
//  main.m  —  MGHelper
//  越狱辅助工具：自动从 MG Live 沙盒捞 ACCESS_TOKEN，写入共享层，
//  免去每次手动抓包填 token。
//
//  编译：gmake package THEOS_PACKAGE_SCHEME=roothide
//

#import <Foundation/Foundation.h>
#include <roothide.h>   // roothide 的 jbroot() 宏，需 roothide/theos

#define SHARED_DIR  @"/var/mobile/Library/MGLiveWidget"

// MG Live 的 bundle id（待用 `ipainstaller -l` 或 Filza 确认真实值）
static NSString *const kMGLiveBundleIDs[] = {
    @"com.saicmotor.mglive",
    @"com.saic.mglive",
    @"com.saicmotor.mg",
    nil
};

#pragma mark - 工具

static NSArray<NSString *> *appDataContainers(void) {
    // roothide 下真实容器目录
    NSString *base = jbroot(@"/var/mobile/Containers/Data/Application");
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
}

static NSString *metaBundleID(NSString *containerPath) {
    NSString *plist = [containerPath stringByAppendingPathComponent:
                       @".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:plist];
    return d[@"MCMMetadataIdentifier"];
}

/// 在 MG Live 容器里递归找形如 *-prod_SAIC 的 token
static NSString *findTokenInDirectory(NSString *dir, NSInteger depth) {
    if (depth <= 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *it in items) {
        NSString *p = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        [fm fileExistsAtPath:p isDirectory:&isDir];
        if (isDir) {
            NSString *found = findTokenInDirectory(p, depth - 1);
            if (found) return found;
            continue;
        }
        // 只扫小文本/plist，避免读垃圾
        NSNumber *sz = [fm attributesOfItemAtPath:p error:nil][NSFileSize];
        if (sz && sz.longLongValue > 512 * 1024) continue;

        NSData *data = [NSData dataWithContentsOfFile:p];
        if (!data || data.length < 32) continue;
        NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!txt) {
            // 尝试二进制 plist → 序列化回文本
            id obj = [NSPropertyListSerialization propertyListWithData:data
                                                              options:0
                                                               format:NULL
                                                                error:nil];
            if (obj) {
                NSData *j = [NSPropertyListSerialization dataWithPropertyList:obj
                                    format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
                txt = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
            }
        }
        if (!txt) continue;

        // 匹配 xxx-prod_SAIC
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"[A-Za-z0-9_\\-\\.]{16,}-prod_SAIC"
                                 options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:txt
                                                 options:0
                                                   range:NSMakeRange(0, txt.length)];
        if (m) return [txt substringWithRange:m.range];
    }
    return nil;
}

#pragma mark - 主逻辑

static int refreshToken(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:SHARED_DIR
  withIntermediateDirectories:YES attributes:nil error:nil];

    for (int i = 0; kMGLiveBundleIDs[i]; i++) {
        NSString *want = kMGLiveBundleIDs[i];
        for (NSString *uuid in appDataContainers()) {
            NSString *container = [jbroot(@"/var/mobile/Containers/Data/Application")
                                   stringByAppendingPathComponent:uuid];
            if (![metaBundleID(container) isEqualToString:want]) continue;

            NSString *token = findTokenInDirectory(container, 6);
            if (token) {
                NSString *out = [SHARED_DIR stringByAppendingPathComponent:@"token_raw.txt"];
                [token writeToFile:out atomically:YES
                          encoding:NSUTF8StringEncoding error:nil];
                [fm setAttributes:@{NSFilePosixPermissions: @0600}
                     ofItemAtPath:out error:nil];
                NSLog(@"[MGHelper] token acquired (tail: ...%@)", [token substringFromIndex:token.length-16]);
                return 0;
            }
        }
    }
    NSLog(@"[MGHelper] token NOT found");
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
        return refreshToken();
    }
}

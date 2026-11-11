// worse_query.h — 头文件（上游接口，GPL-3.0-or-later）
// 来源：https://github.com/forcequitOS/worse_query （作者 Taj C / forcequit）
// 用途：以 App Group 容器为跳板，通过 containermanager 的 part-domain + 符号链接
//       取得任意路径的 sandbox extension，从而读取其它 App 容器。
//
// 集成注意：GPL-3.0-or-later，二进制分发需遵守其条款。

#ifndef worse_query_h
#define worse_query_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

/// 取得 target 路径的 sandbox extension。
/// @param target     目标绝对路径（不存在时需 create_dir=true）
/// @param group      本 App 拥有的 App Group 标识（entitlement 里那个）
/// @param alt_flags  iOS 26.x 需要传 true；iOS 27+ 传 false
/// @param create_dir target 不存在时是否创建
/// @return >0 成功（extension handle）；<0 失败：
///         -1 拿不到 App Group 容器
///         -2 dlopen/dlsym 失败（系统不支持）
///         -3 query 创建失败
///         -4 符号链接创建失败
///         -5 containermanagerd 拒绝
///         -6 内核拒绝签发 extension
///         -255 目标不存在且 create_dir=false
int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir);

/// 释放 handle
void worse_query_release(int64_t handle);

#endif

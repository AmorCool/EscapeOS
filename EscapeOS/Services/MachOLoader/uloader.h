//
//  uloader.h
//  EscapeOS
//
//  用户态 Mach-O dylib 加载器（v0.3.108，移植自 Nyxian kxld，AGPL-3.0-or-later）
//  用途：绕开 dyld 的库校验，自己映射/重定位/绑定并调用模块 dylib。
//

#ifndef uloader_h
#define uloader_h

#include <stddef.h>

/// 加载 dylib（自行 mmap + rebase + bind + 构造器）。成功返回句柄，失败返回 NULL 并填 errBuf。
void *uloader_load(const char *path, char *errBuf, size_t errBufSize);

/// 在已加载镜像中查找符号（name 可带或不带前导下划线）。
void *uloader_symbol(void *handle, const char *name);

/// 卸载并释放。
void uloader_unload(void *handle);

#endif /* uloader_h */

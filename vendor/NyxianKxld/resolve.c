/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#include <LindChain/ProcEnvironment/Surface/kxld/resolve.h>
#include <LindChain/ProcEnvironment/Surface/radix/radix.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <os/lock.h>

static radix_tree_t g_kext_symbol_tree = { 0 };
static radix_tree_t g_kext_identity_tree = { 0 };
static os_unfair_lock g_kext_symbol_lock = OS_UNFAIR_LOCK_INIT;

static uint64_t KXSymbolKey(const char *name)
{
    uint64_t h = 1469598103934665603ULL;
    for(const uint8_t *p = (const uint8_t *)name; *p; p++)
    {
        h ^= *p;
        h *= 1099511628203ULL;
    }
    return h;
}

void KXRegisterExportCore(const char *name, void *addr)
{
    const char *lookup = (name[0] == '_') ? name + 1 : name;
    os_unfair_lock_lock(&g_kext_symbol_lock);
    uint64_t key = KXSymbolKey(lookup);
    kx_export_t *symbol = radix_remove(&g_kext_symbol_tree, key);
    if(symbol != NULL)
    {
        free(symbol->name);
        free(symbol);
    }
    symbol = malloc(sizeof(*symbol));
    symbol->name = strdup(lookup);
    if(symbol->name == NULL)
    {
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return;
    }
    symbol->addr = addr;
    radix_insert(&g_kext_symbol_tree, key, symbol);
    os_unfair_lock_unlock(&g_kext_symbol_lock);
}

void KXRegisterExport(const char *name,
                      void *addr)
{
    const char *lookup = (name[0] == '_') ? name + 1 : name;
    void *dlAddr = dlsym(RTLD_DEFAULT, lookup);
    if(dlAddr != NULL)
    {
        /* cant export */
        return;
    }
    os_unfair_lock_lock(&g_kext_symbol_lock);
    uint64_t key = KXSymbolKey(lookup);
    kx_export_t *symbol = radix_remove(&g_kext_symbol_tree, key);
    if(symbol != NULL)
    {
        free(symbol->name);
        free(symbol);
    }
    symbol = malloc(sizeof(*symbol));
    symbol->name = strdup(lookup);
    if(symbol->name == NULL)
    {
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return;
    }
    symbol->addr = addr;
    radix_insert(&g_kext_symbol_tree, key, symbol);
    os_unfair_lock_unlock(&g_kext_symbol_lock);
}

void *KXResolve(const char *name)
{
    os_unfair_lock_lock(&g_kext_symbol_lock);
    if(!name)
    {
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return NULL;
    }
    const char *lookup = (name[0] == '_') ? name + 1 : name;
    kx_export_t *e = radix_lookup(&g_kext_symbol_tree, KXSymbolKey(lookup));
    if(e && strcmp(e->name, lookup) == 0)
    {
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return e->addr;
    }
    os_unfair_lock_unlock(&g_kext_symbol_lock);
    return dlsym(RTLD_DEFAULT, lookup);
}

kern_return_t KXRegisterKext(kxld_image_info_t *image_info)
{
    os_unfair_lock_lock(&g_kext_symbol_lock);
    uint64_t key = KXSymbolKey(image_info->mod->identifier);
    kxld_image_info_t *found = radix_lookup(&g_kext_identity_tree, key);
    if(found != NULL)
    {
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return KERN_NAME_EXISTS;
    }
    radix_insert(&g_kext_identity_tree, key, image_info);
    os_unfair_lock_unlock(&g_kext_symbol_lock);
    return KERN_SUCCESS;
}

kern_return_t KXUnregisterKext(kxld_image_info_t *image_info)
{
    os_unfair_lock_lock(&g_kext_symbol_lock);
    uint64_t key = KXSymbolKey(image_info->mod->identifier);
    kxld_image_info_t *found = radix_remove(&g_kext_identity_tree, key);
    if(found == NULL)
    {
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return KERN_NOT_FOUND;
    }
    os_unfair_lock_unlock(&g_kext_symbol_lock);
    return KERN_SUCCESS;
}

kern_return_t KXGetRegisteredKextForIdentifier(const char *identifier,
                                               kxld_image_info_t **image_info)
{
    os_unfair_lock_lock(&g_kext_symbol_lock);
    uint64_t key = KXSymbolKey(identifier);
    kxld_image_info_t *found = radix_lookup(&g_kext_identity_tree, key);
    if(found)
    {
        *image_info = found;
        os_unfair_lock_unlock(&g_kext_symbol_lock);
        return KERN_SUCCESS;
    }
    os_unfair_lock_unlock(&g_kext_symbol_lock);
    return KERN_NOT_FOUND;
}

static uint32_t platform_query_version(void)
{
    char buf[32];
    size_t len = sizeof(buf);
    unsigned maj = 0, min = 0, pat = 0;
    
    if(sysctlbyname("kern.osproductversion", buf, &len, NULL, 0) != 0)
    {
        return 0;
    }
    if(sscanf(buf, "%u.%u.%u", &maj, &min, &pat) < 1)
    {
        return 0;
    }
    
    return KMOD_VERSION(maj, min, pat);
}

static kinfo_mod_t g_ksurface_kmod = {
    .magic = KSURFACE_KMOD_MAGIC,
    .abi_version = KSURFACE_KMOD_ABI_VERSION,
    .identifier = "ksurface",
    .version = KMOD_VERSION(0, 11, 4),
    .flags = KMOD_FLAG_PERSISTENT,
    .dependency_count = 1,
    .dependencies = {
        {
            .identifier = "com.apple.iphoneos",
            .min_version = KMOD_VERSION(18, 4, 0),      /* bottom */
            .max_version = KMOD_VERSION(99, 99, 99),    /* ceiling is unclear, dependant on apples mood swings >~< */
        }
    },
};

static kinfo_mod_t g_ios_kmod = {
    .magic = KSURFACE_KMOD_MAGIC,
    .abi_version = KSURFACE_KMOD_ABI_VERSION,
    .identifier = "com.apple.iphoneos",
    .version = 0,
    .flags = KMOD_FLAG_PERSISTENT,
    .dependency_count = 0,
};

__attribute__((constructor))
static void register_nximage(void)
{
    /* pre-register ksurface */
    kxld_image_info_t *image_ksurface_info = calloc(1, sizeof(kxld_image_info_t));
    image_ksurface_info->mod = &g_ksurface_kmod;
    KXRegisterKext(image_ksurface_info);
    
    /* pre-register com.apple.iphoneos */
    g_ios_kmod.version = platform_query_version();
    kxld_image_info_t *image_ios_info = calloc(1, sizeof(kxld_image_info_t));
    image_ios_info->mod = &g_ios_kmod;
    KXRegisterKext(image_ios_info);
}

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

#include <LindChain/ProcEnvironment/Utils/klog.h>
#include <LindChain/ProcEnvironment/Surface/kxld/kxopen.h>
#include <LindChain/ProcEnvironment/Surface/kxld/validation.h>
#include <LindChain/ProcEnvironment/Surface/kxld/mapper.h>
#include <LindChain/ProcEnvironment/Surface/kxld/fixup.h>
#include <LindChain/ProcEnvironment/Surface/kxld/reseal.h>
#include <LindChain/ProcEnvironment/Surface/kxld/image.h>
#include <LindChain/ProcEnvironment/Surface/kxld/kmod.h>
#include <LindChain/ProcEnvironment/Surface/kxld/export.h>
#include <LindChain/ProcEnvironment/Surface/kxld/init.h>
#include <LindChain/ProcEnvironment/Surface/kxld/objc.h>
#include <LindChain/ProcEnvironment/Surface/kxld/resolve.h>
#include <LindChain/ProcEnvironment/Surface/trust/signing.h>
#include <LindChain/ProcEnvironment/LiveContainer/LCMachOUtils.h>
#include <LindChain/ProcEnvironment/Shims/panic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/param.h>
#include <mach-o/loader.h>
#include <mach-o/ldsyms.h>
#include <os/lock.h>
#include <pthread.h>

static os_unfair_lock g_kxld_lock = OS_UNFAIR_LOCK_INIT;

static void kxdestroy_image(kxld_image_info_t *image_info)
{
    if(image_info->base != NULL)
    {
        munmap(image_info->base, image_info->len);
    }
    free(image_info);
}

void *ksurface_kext_thread(void *ii)
{
    kxld_image_info_t *image_info = (kxld_image_info_t*)ii;
    
    /* invoking kextension start */
    klog_log("kextloader:thread", "spinning up kext '%s'", image_info->mod->identifier);
    image_info->mod->start();
    if(!(image_info->mod->flags & KMOD_FLAG_PERSISTENT))
    {
        if(image_info->mod->deinit)
        {
            kern_return_t kr = image_info->mod->deinit();
            if(kr != KERN_SUCCESS)
            {
                environment_panic("kext '%s' failed to deinitialize: %s", image_info->mod->identifier, mach_error_string(kr));
            }
        }
        
        os_unfair_lock_lock(&g_kxld_lock);
        if(KXUnregisterKext(image_info) == KERN_SUCCESS)
        {
            kxdestroy_image(image_info);
        }
        os_unfair_lock_unlock(&g_kxld_lock);
    }
    
    return NULL;
}

kern_return_t kxopen(const char *path,
                     int mode,
                     kxld_image_info_t **export_info)
{
    int fd = open(path, O_RDWR);
    if(fd < 0)
    {
        return KERN_FAILURE;
    }
    
    kern_return_t kr = kxopen_with_fd(fd, mode, export_info);
    close(fd);
    return kr;
}

kern_return_t kxopen_with_fd(int fd,
                             int mode,
                             kxld_image_info_t **export_info)
{
    if(fd < 0)
    {
        errno = EINVAL;
        return KERN_INVALID_ARGUMENT;
    }
    
    os_unfair_lock_lock(&g_kxld_lock);
    /* map machO */
    LCMachO *machO = LCMapMachOFromFDRO(dup(fd));
    if(machO == NULL)
    {
        goto out_failure;
    }
    
    /* checking if the kernel says(double meaning x3) this is signed */
    if(!KXValidateCodeSignature(machO))
    {
        LCUnmapMachO(machO);
        goto out_failure;
    }
    
    kxld_image_info_t *image_info = calloc(1, sizeof(kxld_image_info_t));
    if(image_info == NULL)
    {
        LCUnmapMachO(machO);
        errno = ENOMEM;
        goto out_failure;
    }
    
    if(fcntl(machO->fd, F_GETPATH, image_info->path) != 0)
    {
        LCUnmapMachO(machO);
        free(image_info);
        errno = ENOMEM;
        goto out_failure;
    }
    
    bool success = KXMapMachOExecutable(machO, image_info);
    LCUnmapMachO(machO);
    if(!success)
    {
        /* sets errno */
        goto out_failure_destroy;
    }
    
    /* we gotta get kmod first */
    if(!KXLocateKmod(image_info))
    {
        goto out_failure_destroy;
    }
    
    /* resolve dependencies versions */
    for(uint32_t i = 0; i < image_info->mod->dependency_count; i++)
    {
        kxld_image_info_t *depImageInfo;
        kern_return_t kr = KXGetRegisteredKextForIdentifier(image_info->mod->dependencies[i].identifier, &depImageInfo);
        if(kr != KERN_SUCCESS)
        {
            goto out_failure_destroy;
        }
        
        if(depImageInfo->mod->version < image_info->mod->dependencies[i].min_version ||
           depImageInfo->mod->version > image_info->mod->dependencies[i].max_version)
        {
            goto out_failure_destroy;
        }
        
        /* so the kext knows on what version this dependency is */
        image_info->mod->dependencies[i].min_version = depImageInfo->mod->version;
        image_info->mod->dependencies[i].max_version = depImageInfo->mod->version;
        depImageInfo->mod->flags |= KMOD_FLAG_PERSISTENT;   /* deny dependency unload TODO: track images */
    }
    
    /* apply persistent flag if KXLD_NOCLOSE is set */
    if(mode & KXLD_NOCLOSE)
    {
        image_info->mod->flags |= KMOD_FLAG_PERSISTENT;
    }
    
    /* fixing up kmod and the blobs offsets */
    if(!KXApplyFixups(image_info))
    {
        goto out_failure_destroy;
    }
    
    /* still very unmappable */
    kern_return_t kr = KXRegisterKext(image_info);
    if(kr != KERN_SUCCESS)
    {
        kxdestroy_image(image_info);
        os_unfair_lock_unlock(&g_kxld_lock);
        return kr;
    }
    
    /* now the spicy port with the symbol exports */
    if(!KXRegisterKextExports(image_info))
    {
        goto out_failure_unregister;
    }
    
    if(!KXRegisterObjCImage(image_info))
    {
        goto out_failure_unregister;
    }
    
    /* now resealing */
    if(!KXResealDataConst(image_info))
    {
        goto out_failure_unregister;
    }
    
    if(!KXRunInitializers(image_info))
    {
        goto out_failure_unregister;
    }
    
    /* now lets initialize the kext it self */
    if(image_info->mod->init)
    {
        kern_return_t kr = image_info->mod->init();
        if(kr != KERN_SUCCESS)
        {
            klog_log("kextloader", "kext '%s', had a failure initializing: %s", image_info->mod->identifier, mach_error_string(kr));
            errno = EBADEXEC;
            goto out_failure_unregister;
        }
    }
    
    if(image_info->mod->start)
    {
        pthread_t thread;
        if(pthread_create(&thread, NULL, ksurface_kext_thread, (void*)image_info) != 0)
        {
            if(image_info->mod->deinit)
            {
                kern_return_t kr = image_info->mod->deinit();
                if(kr != KERN_SUCCESS)
                {
                    environment_panic("kext '%s' failed to deinitialize: %s", image_info->mod->identifier, mach_error_string(kr));
                }
            }
            klog_log("kextloader", "failed start thread for kext '%s'", image_info->mod->identifier);
            goto out_failure_unregister;
        }
        pthread_detach(thread);
    }
    else if(!(image_info->mod->flags & KMOD_FLAG_PERSISTENT))
    {
        /* did its modifications, but KMOD_FLAG_PERSISTENT is disabled */
        if(image_info->mod->deinit)
        {
            kern_return_t kr = image_info->mod->deinit();
            if(kr != KERN_SUCCESS)
            {
                environment_panic("kext '%s' failed to deinitialize: %s", image_info->mod->identifier, mach_error_string(kr));
            }
        }
        os_unfair_lock_unlock(&g_kxld_lock);
        return KERN_SUCCESS;
    }
    
    /* done =3 */
    klog_log("kextloader", "successfully initialized kext '%s'", image_info->mod->identifier);
    os_unfair_lock_unlock(&g_kxld_lock);
    if(export_info)
    {
        *export_info = image_info;
    }
    return KERN_SUCCESS;
    
out_failure_unregister:
    if(KXUnregisterKext(image_info) == KERN_SUCCESS)
    {
        kxdestroy_image(image_info);
    }
    os_unfair_lock_unlock(&g_kxld_lock);
    return KERN_FAILURE;
out_failure_destroy:
    kxdestroy_image(image_info);
out_failure:
    os_unfair_lock_unlock(&g_kxld_lock);
    return KERN_FAILURE;
}

kern_return_t kxclose(kxld_image_info_t *claimed_image_info)
{
    os_unfair_lock_lock(&g_kxld_lock);
    klog_log("kextloader", "unloading kext '%s'", claimed_image_info->mod->identifier);
    
    /* finding kext object */
    kxld_image_info_t *image_info = NULL;
    if(KXGetRegisteredKextForIdentifier(claimed_image_info->mod->identifier, &image_info) != KERN_SUCCESS)
    {
        klog_log("kextloader", "couldn't find kext for identifier '%s'", claimed_image_info->mod->identifier);
        return KERN_NOT_FOUND;
    }
    
    if(!(image_info->mod->flags & KMOD_FLAG_PERSISTENT))
    {
        /* now we can remove it again */
        klog_log("ksurface:kext:unload", "stopping kext");
        kern_return_t kr;
        if(image_info->mod->stop)
        {
            kr = image_info->mod->stop();
            if(kr != KERN_SUCCESS)
            {
                environment_panic("kext '%s' failed to stop: %s", image_info->mod->identifier, mach_error_string(kr));
            }
            else
            {
                /* kext's thread is supposed to do it */
                os_unfair_lock_unlock(&g_kxld_lock);
                return KERN_SUCCESS;
            }
        }
        if(image_info->mod->deinit)
        {
            kr = image_info->mod->deinit();
            if(kr != KERN_SUCCESS)
            {
                environment_panic("kext '%s' failed to deinitialize: %s", image_info->mod->identifier, mach_error_string(kr));
            }
        }
        if(KXUnregisterKext(image_info) == KERN_SUCCESS)
        {
            kxdestroy_image(image_info);
        }
    }
    else
    {
        klog_log("kextloader", "kext '%s' is marked as not unloadable", image_info->mod->identifier);
        os_unfair_lock_unlock(&g_kxld_lock);
        return KERN_NOT_SUPPORTED;
    }
    
    
    klog_log("kextloader", "successfully unloaded kext '%s'", image_info->mod->identifier);
    os_unfair_lock_unlock(&g_kxld_lock);
    return KERN_SUCCESS;
}

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

#include <LindChain/ProcEnvironment/Surface/kxld/mapper.h>

bool KXMapMachOExecutable(LCMachO *machO,
                          kxld_image_info_t *image_info)
{
    /* how much memory does this kext need? */
    uintptr_t vmStart = UINT64_MAX;
    uintptr_t vmEnd = 0;
    const uint8_t *ptr = ((const uint8_t *)machO->header) + sizeof(struct mach_header_64);
    uint64_t ncmds = machO->header->ncmds;
    for(uint32_t i = 0; i < ncmds; i++)
    {
        const struct load_command *lc = (const struct load_command *)ptr;
        if(lc->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)ptr;
            if(sc->vmsize == 0)
            {
                ptr += lc->cmdsize;
                continue;
            }
            vmStart = MIN(vmStart, sc->vmaddr);
            vmEnd = MAX(vmEnd, sc->vmaddr + sc->vmsize);
        }
        ptr += lc->cmdsize;
    }
    
    /* allocating the memory needed by the segments of the kext (aka address space reservation) */
    image_info->len = vmEnd - vmStart;
    image_info->base = mmap(NULL, image_info->len, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if(image_info->base == MAP_FAILED)
    {
        return false;
    }
    
    /* calculating slide of kext */
    image_info->slide = (intptr_t)image_info->base - (intptr_t)vmStart;
    
    /* now mapping executable memory on iOS the valid way */
    image_info->sliceOffset = (uint8_t*)machO->header - (uint8_t*)machO->map;
    ptr = ((const uint8_t *)machO->header) + sizeof(struct mach_header_64);
    for(uint32_t i = 0; i < ncmds; i++)
    {
        const struct load_command *lc = (const struct load_command *)ptr;
        if(lc->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)ptr;
            if(sc->vmsize == 0)
            {
                ptr += lc->cmdsize;
                continue;
            }
            
            /* now a lot of math ^^ */
            void *addr = (void *)(sc->vmaddr + image_info->slide);
            off_t fileOff = image_info->sliceOffset + sc->fileoff;
            int prot = 0;
            if(sc->initprot & VM_PROT_READ)
            {
                prot |= PROT_READ;
            }
            if(sc->initprot & VM_PROT_WRITE)
            {
                prot |= PROT_WRITE;
            }
            if(sc->initprot & VM_PROT_EXECUTE)
            {
                prot |= PROT_EXEC;
            }
            
            int flags = (sc->initprot & VM_PROT_WRITE) ? (MAP_PRIVATE | MAP_FIXED) : (MAP_SHARED  | MAP_FIXED);
            
            /* the everything part */
            if(sc->filesize > 0)
            {
                void *r = mmap(addr, sc->filesize, prot, flags, machO->fd, fileOff);
                if(r == MAP_FAILED)
                {
                    return false;
                }
            }
            
            /* the bss part */
            size_t pageSize = vm_page_size;
            if(sc->vmsize > sc->filesize)
            {
                /* I love tails >~< */
                uintptr_t fileEnd = (uintptr_t)addr + sc->filesize;
                uintptr_t bssStart = (fileEnd + pageSize - 1) & ~(pageSize - 1);
                uintptr_t bssEnd = (uintptr_t)addr + sc->vmsize;
                bssEnd = (bssEnd + pageSize - 1) & ~(pageSize - 1);
                
                if(bssEnd > bssStart)
                {
                    void *r = mmap((void *)bssStart, bssEnd - bssStart, prot, MAP_PRIVATE | MAP_FIXED | MAP_ANON, -1, 0);
                    if(r == MAP_FAILED)
                    {
                        return false;
                    }
                }
            }
        }
        ptr += lc->cmdsize;
    }
    
    image_info->header = image_info->base;
    
    return true;
}

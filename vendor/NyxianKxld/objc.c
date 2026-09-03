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

#include <LindChain/ProcEnvironment/Surface/kxld/objc.h>
#include <dlfcn.h>

static bool KXImageHasObjC(kxld_image_info_t *image_info)
{
    const uint8_t *ptr = (const uint8_t *)image_info->header + sizeof(struct mach_header_64);
    uint32_t ncmds = image_info->header->ncmds;
    for(uint32_t i = 0; i < ncmds; i++)
    {
        const struct load_command *lc = (const struct load_command *)ptr;
        if(lc->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            const struct section_64 *sects = (const struct section_64 *)(sc + 1);
            for(uint32_t s = 0; s < sc->nsects; s++)
            {
                if(strncmp(sects[s].sectname, "__objc_", 7) == 0)
                {
                    return true;
                }
            }
        }
        ptr += lc->cmdsize;
    }
    return false;
}

typedef void (*objc_map_images_t)(unsigned count, const char * const paths[], const struct mach_header * const mhdrs[]);

bool KXRegisterObjCImage(kxld_image_info_t *image_info)
{
    static objc_map_images_t objc_map = NULL;
    static bool probed = false;
    if(!probed)
    {
        objc_map = (objc_map_images_t)dlsym(RTLD_DEFAULT, "_objc_map_images");
        probed = true;
    }
    if(!objc_map)
    {
        return false;
    }
    if(!KXImageHasObjC(image_info))
    {
        return true;
    }
    
    const struct mach_header *mh = (const struct mach_header *)image_info->header;
    const char * const paths[1] = { image_info->path };
    const struct mach_header * const mhdrs[1] = { mh };
    
    objc_map(1, paths, mhdrs);
    return true;
}

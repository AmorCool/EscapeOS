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

#include <LindChain/ProcEnvironment/Surface/kxld/init.h>
#include <LindChain/ProcEnvironment/Utils/klog.h>

typedef void (*kx_init_fn)(int argc, char **argv, char **envp, char **apple, void *vars);

bool KXRunInitializers(kxld_image_info_t *image_info)
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
                const struct section_64 *sect = &sects[s];
                uint32_t type = sect->flags & SECTION_TYPE;
                if(type == S_MOD_INIT_FUNC_POINTERS)
                {
                    kx_init_fn *fns = (kx_init_fn *)((uintptr_t)image_info->slide + sect->addr);
                    size_t n = sect->size / sizeof(kx_init_fn);
                    for (size_t k = 0; k < n; k++)
                    {
                        fns[k](0, NULL, NULL, NULL, NULL);
                    }
                }
                else if(type == S_INIT_FUNC_OFFSETS)
                {
                    uint32_t *offs = (uint32_t *)((uintptr_t)image_info->slide + sect->addr);
                    size_t n = sect->size / sizeof(uint32_t);
                    for(size_t k = 0; k < n; k++)
                    {
                        kx_init_fn fn = (kx_init_fn)((uintptr_t)image_info->header + offs[k]);
                        fn(0, NULL, NULL, NULL, NULL);
                    }
                }
            }
        }
        ptr += lc->cmdsize;
    }
    return true;
}

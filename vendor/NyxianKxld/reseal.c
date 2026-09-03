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

#include <LindChain/ProcEnvironment/Surface/kxld/reseal.h>

bool KXResealDataConst(kxld_image_info_t *image_info)
{
    const uint8_t *ptr = ((const uint8_t *)image_info->header) + sizeof(struct mach_header_64);
    uint64_t ncmds = image_info->header->ncmds;
    for(uint32_t i = 0; i < ncmds; i++)
    {
        const struct load_command *lc = (const struct load_command *)ptr;
        if(lc->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *sc = (struct segment_command_64*)lc;
            if(!(sc->initprot & VM_PROT_WRITE) && strncmp(sc->segname, "__DATA_CONST", 16) == 0)
            {
                void *addr = (void *)((uintptr_t)image_info->slide + sc->vmaddr);
                if(mprotect(addr, sc->vmsize, PROT_READ) != 0)
                {
                    fprintf(stderr, "reseal __DATA_CONST failed: %s\n", strerror(errno));
                    return false;
                }
            }
        }
        ptr += lc->cmdsize;
    }
    return true;
}

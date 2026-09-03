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

#include <LindChain/ProcEnvironment/Surface/kxld/kmod.h>

const uint8_t *ksurface_locate_modinfo(const uint8_t *base, size_t size, uint64_t *out_len);

static bool macho_name_eq(const char *field,
                          size_t field_size,
                          const char *want)
{
    size_t have = strnlen(field, field_size);
    size_t want_len = strlen(want);
    return have == want_len && memcmp(field, want, want_len) == 0;
}

static bool range_ok(uint64_t off,
                     uint64_t len,
                     uint64_t total)
{
    return len <= total && off <= total - len;
}

const uint8_t *ksurface_locate_modinfo(const uint8_t *base,
                                       size_t size,
                                       uint64_t *out_len)
{
    if(size < sizeof(struct mach_header_64))
    {
        return NULL;
    }
    
    const struct mach_header_64 *mh = (const struct mach_header_64 *)base;
    if(mh->magic != MH_MAGIC_64)
    {
        return NULL;
    }
    if(mh->filetype != MH_KEXT_BUNDLE)
    {
        return NULL;
    }
    if(!range_ok(sizeof(*mh), mh->sizeofcmds, size))
    {
        return NULL;
    }
    
    const uint8_t *cursor = base + sizeof(*mh);
    const uint8_t *lc_end = cursor + mh->sizeofcmds;
    for(uint32_t i = 0; i < mh->ncmds; i++)
    {
        if((uint64_t)(lc_end - cursor) < sizeof(struct load_command))
        {
            return NULL;
        }
        
        const struct load_command *lc = (const struct load_command *)cursor;
        if(lc->cmdsize < sizeof(struct load_command) ||
           (lc->cmdsize & 0x7) ||
           lc->cmdsize > (uint64_t)(lc_end - cursor))
        {
            return NULL;
        }
        
        if(lc->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if(lc->cmdsize < sizeof(*seg))
            {
                return NULL;
            }
            
            if(macho_name_eq(seg->segname, sizeof(seg->segname), SEG_DATA) ||
               macho_name_eq(seg->segname, sizeof(seg->segname), "__DATA_CONST"))
            {
                uint64_t need = sizeof(*seg) + (uint64_t)seg->nsects * sizeof(struct section_64);
                if(lc->cmdsize < need)
                {
                    return NULL;
                }
                
                const struct section_64 *sec = (const struct section_64 *)(cursor + sizeof(*seg));
                
                for(uint32_t j = 0; j < seg->nsects; j++)
                {
                    if(!macho_name_eq(sec[j].sectname, sizeof(sec[j].sectname), "__ksurfacemod"))
                    {
                        continue;
                    }
                    
                    uint32_t type = sec[j].flags & SECTION_TYPE;
                    if(type == S_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL)
                    {
                        return NULL;
                    }
                    
                    if(!range_ok(sec[j].offset, sec[j].size, size))
                    {
                        return NULL;
                    }
                    
                    *out_len = sec[j].size;
                    return base + sec[j].offset;
                }
            }
        }
        cursor += lc->cmdsize;
    }
    return NULL;
}

bool KXLocateKmod(kxld_image_info_t *image_info)
{
    uint64_t sec_len = 0;
    const uint8_t *blob = ksurface_locate_modinfo(image_info->base, image_info->len, &sec_len);
    if(blob == NULL)
    {
        return false;
    }
    
    if(sec_len < sizeof(kinfo_mod_t))
    {
        return false;
    }
    image_info->mod = (kinfo_mod_t*)blob;
    
    if(image_info->mod->magic != KSURFACE_KMOD_MAGIC ||
       image_info->mod->abi_version != KSURFACE_KMOD_ABI_VERSION ||
       strnlen(image_info->mod->identifier, KMOD_MAX_NAME) == KMOD_MAX_NAME)
    {
        return false;
    }
    
    return true;
}

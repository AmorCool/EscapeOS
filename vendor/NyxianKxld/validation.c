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

#include <LindChain/ProcEnvironment/Surface/kxld/validation.h>

bool KXValidateCodeSignature(LCMachO *machO)
{
    /* validate machO header it self */
    if(machO->header->magic != MH_MAGIC_64 ||
       machO->header->filetype != MH_KEXT_BUNDLE ||
       machO->header->cputype != CPU_TYPE_ARM64)
    {
        errno = ENOEXEC;
        return false;
    }
    
    /* trying to locate the link edit data command */
    off_t sliceOffset = (uint8_t*)machO->header - (uint8_t*)machO->map;
    struct linkedit_data_command* linkEditDataCommand = findSignatureCommand(machO->header);
    if(sliceOffset < 0 ||
       linkEditDataCommand == NULL ||
       linkEditDataCommand->datasize == 0 ||
       linkEditDataCommand->dataoff > machO->size ||
       linkEditDataCommand->datasize > machO->size - linkEditDataCommand->dataoff)
    {
        errno = ENOEXEC;
        return false;
    }
    
    /* binary must be signed, otherwise no execution */
    fsignatures_t siginfo = { .fs_file_start = sliceOffset, .fs_blob_start = (void*)(long)(linkEditDataCommand->dataoff), .fs_blob_size = linkEditDataCommand->datasize };
    fchecklv_t checkInfo = { .lv_file_start = sliceOffset, 0 }; /* the rest is zero by default */
    ksurface_nxt2_t nxt2_result = { 0 };
    bool hasKextEntitlement = false;
    
    /* checking if apple likes the executable */
    if(fcntl(machO->fd, F_ADDFILESIGS_RETURN, &siginfo) == -1 ||
       fcntl(machO->fd, F_CHECK_LV, &checkInfo) == -1)
    {
        goto out_denied;
    }
    
    /* nyxian trust blob is required and it must be signed with `org.emexlabs.nyxian.ksurface.kernelextension.loading` set to true */
    if(trust_nxt2_read_fd(machO->fd, &nxt2_result) != KERN_SUCCESS)
    {
        goto out_denied;
    }
    
    /* entitlements must be present */
    if(nxt2_result.entitlements == NULL)
    {
        goto out_denied;
    }
    
    /* and it must be signed (data structure has to be trusted before reading it's contents, CS basics) */
    if(!nxt2_result.isValid ||
       !nxt2_result.isCdHashValid ||
       !nxt2_result.isSigned)
    {
        CFRelease(nxt2_result.entitlements);
        goto out_denied;
    }
    
    /* blob is trusted, checking myxian trust blob entitlement requirement */
    hasKextEntitlement = CFDictionaryGetValue(nxt2_result.entitlements, kNXT2EntitlementKsurfaceKEXTLoading) == kCFBooleanTrue;
    CFRelease(nxt2_result.entitlements);
    if(!hasKextEntitlement)
    {
        goto out_denied;
    }
    
    return true;
    
out_denied:
    errno = EPERM;
    return false;
}

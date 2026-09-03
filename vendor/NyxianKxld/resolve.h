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

#ifndef KXLD_RESOLVE_H
#define KXLD_RESOLVE_H

#include <LindChain/ProcEnvironment/LiveContainer/LCMachOUtils.h>
#include <LindChain/ProcEnvironment/Surface/kxld/image.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/param.h>
#include <mach-o/loader.h>
#include <mach-o/ldsyms.h>

typedef struct {
    char *name;
    void *addr;
} kx_export_t;

void KXRegisterExportCore(const char *name, void *addr);
void KXRegisterExport(const char *name, void *addr);
void *KXResolve(const char *name);

kern_return_t KXRegisterKext(kxld_image_info_t *image_info);
kern_return_t KXUnregisterKext(kxld_image_info_t *image_info);
kern_return_t KXGetRegisteredKextForIdentifier(const char *identifier, kxld_image_info_t **image_info);

#endif /* KXLD_RESOLVE_H */

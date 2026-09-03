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

#ifndef KXLD_KXOPEN_H
#define KXLD_KXOPEN_H

#include <LindChain/ProcEnvironment/Surface/kxld/image.h>
#include <stdio.h>

#define KXLD_DEFAULT    0
#define KXLD_NOCLOSE    (1ull << 1)

kern_return_t kxopen(const char *path, int mode, kxld_image_info_t **image_info);
kern_return_t kxopen_with_fd(int fd, int mode, kxld_image_info_t **image_info);
kern_return_t kxclose(kxld_image_info_t *image_info);

#endif /* KXLD_KXOPEN_H */

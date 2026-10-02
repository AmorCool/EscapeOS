#!/usr/bin/env python3
"""Fetch pinned SAP build inputs, verify every asset, and build Unicorn without JIT."""
import bz2
import hashlib
import io
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
import zlib

REVISION = '53471ef9cf480fab094bf13db3e5d2f9e2c30dc5'
ARCHIVE_SHA256 = 'e395e308aae3629aebe14d6692ce989018e52060c3e0506d02d01f2047f52a47'
APPLE_URL = 'https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/5dqkl4rqgbsr18yzy61yeie9g3cmjc5hiv/OSXUpd10.9.pkg'
ASSETS = {
    'CommerceKit': (3271840, 'b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2'),
    'CommerceCore': (207744, 'c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2'),
    'CoreFP': (29014912, 'f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074'),
    'CoreFP.icxs': (5288352, '473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a'),
    # v0.3.540：`ent/download` 免登录下载链要用的解密器镜像（上游 ipatool `internal/sap/
    # assets/storeagent.go` 同款 path/size/digest）。与上面四个**同源**——都在同一个
    # OSXUpd10.9.pkg 的 Payload CPIO 里，所以复用同一条 Range 通道，无需另开下载路径。
    'storeagent': (2580176, '70ce036f9dbcbc04db9511ebd08de0dd3cbc35ccc9d44b089c90170cb5453c59'),
}


def valid_asset(path, spec):
    return path.is_file() and path.stat().st_size == spec[0] and hashlib.sha256(path.read_bytes()).hexdigest() == spec[1]


def apple_range(start, end=None):
    request = urllib.request.Request(APPLE_URL, headers={'Range': f'bytes={start}-{end if end is not None else ""}'})
    response = urllib.request.urlopen(request, timeout=90)
    if response.status != 206 or not response.headers.get('Content-Range', '').startswith(f'bytes {start}-'):
        response.close()
        raise RuntimeError('Apple asset server did not honor the range request')
    return response


class PrefixedReader:
    def __init__(self, stream):
        self.prefix, self.stream = b'BZh9', stream

    def read(self, size=-1):
        if self.prefix:
            result, self.prefix = self.prefix, b''
            return result
        return self.stream.read(size)

    def seekable(self):
        return False


def exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise RuntimeError('Truncated Apple asset archive')
    return data


def fetch_assets(directory, reuse_cache=True):
    directory.mkdir(parents=True, exist_ok=True)
    if all(valid_asset(directory / name, spec) for name, spec in ASSETS.items()):
        return
    # The same verified cache is used by official ipatool; never copy unverified bytes.
    #
    # 注意上游把资产放**两个**缓存目录（`internal/sap/assets/assets.go` 的
    # `apple-assets-v2` 与 `storeagent.go` 的 `apple-storeagent-v1`），
    # 所以这里两个都要探，否则本机已缓存 storeagent 时仍会去重下 2.5MB。
    ipatool_sap = Path.home() / 'Library/Caches/ipatool/sap'
    for cache in (ipatool_sap / 'apple-assets-v2', ipatool_sap / 'apple-storeagent-v1'):
        for name, spec in ASSETS.items():
            if reuse_cache and not (directory / name).exists() and valid_asset(cache / name, spec):
                shutil.copy2(cache / name, directory / name)
    if all(valid_asset(directory / name, spec) for name, spec in ASSETS.items()):
        return
    print('Downloading SAP assets from Apple…', flush=True)
    with apple_range(0, 27) as response:
        magic, header_size, _, toc_size, _, _ = struct.unpack('>4sHHQQI', exact(response, 28))
    if magic != b'xar!' or toc_size > 16 * 1024 * 1024:
        raise RuntimeError('Unexpected Apple XAR header')
    with apple_range(header_size, header_size + toc_size - 1) as response:
        toc = ET.fromstring(zlib.decompress(response.read()))
    payload = next(node for node in toc.findall('.//file') if node.findtext('name') == 'Payload')
    start = header_size + toc_size + int(payload.findtext('data/offset')) + 0x352F40D5
    found = set()
    with apple_range(start) as response, bz2.BZ2File(PrefixedReader(response)) as archive:
        exact(archive, 0x3A4)
        while len(found) < len(ASSETS):
            header = exact(archive, 76)
            if header[:6] != b'070707':
                raise RuntimeError('Unexpected CPIO header')
            name_size, size = int(header[59:65], 8), int(header[65:76], 8)
            if not 1 <= name_size <= 4096:
                raise RuntimeError('Invalid CPIO path')
            name = exact(archive, name_size).rstrip(b'\0').decode()
            if name == 'TRAILER!!!':
                break
            basename = name.rsplit('/', 1)[-1]
            if basename in ASSETS and size == ASSETS[basename][0]:
                data = exact(archive, size)
                if hashlib.sha256(data).hexdigest() != ASSETS[basename][1]:
                    raise RuntimeError(f'Invalid SAP asset hash: {basename}')
                (directory / basename).write_bytes(data)
                found.add(basename)
            else:
                while size:
                    count = min(size, 1024 * 1024)
                    exact(archive, count)
                    size -= count
    if not all(valid_asset(directory / name, spec) for name, spec in ASSETS.items()):
        raise RuntimeError('Missing SAP assets')


def prepare_source(root):
    source = root / 'source'
    if (source / '.asspp-revision').exists() and (source / '.asspp-revision').read_text() == REVISION:
        return source
    archive = root / 'unicorn.tar.gz'
    url = f'https://codeload.github.com/Naville/unicorn/tar.gz/{REVISION}'
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read(16 * 1024 * 1024)
    if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
        raise RuntimeError('Unicorn source checksum mismatch')
    archive.write_bytes(data)
    with tarfile.open(archive) as tar:
        # This archive is pinned and verified before extraction.
        tar.extractall(root)
    if source.exists():
        shutil.rmtree(source)
    (root / f'unicorn-{REVISION}').rename(source)
    (source / '.asspp-revision').write_text(REVISION)
    return source


def main():
    root = Path(os.environ['DERIVED_FILE_DIR']) / 'SAP'
    root.mkdir(parents=True, exist_ok=True)
    source = prepare_source(root)
    assets = root / 'assets'
    fetch_assets(assets)
    cmake = shutil.which('cmake') or next((str(p) for p in [Path('/opt/homebrew/bin/cmake'), Path('/usr/local/bin/cmake')] if p.exists()), None)
    if not cmake:
        raise RuntimeError('CMake is required. Install it with: brew install cmake')
    platform = os.environ['PLATFORM_NAME']
    libraries = []
    for arch in os.environ['ARCHS'].split():
        build = root / f'build-{platform}-{arch}'
        command = [cmake, '-S', str(source), '-B', str(build), '-DUNICORN_INTERPRETER=ON', '-DUNICORN_ARCH=x86', '-DUNICORN_BUILD_TESTS=OFF', '-DUNICORN_INSTALL=OFF', '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_OSX_ARCHITECTURES={arch}', f'-DCMAKE_OSX_SYSROOT={os.environ["SDKROOT"]}']
        if platform in ('iphoneos', 'iphonesimulator'):
            command += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0']
        else:
            command += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
        if not (build / 'libunicorn.a').exists():
            subprocess.run(command, check=True)
            subprocess.run([cmake, '--build', str(build), '-j', '8'], check=True)
        libraries.append(str(build / 'libunicorn.a'))
    (root / 'lib').mkdir(exist_ok=True)
    subprocess.run(['xcrun', 'lipo', '-create', *libraries, '-output', str(root / 'lib/libunicorn.a')], check=True)
    resources = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'SAPAssets'
    resources.mkdir(parents=True, exist_ok=True)
    for name in ASSETS:
        shutil.copy2(assets / name, resources / name)
    licenses = Path(os.environ['SRCROOT']) / 'Resources/Licenses'
    for path in licenses.glob('*.txt'):
        shutil.copy2(path, resources / path.name)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'error: SAP preparation failed: {error}', file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Pack the proprietary files pulled from the user's own device into an overlay tarball for a prebuilt root filesystem.

The published images contain no vendor files; install.sh builds this overlay on the host and android-install.sh
unpacks it over the system. The layout matches rootfs/assemble.sh and openwrt/build-rootfs.sh:
  firmware/            -> usr/lib/firmware (Ubuntu) or lib/firmware (OpenWrt)
  android-subset/      -> opt/mu300/android (dev/__properties__ becomes dev-properties)
  android-gpu-subset/  -> opt/mu300/android (files already taken from android-subset win)
"""
import argparse
import io
import os
import tarfile
from pathlib import Path


def add_bytes(tar, arc, data, seen, mode=0o644):
    if arc in seen:
        return
    seen.add(arc)
    info = tarfile.TarInfo(arc)
    info.size, info.mode, info.uid, info.gid, info.uname, info.gname = len(data), mode, 0, 0, 'root', 'root'
    tar.addfile(info, io.BytesIO(data))


def add_dir(tar, arc, seen, keep):
    """directory entries for arc, but none for its first `keep` components: those exist in the system already, and
    an entry for one of them could replace it - Ubuntu's lib is a link to usr/lib"""
    parts = arc.split('/')
    for i in range(keep + 1, len(parts) + 1):
        d = '/'.join(parts[:i])
        if d in seen:
            continue
        seen.add(d)
        info = tarfile.TarInfo(d)
        info.type, info.mode, info.uid, info.gid, info.uname, info.gname = tarfile.DIRTYPE, 0o755, 0, 0, 'root', 'root'
        tar.addfile(info)


def add_kernel_bundle(tar, bundle: Path, os_name, seen):
    """the modules of another kernel (an unpacked mu300-kernel-6.18.tar.gz), laid out as mu300-update installs
    them: Ubuntu under lib/modules/<release>/extra (depmod on the device indexes them), OpenWrt flat (it loads
    them by path)"""
    krel = (bundle / 'kernel.release').read_text().strip()
    kos = sorted((bundle / 'modules').glob('*.ko'))
    # the real path: in Ubuntu lib is a link to usr/lib, in OpenWrt a directory
    parent = 'usr/lib/modules' if os_name == 'ubuntu' else 'lib/modules'
    base = f'{parent}/{krel}'
    sub = f'{base}/extra' if os_name == 'ubuntu' else base
    add_dir(tar, sub, seen, keep=len(parent.split('/')))
    for ko in kos:
        add_bytes(tar, f'{sub}/{ko.name}', ko.read_bytes(), seen)
    if os_name == 'ubuntu':
        for f in ('modules.builtin', 'modules.builtin.modinfo'):
            if (bundle / f).is_file():
                add_bytes(tar, f'{base}/{f}', (bundle / f).read_bytes(), seen)
        # the index (modules.dep): wifi-start runs depmod early in every boot
        add_bytes(tar, f'{base}/modules.order', b'', seen)
    return krel, len(kos)


def add_tree(tar, src: Path, dest: str, seen: set, rename=None):
    for root, dirs, files in os.walk(src, followlinks=False):
        dirs.sort()
        rel_root = Path(root).relative_to(src)
        entries = [(d, True) for d in dirs] + [(f, False) for f in sorted(files)]
        # symlinks to directories show up in dirs but must be stored as links
        for name, _ in entries:
            path = Path(root) / name
            rel = (rel_root / name).as_posix()
            if rename:
                rel = rename(rel)
                if rel is None:
                    continue
            arc = f'{dest}/{rel}'
            if arc in seen:
                continue
            seen.add(arc)
            info = tar.gettarinfo(str(path), arcname=arc)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            if info.isfile():
                with open(path, 'rb') as f:
                    tar.addfile(info, f)
            else:
                tar.addfile(info)
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--os', required=True, choices=['ubuntu', 'openwrt'])
    ap.add_argument('--firmware', type=Path)
    ap.add_argument('--android-subset', type=Path, required=True)
    ap.add_argument('--gpu-subset', type=Path)
    ap.add_argument('--kernel-bundle', type=Path,
                    help='unpacked mu300-kernel-6.18.tar.gz: its modules go into the system too')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()

    def android(rel):
        # the property area snapshot moves out of dev/ (a devtmpfs is mounted there on the device)
        if rel == 'dev/__properties__' or rel.startswith('dev/__properties__/'):
            return 'dev-properties' + rel[len('dev/__properties__'):]
        if rel == 'dev' or rel.startswith('dev/'):
            return None
        return rel

    def gpu(rel):
        return None if rel == 'dev' or rel.startswith('dev/') else rel

    seen = set()
    with tarfile.open(a.out, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
        if a.firmware and a.firmware.is_dir():
            add_tree(tar, a.firmware, 'usr/lib/firmware' if a.os == 'ubuntu' else 'lib/firmware', seen)
        add_tree(tar, a.android_subset, 'opt/mu300/android', seen, android)
        if a.gpu_subset and a.gpu_subset.is_dir():
            add_tree(tar, a.gpu_subset, 'opt/mu300/android', seen, gpu)
        if a.kernel_bundle:
            krel, n = add_kernel_bundle(tar, a.kernel_bundle, a.os, seen)
            print(f'{a.out}: {n} modules for {krel}')
    print(f'{a.out}: {len(seen)} entries')


if __name__ == '__main__':
    main()

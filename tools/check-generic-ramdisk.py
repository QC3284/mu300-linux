#!/usr/bin/env python3
"""Gate a generic boot-ramdisk segment against init/file skew.

Class of bug this catches (2026-10-30, kernel #73 test): the generic init
dot-sources /etc/mu300-storage.sh, which lives in NEWER device segments only.
On a kernel-only update the merged ramdisk (old device segment + new generic
segment) lacked the file, PID 1 exited 2, the kernel panicked
"Attempted to kill init! exitcode=0x00000200", and LK fell back to Android
after 5 failed boots.

usage: check-generic-ramdisk.py RAMDISK_GENERIC_LZ4 [BOOT_IMAGE]

  RAMDISK_GENERIC_LZ4  the ramdisk-generic.lz4 of a kernel bundle
  BOOT_IMAGE           optional released full boot image (boot-linux.img,
                       header v4) whose ramdisk is the device segment of the
                       same release

RULES
  A (hard, no allowlist): every path the generic init dot-sources ('. PATH'),
     runs with 'sh PATH' or execs ('exec PATH') must exist INSIDE the generic
     segment itself. The device segment is unknown at bundle-build time, so
     the generic segment must carry its own executable dependencies.
  B (hard when BOOT_IMAGE is given): every other absolute /etc/ path the init
     references must exist in the generic segment or in the boot image's
     ramdisk, minus a small documented allowlist of paths the init itself
     writes at runtime or reads guarded (cat 2>/dev/null with fallback).
     Without BOOT_IMAGE, rule B is skipped with a warning (rule A still runs).

Exit: 0 pass, 1 violation, 2 usage error.
"""
import argparse
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Runtime-written / guarded-read /etc/ paths, with evidence:
#   etc/mu300-device           init: DEVICE=$(cat /etc/mu300-device 2>/dev/null);
#                              only full-image builds write it (generic mode
#                              forbids --device); init falls back to the
#                              device-tree guess.
#   etc/mu300-desktop-root-mode  init: case $(cat ... 2>/dev/null); runtime
#                              marker written by the desktop installer.
#   etc/udhcpd.conf            init writes it itself: cat > /etc/udhcpd.conf.
ALLOWLIST = {
    'etc/mu300-device',
    'etc/mu300-desktop-root-mode',
    'etc/udhcpd.conf',
}


def lz4_to_file(src: Path, dst: Path) -> None:
    if shutil.which('lz4'):
        r = subprocess.run(['lz4', '-d', '-f', str(src), str(dst)],
                           capture_output=True)
        if r.returncode == 0:
            return
        sys.exit(f'{src}: lz4 -d failed: '
                 f'{r.stderr.decode(errors="replace").strip()}')
    sys.exit('lz4 not found: needed to decompress the ramdisk segment')


def cpio_files(cpio: bytes):
    """Yield (name, data) for every regular file in a newc cpio archive."""
    i = 0
    while True:
        hdr = cpio[i:i + 110]
        if len(hdr) < 110 or hdr[:6] != b'070701':
            sys.exit('cpio archive is not newc (070701)')
        fields = [int(hdr[o:o + 8], 16) for o in range(6, 110, 8)]
        # newc order: ino, mode, uid, gid, nlink, mtime, filesize,
        # devmajor, devminor, rdevmajor, rdevminor, namesize, check
        mode, filesize, namesize = fields[1], fields[6], fields[11]
        i += 110
        name = cpio[i:i + namesize - 1].decode(errors='replace')
        if name == 'TRAILER!!!':
            return
        # the writer pads the whole header+name to 4 bytes; the 110-byte
        # header is 2 mod 4, so this is NOT just round_up(namesize)
        i += ((110 + namesize + 3) & ~3) - 110
        data = cpio[i:i + filesize]
        i += (filesize + 3) & ~3
        if mode & 0o170000 == 0o100000:  # regular file
            yield name, data


def segment_map(lz4_path: Path) -> dict:
    with tempfile.TemporaryDirectory() as td:
        raw = Path(td) / 'ram.cpio'
        lz4_to_file(lz4_path, raw)
        data = raw.read_bytes()
    return {n: d for n, d in cpio_files(data)}


def boot_ramdisk_map(boot_image: Path) -> dict:
    base = boot_image.read_bytes()
    if base[:8] != b'ANDROID!' or struct.unpack_from('<I', base, 40)[0] != 4:
        sys.exit(f'{boot_image}: not an Android boot image header v4')
    ksz = struct.unpack_from('<I', base, 8)[0]
    rsz = struct.unpack_from('<I', base, 12)[0]
    off = 4096 + ((ksz + 4095) // 4096) * 4096
    seg = base[off:off + rsz]
    if seg[:4] != bytes.fromhex('02214c18'):
        sys.exit(f'{boot_image}: ramdisk segment has no LZ4 legacy magic')
    with tempfile.TemporaryDirectory() as td:
        lz = Path(td) / 'dev.lz4'
        lz.write_bytes(seg)
        return segment_map(lz)


def init_refs(init: bytes):
    text = init.decode(errors='replace')
    hard = []
    for m in re.finditer(r'(?:^|[^\w./-])(?:\.|source)\s+(/[^\s;]+)', text,
                         re.M):
        hard.append(('dot-source', m.group(1)))
    for m in re.finditer(r'\bsh\s+(/[^\s;]+)', text):
        hard.append(('sh', m.group(1)))
    for m in re.finditer(r'\bexec\s+(/[^\s;]+)', text):
        hard.append(('exec', m.group(1)))
    etc = set()
    for m in re.finditer(r'[^\w./-](/(?:etc)/[\w-]+(?:\.[\w-]+)*)', text):
        nxt = text[m.end():m.end() + 1]
        if nxt == '$':  # parameterized path (etc/module-order-$DEVICE)
            continue
        etc.add(m.group(1)[1:])
    return hard, etc


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('ramdisk', type=Path)
    ap.add_argument('boot_image', nargs='?', type=Path)
    a = ap.parse_args()
    if not a.ramdisk.is_file():
        sys.exit(f'{a.ramdisk}: not a file')

    gen = segment_map(a.ramdisk)
    if 'init' not in gen:
        sys.exit(f'{a.ramdisk}: generic segment has no init')
    hard, etc = init_refs(gen['init'])

    failures = []
    for kind, path in hard:
        if path.lstrip('/') not in gen:
            failures.append(f'rule A: init {kind}s {path}, which is NOT in '
                            f'the generic segment')
    if failures:
        print('FAIL ' + a.ramdisk.name)
        for f in failures:
            print('  ' + f)
        return 1

    if a.boot_image:
        dev = boot_ramdisk_map(a.boot_image)
        for p in sorted(etc):
            if p in gen or p in dev or p in ALLOWLIST:
                continue
            failures.append(f'rule B: init references /{p}, which is in '
                            f'neither the generic segment nor the boot image '
                            f'ramdisk')
        if failures:
            print('FAIL ' + a.ramdisk.name)
            for f in failures:
                print('  ' + f)
            return 1
    else:
        print(f'NOTE {a.ramdisk.name}: no boot image given; rule B skipped '
              f'(rule A checked)')

    print(f'PASS {a.ramdisk.name}: {len(hard)} hard refs and {len(etc)} '
          f'/etc/ refs checked')
    return 0


if __name__ == '__main__':
    sys.exit(main())

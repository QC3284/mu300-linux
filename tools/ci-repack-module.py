#!/usr/bin/env python3
"""Regenerate the module payload checks after replacing payload/mu300-openwrt.tar.gz.

Usage: ci-repack-module.py PAYLOAD_DIR
"""
import hashlib
import os
import sys
import tarfile


def sha(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def main(payload):
    tar = os.path.join(payload, 'mu300-openwrt.tar.gz')
    with tarfile.open(tar) as t:
        members = t.getmembers()
        names = {m.name[2:] if m.name.startswith('./') else m.name: m for m in members}
        crit = []
        for member in ('bin/busybox', 'sbin/procd', 'etc/init.d/mu300-vendor'):
            crit.append('%s  %s' % (hashlib.sha256(t.extractfile(names[member]).read()).hexdigest(), member))
        files = [m for m in members if m.isfile()]
    with open(os.path.join(payload, 'rootfs-critical.sha256'), 'w') as f:
        f.write('\n'.join(crit) + '\n')
    with open(os.path.join(payload, 'rootfs.requirements'), 'w') as f:
        f.write('%d %d\n' % (sum(m.size for m in files) // 1024, len(files)))
    lines = []
    for name in ('mu300-openwrt.tar.gz', 'boot-linux.img', 'rootfs.requirements',
                 'rootfs-critical.sha256', 'android-bootchain.sh', 'bootchain.sh'):
        lines.append('%s  %s' % (sha(os.path.join(payload, name)), name))
    with open(os.path.join(payload, 'payload.sha256'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('payload checks regenerated')


if __name__ == '__main__':
    main(sys.argv[1])
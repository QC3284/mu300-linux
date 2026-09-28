#!/usr/bin/env python3
"""compare-ramdisk.py —— 比对两个 ramdisk / boot 镜像的「数据段」,忽略 cpio 元数据差异

用法:
    python3 compare-ramdisk.py <A> <B>

A/B 可以是下面任意一种(自动识别):
    · Android boot 镜像(以 ANDROID! 开头)
    · lz4 压缩的 ramdisk(0x184C2102 / 0x184D2204)
    · 裸 cpio newc 归档(070701)

逐条比对归档里的文件:名称(忽略 './' 前缀)、模式(含文件类型)、大小、内容 sha256
(符号链接的目标字符串也在数据段里,同样会被比出来)。

ino / st_dev / uid / gid / mtime / 条目顺序 是【宿主文件系统】留下的痕迹,每次重建都不同,
只统计、不算失败 —— 原因见 README「为什么重建出的镜像 sha256 和现役不一样」。

退出码:0 = 数据段全部一致(重建内容正确);1 = 有条目缺失或内容差异。
"""
import hashlib, pathlib, struct, subprocess, sys

PAGE = 4096
LZ4_MAGICS = (b'\x02\x21\x4c\x18', b'\x04\x22\x4d\x18')


def to_cpio(path):
    """把任意一种输入变成 cpio 字节流"""
    raw = pathlib.Path(path).read_bytes()
    if raw[:8] == b'ANDROID!':
        ks = struct.unpack_from('<I', raw, 8)[0]
        rs = struct.unpack_from('<I', raw, 12)[0]
        ro = PAGE + ((ks + PAGE - 1) // PAGE) * PAGE
        raw = raw[ro:ro + rs]
        print('  %s: Android boot 镜像 → ramdisk %d 字节(偏移 %d)' % (path, rs, ro))
    if raw[:4] in LZ4_MAGICS:
        out = subprocess.run(['lz4', '-d', '-c'], input=raw, capture_output=True)
        if out.returncode != 0:
            sys.exit('lz4 解压失败: ' + out.stderr.decode('utf-8', 'replace'))
        raw = out.stdout
        print('  %s: lz4 ramdisk → cpio %d 字节' % (path, len(raw)))
    return raw


def parse(raw):
    """解析 cpio newc 归档,返回 {归一化名称: 条目}"""
    ents, off = {}, 0
    while True:
        if raw[off:off + 6] != b'070701':
            break
        f = [int(raw[off + 6 + 8 * i:off + 6 + 8 * (i + 1)], 16) for i in range(13)]
        ino, mode, uid, gid, nlink, mtime, size = f[:7]
        devmaj, devmin, rmaj, rmin, namesize = f[7:12]
        name = raw[off + 110:off + 110 + namesize - 1].decode('utf-8', 'replace')
        do = (off + 110 + namesize + 3) & ~3
        data = raw[do:do + size]
        key = name[2:] if name.startswith('./') else name
        ents[key] = dict(name=name, mode=mode, uid=uid, gid=gid, mtime=mtime, size=size,
                         dev=(devmaj, devmin), rdev=(rmaj, rmin),
                         sha=hashlib.sha256(data).hexdigest(),
                         data=data, ino=ino, order=len(ents))
        off = (do + size + 3) & ~3
        if name == 'TRAILER!!!':
            break
    return ents


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a_path, b_path = sys.argv[1], sys.argv[2]
    print('A =', a_path)
    ea = parse(to_cpio(a_path))
    print('B =', b_path)
    eb = parse(to_cpio(b_path))

    print()
    print('条目数:A=%d  B=%d' % (len(ea), len(eb)))
    only_a = sorted(set(ea) - set(eb))
    only_b = sorted(set(eb) - set(ea))
    if only_a:
        print('★ 只在 A 里:%s' % (only_a[:10] + (['...'] if len(only_a) > 10 else [])))
    if only_b:
        print('★ 只在 B 里:%s' % (only_b[:10] + (['...'] if len(only_b) > 10 else [])))

    common = sorted(set(ea) & set(eb))
    bad = []
    for k in common:
        x, y = ea[k], eb[k]
        if (x['mode'], x['size'], x['sha']) != (y['mode'], y['size'], y['sha']):
            what = []
            if x['mode'] != y['mode']:
                what.append('类型/权限 %o→%o' % (x['mode'], y['mode']))
            if x['size'] != y['size']:
                what.append('大小 %d→%d' % (x['size'], y['size']))
            if x['sha'] != y['sha']:
                what.append('内容不同')
            bad.append((k, what))
    for k, what in bad[:20]:
        print('★ 数据段不一致: %-34s %s' % (k, '; '.join(what)))
    if len(bad) > 20:
        print('  ...(共 %d 条)' % len(bad))

    meta = {}
    for k in common:
        x, y = ea[k], eb[k]
        for field in ('ino', 'uid', 'gid', 'mtime', 'dev', 'rdev'):
            if x[field] != y[field]:
                meta[field] = meta.get(field, 0) + 1
    order_same = [ea[k]['order'] for k in common] == [eb[k]['order'] for k in common]
    print()
    print('数据段不一致条目数: %d' % (len(bad) + len(only_a) + len(only_b)))
    print('条目顺序一致: %s' % ('是' if order_same else '否'))
    print('元数据差异(不计入失败): %s' % (', '.join('%s %d 条' % (k, v) for k, v in sorted(meta.items())) or '无'))
    print()
    if bad or only_a or only_b:
        print('结论:✗ 数据段不一致 —— 重建内容与参考不同,别刷。')
        return 1
    print('结论:✓ 数据段完全一致(元数据/顺序不同属正常,原因见 README)。')
    return 0


if __name__ == '__main__':
    sys.exit(main())

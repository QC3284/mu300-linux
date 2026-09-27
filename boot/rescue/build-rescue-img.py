#!/usr/bin/env python3
import struct, pathlib, hashlib

SRC = pathlib.Path('/home/qc233/zte/mu300-work/bootb-live.img')
RAM = pathlib.Path('/tmp/new.ramdisk.lz4')
OUT = pathlib.Path('/home/qc233/zte/mu300-work/bootb-rescue.img')

d = bytearray(SRC.read_bytes())
ram = RAM.read_bytes()
print('原镜像:', len(d), '字节')
print('新 ramdisk:', len(ram), '字节')

# 解析头部确认参数
kernel_size  = struct.unpack_from('<I', d, 8)[0]
old_ram_size = struct.unpack_from('<I', d, 12)[0]
print('头部: kernel_size=%d ramdisk_size=%d' % (kernel_size, old_ram_size))

PAGE = 4096
ro = PAGE + ((kernel_size + PAGE - 1)//PAGE)*PAGE
print('ramdisk 偏移:', ro)

# ① 把新 ramdisk 写进去
d[ro:ro+len(ram)] = ram
# ② 原本 ramdisk 的尾部残留要清零吗? 不用 —— 头部的 size 决定读多少,但为干净起见清掉多余部分
if len(ram) < old_ram_size:
    d[ro+len(ram):ro+old_ram_size] = b'\x00' * (old_ram_size - len(ram))
# ③ ★ 更新头部的 ramdisk_size ★
struct.pack_into('<I', d, 12, len(ram))

OUT.write_bytes(bytes(d))
print()
print('已写出:', OUT, len(d), '字节')
print('sha256:', hashlib.sha256(bytes(d)).hexdigest())
print()
# 复验
chk = OUT.read_bytes()
print('=== 复验 ===')
print('  magic      :', chk[:8])
print('  ramdisk_size:', struct.unpack_from('<I', chk, 12)[0], '(应 =', len(ram), ')')
r2 = chk[ro:ro+len(ram)]
print('  ramdisk 前 4 字节:', r2[:4].hex(), '(应 02214c18)')
print('  ramdisk 完整:', r2 == ram)

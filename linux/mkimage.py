#!/usr/bin/env python3
"""Assemble a flat RAM image: kernel at 0, device tree and boot stub near the top.
    mkimage.py <vmlinux.bin> <dtb> <boot.bin> <out.bin> [dtb_addr] [boot_addr]"""
import sys
k, d, b, out = sys.argv[1:5]
dtb_addr = int(sys.argv[5], 0) if len(sys.argv) > 5 else 0x01E00000
boot_addr = int(sys.argv[6], 0) if len(sys.argv) > 6 else 0x01F00000
kern, dtb, boot = open(k, "rb").read(), open(d, "rb").read(), open(b, "rb").read()
assert len(kern) <= dtb_addr and dtb_addr + len(dtb) <= boot_addr
img = bytearray(boot_addr + len(boot))
img[0:len(kern)] = kern
img[dtb_addr:dtb_addr + len(dtb)] = dtb
img[boot_addr:] = boot
open(out, "wb").write(img)
print(f"kernel {len(kern)} bytes, dtb {len(dtb)} @ {dtb_addr:#x}, boot stub @ {boot_addr:#x}")

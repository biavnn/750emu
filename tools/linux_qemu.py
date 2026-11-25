#!/usr/bin/env python3
"""Run the g3core Linux image on QEMU's emulated 750 (machine "40p") as a
reference: same kernel binary and init, device tree with the 40p's UART.

    linux_qemu.py <linux-build-out-dir> <console-log> [timeout_s]
"""
import os, re, subprocess, sys, tempfile, time

out, log = sys.argv[1], sys.argv[2]
timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 120
ser = tempfile.mktemp(prefix="g3ser")
p = subprocess.Popen(
    ["qemu-system-ppc", "-M", "40p", "-cpu", "750", "-m", "128", "-display", "none", "-monitor", "none",
     "-serial", f"file:{ser}",
     "-device", f"loader,file={out}/vmlinux.bin,addr=0,force-raw=on",
     "-device", f"loader,file={out}/g3core-qemu40p.dtb,addr=0x01E00000,force-raw=on",
     "-device", f"loader,file={out}/boot-qemu40p.elf,cpu-num=0"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
rc, text, t0 = 124, "", time.time()
while time.time() - t0 < timeout and p.poll() is None:
    time.sleep(0.2)
    if os.path.exists(ser):
        text = open(ser, errors="replace").read()
        m = re.search(r"<<EXIT (-?\d+)>>", text)
        if m:
            time.sleep(1.0)                      # let the power-off messages arrive
            text = open(ser, errors="replace").read()
            rc = int(m.group(1)) & 0xFF
            break
p.kill(); p.wait()
if os.path.exists(ser): os.remove(ser)
open(log, "w").write(text)
sys.exit(rc)

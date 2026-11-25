#!/usr/bin/env python3
"""Run a bare-metal ELF on QEMU's emulated PowerPC 750 (machine "40p") and
capture its UART output. The program ends by printing "<<EXIT n>>".

    qemu_sys.py prog.elf out.txt   -> exit status n (or 124 on timeout)
"""
import os, re, subprocess, sys, tempfile, time

elf, out = sys.argv[1], sys.argv[2]
timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 30
ser = tempfile.mktemp(prefix="g3ser")
p = subprocess.Popen(
    ["qemu-system-ppc", "-M", "40p", "-cpu", "750", "-display", "none", "-monitor", "none",
     "-serial", f"file:{ser}", "-device", f"loader,file={elf},cpu-num=0"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
rc, text, t0 = 124, "", time.time()
while time.time() - t0 < timeout and p.poll() is None:
    time.sleep(0.05)
    if os.path.exists(ser):
        text = open(ser, errors="replace").read()
        m = re.search(r"\n<<EXIT (-?\d+)>>\n", text)
        if m:
            rc, text = int(m.group(1)) & 0xFF, text[:m.start()]
            break
p.kill()
p.wait()
if os.path.exists(ser):
    os.remove(ser)
open(out, "w").write(text)
sys.exit(rc)

#!/usr/bin/env bash
# Build the g3core Linux test image.
#   linux/build.sh <kernel-source-dir> <output-dir>
# Produces <out>/linux-sim.bin (for the RTL simulator) and the pieces to run
# the same kernel on QEMU's 750 (see tools/linux_qemu.sh).
set -euo pipefail
KSRC=$(realpath "$1"); OUT=$(realpath -m "$2"); HERE=$(cd "$(dirname "$0")" && pwd)
CROSS=${CROSS:-powerpc-linux-gnu-}
mkdir -p "$OUT/kbuild"

# 1. user space
${CROSS}gcc -Os -mcpu=750 -msoft-float -ffreestanding -fno-builtin -fno-stack-protector -fno-pie \
    -nostdlib -static -no-pie -Wl,--build-id=none -o "$OUT/init" "$HERE/init.c" -lgcc
sed "s|@INIT@|$OUT/init|" "$HERE/initramfs.list" > "$OUT/initramfs.list"

# 2. platform support (idempotent)
P=$KSRC/arch/powerpc/platforms/embedded6xx
cp "$HERE/g3core.c" "$P/g3core.c"
grep -q G3CORE "$P/Kconfig" || cat >> "$P/Kconfig" <<'KC'

config G3CORE
	bool "g3core soft PowerPC 750"
	depends on EMBEDDED6xx
	select PPC_UDBG_16550
	help
	  Minimal device-tree platform for the g3core soft CPU.
KC
grep -q G3CORE "$P/Makefile" || echo 'obj-$(CONFIG_G3CORE)		+= g3core.o' >> "$P/Makefile"

# 3. kernel
MK="make -C $KSRC O=$OUT/kbuild ARCH=powerpc CROSS_COMPILE=$CROSS"
if [ ! -f "$OUT/kbuild/.config" ]; then
    $MK tinyconfig >/dev/null
    sed "s|@LIST@|$OUT/initramfs.list|" "$HERE/g3core.config" > "$OUT/g3core.config"
    (cd "$OUT/kbuild" && "$KSRC/scripts/kconfig/merge_config.sh" -m .config "$OUT/g3core.config" >/dev/null)
    $MK olddefconfig >/dev/null
fi
$MK -j"$(nproc)" vmlinux
${CROSS}objcopy -O binary "$OUT/kbuild/vmlinux" "$OUT/vmlinux.bin"

# 4. device trees, boot stub, images
for t in sim qemu40p; do dtc -q -I dts -O dtb -o "$OUT/g3core-$t.dtb" "$HERE/g3core-$t.dts"; done
BOOTFLAGS="-nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x01F00000 -Wa,--defsym,DTB_ADDR=0x01E00000 -Wa,--defsym,STACK_ADDR=0x01DFFFF0"
${CROSS}gcc $BOOTFLAGS -o "$OUT/boot.elf" "$HERE/boot.S"
${CROSS}gcc $BOOTFLAGS -Wa,--defsym,QEMU_40P=1 -o "$OUT/boot-qemu40p.elf" "$HERE/boot.S"
${CROSS}objcopy -O binary "$OUT/boot.elf" "$OUT/boot.bin"
python3 "$HERE/mkimage.py" "$OUT/vmlinux.bin" "$OUT/g3core-sim.dtb" "$OUT/boot.bin" "$OUT/linux-sim.bin"

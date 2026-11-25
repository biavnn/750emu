#!/usr/bin/env bash
# Random differential testing.
#   randtest.sh <first_seed> <num_seeds> <insns_per_test>
# For each seed: generate a random program, build it bare-metal and for Linux,
# then check pipeline-vs-QEMU output and pipeline-vs-reference lockstep.
set -u
first=$1; n=$2; len=$3
B=build/rand; mkdir -p $B
CC=powerpc-linux-gnu-gcc
CF="-O2 -Wno-unused-result -mcpu=750 -mbig-endian -fno-pie -Wall -Isw/common -Wa,-mregnames"
pass=0; fail=0
for ((s=first; s<first+n; s++)); do
    t=$B/rand_$s
    python3 tools/gen_random.py $s $len $t.S
    $CC $CF -ffreestanding -fno-builtin -msdata=none -G 0 -Wl,--build-id=none -nostdlib -nostartfiles \
        -static -no-pie -T sw/common/link.ld -o $t.elf sw/common/crt0.S sw/common/bare.c \
        sw/common/tprintf.c sw/rand/rand.c $t.S -lgcc || { echo "BUILD FAIL seed $s"; fail=$((fail+1)); continue; }
    $CC $CF -static -no-pie -o $t.linux sw/common/linux.c sw/common/tprintf.c sw/rand/rand.c $t.S
    powerpc-linux-gnu-objcopy -O binary $t.elf $t.bin && python3 tools/bin2hex.py $t.bin $t.hex
    qemu-ppc -cpu 750 $t.linux > $t.qemu.out 2>&1
    build/sim1/Vsoc_top +img=$t.hex > $t.sim.out 2> $t.sim.log
    build/ls/Vlockstep_top +img=$t.hex > /dev/null 2> $t.ls.log; lsrc=$?
    if cmp -s $t.qemu.out $t.sim.out && [ $lsrc -eq 0 ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); echo "FAIL seed $s (lockstep rc=$lsrc)"
        diff $t.qemu.out $t.sim.out | head -6; head -8 $t.ls.log
    fi
done
echo "---- random: $pass passed, $fail failed (seeds $first..$((first+n-1)), $len insns each)"
[ $fail -eq 0 ]

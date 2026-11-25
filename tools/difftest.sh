#!/usr/bin/env bash
# Differential test: each program runs on the RTL simulator and under QEMU
# (as a Linux-user binary built from the same source). Output must match byte-for-byte.
#   difftest.sh <sim> <swdir> "<qemu cmd>" test1 test2 ...
set -u
SIM=$1; SW=$2; QEMU=$3; shift 3
pass=0; fail=0
for t in "$@"; do
    $SIM +img=$SW/$t.hex +max_cycles=20000000 >"$SW/$t.sim.out" 2>"$SW/$t.sim.log"; simrc=$?
    $QEMU "$SW/$t.linux" >"$SW/$t.qemu.out" 2>&1; qrc=$?
    stats=$(grep -o 'cycles=.*' "$SW/$t.sim.log" | head -1)
    if [ $simrc -eq $qrc ] && cmp -s "$SW/$t.sim.out" "$SW/$t.qemu.out"; then
        printf "PASS  %-8s %s\n" "$t" "$stats"; pass=$((pass+1))
    else
        printf "FAIL  %-8s (sim rc=%d, qemu rc=%d)\n" "$t" $simrc $qrc; fail=$((fail+1))
        diff "$SW/$t.qemu.out" "$SW/$t.sim.out" | head -20
        tail -5 "$SW/$t.sim.log"
    fi
done
echo "---- $pass passed, $fail failed"
[ $fail -eq 0 ]

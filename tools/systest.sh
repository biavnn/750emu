#!/usr/bin/env bash
# Supervisor-mode tests: same source built for the g3core SoC and for QEMU's
# 40p machine. Checks pipeline vs QEMU, reference vs QEMU, and lockstep.
#   systest.sh <builddir> test1 ...
set -u
B=$1; shift
pass=0; fail=0
for t in "$@"; do
    python3 tools/qemu_sys.py $B/$t.q.elf $B/$t.qemu.out; qrc=$?
    ok=1
    for c in 0 1; do
        build/sim$c/Vsoc_top +img=$B/$t.hex +max_cycles=20000000 >$B/$t.sim$c.out 2>$B/$t.sim$c.log; rc=$?
        if [ $rc -ne $qrc ] || ! cmp -s $B/$t.sim$c.out $B/$t.qemu.out; then
            ok=0; echo "FAIL  $t core$c vs QEMU (sim rc=$rc, qemu rc=$qrc)"
            diff $B/$t.qemu.out $B/$t.sim$c.out | head -20
        fi
    done
    build/ls/Vlockstep_top +img=$B/$t.hex +max_cycles=20000000 >/dev/null 2>$B/$t.ls.log; lrc=$?
    if [ $lrc -ne $qrc ]; then ok=0; echo "FAIL  $t lockstep (rc=$lrc)"; head -14 $B/$t.ls.log; fi
    if [ $ok -eq 1 ]; then printf "PASS  %-8s %s\n" "$t" "$(grep -o 'lockstep: .*' $B/$t.ls.log)"; pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "---- $pass passed, $fail failed"
[ $fail -eq 0 ]

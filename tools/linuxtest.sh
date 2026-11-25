#!/usr/bin/env bash
# Boot the Linux image three ways and compare what user space printed.
#   linuxtest.sh <linux-out-dir> <pipeline sim> <lockstep sim>
set -u
OUT=$1; SIM=$2; LS=$3
L=build/linuxtest; mkdir -p $L
fail=0
python3 tools/linux_qemu.py $OUT $L/qemu.log 120; qrc=$?
tr -d '\r' < $L/qemu.log | grep -E '^(init:|<<EXIT)' > $L/qemu.init
echo "QEMU 750:  rc=$qrc, $(grep -c . $L/qemu.log) console lines"

$SIM +bin=$OUT/linux-sim.bin +max_cycles=2000000000 > $L/sim.log 2> $L/sim.err; src=$?
tr -d '\r' < $L/sim.log | grep -E '^(init:|<<EXIT)' > $L/sim.init
echo "pipeline:  rc=$src, $(grep -c . $L/sim.log) console lines, $(grep -o 'cycles=.*CPI=[0-9.]*' $L/sim.err)"
if [ $qrc -ne 0 ] || [ $src -ne 0 ] || ! cmp -s $L/qemu.init $L/sim.init; then
    echo "FAIL  user-space output differs or a run failed"; diff $L/qemu.init $L/sim.init | head; tail -3 $L/sim.log; fail=1
fi
grep -qE 'Oops|BUG|panic|Unable to handle' $L/sim.log && { echo "FAIL  kernel reported an error"; fail=1; }

$LS +bin=$OUT/linux-sim.bin +max_cycles=2000000000 > /dev/null 2> $L/ls.err; lrc=$?
echo "lockstep:  rc=$lrc, $(grep -o 'lockstep: .*' $L/ls.err)"
[ $lrc -ne 0 ] && { echo "FAIL  lockstep"; head -14 $L/ls.err; fail=1; }
[ $fail -eq 0 ] && echo "PASS  Linux boots to user space and powers off; pipeline matches reference core"
exit $fail

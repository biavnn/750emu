#!/usr/bin/env bash
# Run each test with the reference core and pipeline in lockstep.
#   lockstep.sh <Vlockstep_top> <swdir> test1 test2 ...
set -u
LS=$1; SW=$2; shift 2
pass=0; fail=0
for t in "$@"; do
    $LS +img=$SW/$t.hex +max_cycles=20000000 >/dev/null 2>"$SW/$t.ls.log"; rc=$?
    if [ $rc -eq 0 ]; then
        printf "PASS  %-8s %s\n" "$t" "$(grep -o 'lockstep: .*' "$SW/$t.ls.log")"; pass=$((pass+1))
    else
        printf "FAIL  %-8s (rc=%d)\n" "$t" $rc; fail=$((fail+1)); head -20 "$SW/$t.ls.log"
    fi
done
echo "---- $pass passed, $fail failed"
[ $fail -eq 0 ]

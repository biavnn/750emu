#!/usr/bin/env bash
# Set up a fresh Ubuntu/Debian machine for g3core development and verify it.
#
#   tools/setup.sh            install tools, build the simulators, run the test suite
#   tools/setup.sh --linux    also fetch the kernel source, build the Linux image and boot it
#   tools/setup.sh --no-install   skip apt (tools already present)
#
# Developed with Ubuntu 24.04: Verilator 5.020, GCC 13 powerpc cross-compiler, QEMU 8.2.
# Other versions may work; QEMU's FPU and exception quirks that the tests work
# around (see README) are specific to its 8.2 behaviour.
set -euo pipefail
cd "$(dirname "$0")/.."
LINUX=0; INSTALL=1
for a in "$@"; do
    case $a in
        --linux) LINUX=1 ;;
        --no-install) INSTALL=0 ;;
        *) echo "unknown option $a"; exit 2 ;;
    esac
done

if [ $INSTALL -eq 1 ]; then
    PK="verilator make g++ python3 gcc-powerpc-linux-gnu binutils-powerpc-linux-gnu qemu-user qemu-system-ppc"
    [ $LINUX -eq 1 ] && PK="$PK linux-source flex bison bc device-tree-compiler cpio libssl-dev libelf-dev"
    echo "== installing: $PK"
    sudo apt-get update -qq
    sudo apt-get install -y -qq $PK
fi

echo "== tool versions"
verilator --version
powerpc-linux-gnu-gcc --version | head -1
qemu-ppc --version | head -1
qemu-system-ppc --version | head -1
case "$(verilator --version)" in
    "Verilator 5."*) ;;
    *) echo "warning: Verilator 5.x expected" ;;
esac

echo "== building simulators and tests (a few minutes)"
make -s all 2>&1 | grep -E "Error|error:" || true

echo "== test suite"
make test

echo "== random tests (short run)"
make randtest N=5
make fprandtest N=3 LEN=500

if [ $LINUX -eq 1 ]; then
    SRC=$(ls -d ../linux-source-* 2>/dev/null | head -1 || true)
    if [ -z "$SRC" ]; then
        TB=$(ls /usr/src/linux-source-*.tar.* /usr/src/linux-source-*/linux-source-*.tar.* 2>/dev/null | head -1)
        echo "== unpacking $TB"
        tar xf "$TB" -C ..
        SRC=$(ls -d ../linux-source-* | head -1)
    fi
    echo "== building the Linux image from $SRC (about 10 minutes on 2 cores)"
    linux/build.sh "$SRC" ../linux-build/out > ../linux-build.log 2>&1 || { tail -20 ../linux-build.log; exit 1; }
    make linux-test LINUX_OUT=../linux-build/out
fi
echo "== all good"

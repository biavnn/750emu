# g3core top-level build
#   make            build simulator + all tests
#   make test       run differential tests (sim vs qemu-ppc -cpu 750)
#   make run T=hello  run one test on the pipeline simulator

CROSS   ?= powerpc-linux-gnu-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
QEMU    ?= qemu-ppc -cpu 750

BUILD   := build
TESTS   := $(basename $(notdir $(wildcard sw/tests/*.c)))
SYSTESTS := $(basename $(notdir $(wildcard sw/sys/*.c)))

CFLAGS_COMMON := -O2 -Wno-unused-result -mcpu=750 -mbig-endian -fno-pie -Wall -Isw/common -Wa,-mregnames
CFLAGS_BARE   := $(CFLAGS_COMMON) -ffreestanding -fno-builtin -msdata=none -G 0
LDFLAGS_BARE  := -Wl,--build-id=none -nostdlib -nostartfiles -static -no-pie -T sw/common/link.ld
CFLAGS_LINUX  := $(CFLAGS_COMMON) -static -no-pie

RTL := rtl/ppc_pkg.sv rtl/ppc_fpu.sv rtl/ppc_exec.sv rtl/ppc_mmu.sv rtl/ppc_core.sv rtl/ppc_pipe.sv rtl/soc_top.sv

.PHONY: all sim tests test run clean randtest fprandtest linux-sim linux-test
.SECONDARY:
all: sim tests

# ---------------- simulators ----------------
#   build/sim0/Vsoc_top   single-cycle reference core
#   build/sim1/Vsoc_top   pipeline
#   build/ls/Vlockstep    both, trace-compared
VFLAGS := --cc --exe --build -j 0 -O3 -fno-case -Wall -Wno-fatal
SIM0 := $(BUILD)/sim0/Vsoc_top
SIM1 := $(BUILD)/sim1/Vsoc_top
LS   := $(BUILD)/ls/Vlockstep_top
sim: $(SIM0) $(SIM1) $(LS)

define verilate
	@mkdir -p $(dir $@)
	verilator $(VFLAGS) --top-module $(1) $(2) -Mdir $(dir $@) -o $(notdir $@) \
	    $(abspath $(RTL) $(3)) >$(dir $@)/verilator.log 2>&1 || (cat $(dir $@)/verilator.log; false)
	@grep -E '%Warning' $(dir $@)/verilator.log || true
endef

$(SIM0): $(RTL) sim/tb.cpp
	$(call verilate,soc_top,-GCORE=0,sim/tb.cpp)
$(SIM1): $(RTL) sim/tb.cpp
	$(call verilate,soc_top,-GCORE=1,sim/tb.cpp)
$(LS): $(RTL) rtl/lockstep_top.sv sim/tb_lockstep.cpp
	$(call verilate,lockstep_top,,rtl/lockstep_top.sv sim/tb_lockstep.cpp)

# Linux-capable build of the pipeline: 32 MiB RAM, boots from the stub at 0x01F00000
LSIM := $(BUILD)/linux/Vsoc_top
$(LSIM): $(RTL) sim/tb.cpp
	$(call verilate,soc_top,-GCORE=1 -GMEM_BYTES=33554432 -GRESET_PC=32\'h01F00000,sim/tb.cpp)
LLS := $(BUILD)/linuxls/Vlockstep_top
$(LLS): $(RTL) rtl/lockstep_top.sv sim/tb_lockstep.cpp
	$(call verilate,lockstep_top,-GMEM_BYTES=33554432 -GRESET_PC=32\'h01F00000,rtl/lockstep_top.sv sim/tb_lockstep.cpp)
linux-sim: $(LSIM) $(LLS)

# Boot Linux: QEMU's 750 as reference, then the pipeline, then pipeline vs
# reference core in lockstep. LINUX_OUT is the output directory of linux/build.sh.
LINUX_OUT ?= ../linux-build/out
linux-test: linux-sim
	tools/linuxtest.sh $(LINUX_OUT) $(LSIM) $(LLS)

# ---------------- software ----------------
tests: $(foreach t,$(TESTS),$(BUILD)/sw/$(t).hex $(BUILD)/sw/$(t).linux) \
       $(foreach t,$(SYSTESTS),$(BUILD)/sys/$(t).hex $(BUILD)/sys/$(t).q.elf)

extra_src = $(wildcard sw/tests/$(1).S)
COMMON_BARE  := sw/common/crt0.S sw/common/bare.c sw/common/tprintf.c sw/common/exc.c
COMMON_LINUX := sw/common/linux.c sw/common/tprintf.c

$(BUILD)/sw/%.elf: sw/tests/%.c $(COMMON_BARE) sw/common/link.ld sw/common/tlib.h sw/common/exc.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_BARE) $(LDFLAGS_BARE) -o $@ $(COMMON_BARE) $< $(call extra_src,$*) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/sw/$*.dis

$(BUILD)/sw/%.hex: $(BUILD)/sw/%.elf tools/bin2hex.py
	$(OBJCOPY) -O binary $< $(BUILD)/sw/$*.bin
	python3 tools/bin2hex.py $(BUILD)/sw/$*.bin $@

$(BUILD)/sw/%.linux: sw/tests/%.c $(COMMON_LINUX) sw/common/tlib.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_LINUX) -o $@ $(COMMON_LINUX) $< $(call extra_src,$*)

# supervisor-mode tests: bare-metal for the SoC (.elf/.hex) and for QEMU 40p (.q.elf)
sys_src = sw/sys/$(1).c $(wildcard sw/sys/$(1).S)
$(BUILD)/sys/%.elf: sw/sys/%.c $(COMMON_BARE) sw/common/link.ld sw/common/tlib.h sw/common/exc.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_BARE) $(LDFLAGS_BARE) -o $@ $(COMMON_BARE) $(call sys_src,$*) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/sys/$*.dis
$(BUILD)/sys/%.q.elf: sw/sys/%.c $(COMMON_BARE) sw/common/link.ld sw/common/tlib.h sw/common/exc.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_BARE) -DPLAT_QEMU_40P $(LDFLAGS_BARE) -o $@ $(COMMON_BARE) $(call sys_src,$*) -lgcc
$(BUILD)/sys/%.hex: $(BUILD)/sys/%.elf tools/bin2hex.py
	$(OBJCOPY) -O binary $< $(BUILD)/sys/$*.bin
	python3 tools/bin2hex.py $(BUILD)/sys/$*.bin $@

# ---------------- running ----------------
run: $(SIM1) $(BUILD)/sw/$(T).hex
	$(SIM1) +img=$(BUILD)/sw/$(T).hex

# Differential tests vs QEMU for both cores, then lockstep (pipeline vs reference)
test: all
	@echo "== reference core vs QEMU"; tools/difftest.sh $(SIM0) $(BUILD)/sw "$(QEMU)" $(TESTS)
	@echo "== pipeline vs QEMU";       tools/difftest.sh $(SIM1) $(BUILD)/sw "$(QEMU)" $(TESTS)
	@echo "== lockstep pipeline vs reference"; tools/lockstep.sh $(LS) $(BUILD)/sw $(TESTS)
	@echo "== supervisor tests vs QEMU system (750 on 40p) + lockstep"; tools/systest.sh $(BUILD)/sys $(SYSTESTS)

clean:
	rm -rf $(BUILD)

# Random instruction tests: make randtest [SEED=1] [N=50] [LEN=2000]
SEED ?= 1
N    ?= 50
LEN  ?= 2000
randtest: sim
	tools/randtest.sh $(SEED) $(N) $(LEN)

# Random floating-point tests: make fprandtest [SEED=1] [N=20] [LEN=1500]
fprandtest: sim
	GEN=tools/gen_fprand.py DRV=sw/rand/fprand.c TAG=fprand tools/randtest.sh $(SEED) $(N) $(LEN)

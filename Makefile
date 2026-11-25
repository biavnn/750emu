# g3core top-level build
#   make            build simulator + all tests
#   make test       run differential tests (sim vs qemu-ppc -cpu 750)
#   make run T=hello  run one test on the simulator

CROSS   ?= powerpc-linux-gnu-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
QEMU    ?= qemu-ppc -cpu 750

BUILD   := build
TESTS   := $(basename $(notdir $(wildcard sw/tests/*.c)))

CFLAGS_COMMON := -O2 -Wno-unused-result -mcpu=750 -mbig-endian -fno-pie -Wall -Isw/common -Wa,-mregnames
CFLAGS_BARE   := $(CFLAGS_COMMON) -ffreestanding -fno-builtin -msdata=none -G 0
LDFLAGS_BARE  := -Wl,--build-id=none -nostdlib -nostartfiles -static -no-pie -T sw/common/link.ld
CFLAGS_LINUX  := $(CFLAGS_COMMON) -static -no-pie

RTL := rtl/ppc_core.sv rtl/soc_top.sv
SIM := $(BUILD)/sim/Vsoc_top

.PHONY: all sim tests test run clean
.SECONDARY:
all: sim tests

# ---------------- simulator ----------------
sim: $(SIM)
$(SIM): $(RTL) sim/tb.cpp
	verilator --cc --exe --build -j 0 -O3 -Wall -Wno-fatal --top-module soc_top \
	    -Mdir $(BUILD)/sim -o Vsoc_top $(abspath $(RTL) sim/tb.cpp) >$(BUILD)/verilator.log 2>&1 \
	    || (cat $(BUILD)/verilator.log; false)
	@grep -E '%Warning' $(BUILD)/verilator.log || true

# ---------------- software ----------------
tests: $(foreach t,$(TESTS),$(BUILD)/sw/$(t).hex $(BUILD)/sw/$(t).linux)

extra_src = $(wildcard sw/tests/$(1).S)
COMMON_BARE  := sw/common/crt0.S sw/common/bare.c sw/common/tprintf.c
COMMON_LINUX := sw/common/linux.c sw/common/tprintf.c

$(BUILD)/sw/%.elf: sw/tests/%.c $(COMMON_BARE) sw/common/link.ld sw/common/tlib.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_BARE) $(LDFLAGS_BARE) -o $@ $(COMMON_BARE) $< $(call extra_src,$*) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/sw/$*.dis

$(BUILD)/sw/%.hex: $(BUILD)/sw/%.elf tools/bin2hex.py
	$(OBJCOPY) -O binary $< $(BUILD)/sw/$*.bin
	python3 tools/bin2hex.py $(BUILD)/sw/$*.bin $@

$(BUILD)/sw/%.linux: sw/tests/%.c $(COMMON_LINUX) sw/common/tlib.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_LINUX) -o $@ $(COMMON_LINUX) $< $(call extra_src,$*)

# ---------------- running ----------------
run: $(SIM) $(BUILD)/sw/$(T).hex
	$(SIM) +img=$(BUILD)/sw/$(T).hex

test: all
	@tools/difftest.sh $(SIM) $(BUILD)/sw "$(QEMU)" $(TESTS)

clean:
	rm -rf $(BUILD)

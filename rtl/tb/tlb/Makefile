TB_DIR       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BSC_MMU_ROOT := $(abspath $(TB_DIR)/../../..)
VORTEX_RTL   ?= $(abspath $(BSC_MMU_ROOT)/../..)

VERILATOR ?= verilator

INCDIRS := \
	-I$(BSC_MMU_ROOT)/includes \
	-I$(VORTEX_RTL) \
	-I$(VORTEX_RTL)/libs

# Override port count: make run EXTRA_DEFINES='-DTB_NUM_TLB_PORTS=5'
EXTRA_DEFINES ?= -DTB_NUM_TLB_PORTS=4

SV_SRCS := \
	$(BSC_MMU_ROOT)/includes/mmu_pkg.sv \
	$(BSC_MMU_ROOT)/rtl/common/pseudoLRU.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/tlb_storage.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/pte_perm_check.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/miss_req_fsm.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/request_serialiser.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/eviction_policy.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/l1_tlb.sv \
	$(VORTEX_RTL)/libs/VX_priority_encoder.sv \
	$(VORTEX_RTL)/libs/VX_priority_arbiter.sv \
	$(VORTEX_RTL)/libs/VX_generic_arbiter.sv \
	$(TB_DIR)/top.sv

VERILATOR_COMMON := -sv -DSIMULATION -Wno-TIMESCALEMOD -Wno-INITIALDLY $(EXTRA_DEFINES) $(INCDIRS) \
	$(VORTEX_RTL)/VX_platform.vh $(SV_SRCS) --top-module top

# Waveform: FST (use TRACE_FLAGS=--trace and TRACE_OUT=tlb_tb.vcd for VCD)
TRACE_FLAGS  ?= --trace-fst
TRACE_OUT    ?= tlb_tb.fst

.PHONY: all lint build run clean

all: lint

lint:
	$(VERILATOR) --lint-only $(VERILATOR_COMMON)

build:
	$(VERILATOR) --binary $(TRACE_FLAGS) $(VERILATOR_COMMON)

run: build
	@echo "Writing waves to $(TRACE_OUT) (cwd: $$(pwd))"
	./obj_dir/Vtop +TRACE_OUT=$(TRACE_OUT)

clean:
	rm -rf obj_dir $(TB_DIR)/tlb_tb.fst $(TB_DIR)/tlb_tb.vcd

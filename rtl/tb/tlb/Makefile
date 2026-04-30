TB_DIR       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BSC_MMU_ROOT := $(abspath $(TB_DIR)/../../..)
VORTEX_RTL   ?= $(abspath $(BSC_MMU_ROOT)/../..)

VERILATOR ?= verilator

INCDIRS := \
	-I$(BSC_MMU_ROOT)/includes \
	-I$(VORTEX_RTL) \
	-I$(VORTEX_RTL)/libs

SV_SRCS := \
	$(BSC_MMU_ROOT)/includes/mmu_pkg.sv \
	$(BSC_MMU_ROOT)/rtl/common/pseudoLRU.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/pte_perm_check.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/miss_req_fsm.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/tlb_miss_serialiser.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/eviction_policy.sv \
	$(BSC_MMU_ROOT)/rtl/tlb/l1_tlb.sv \
	$(VORTEX_RTL)/libs/VX_priority_encoder.sv \
	$(VORTEX_RTL)/libs/VX_priority_arbiter.sv \
	$(VORTEX_RTL)/libs/VX_generic_arbiter.sv \
	$(TB_DIR)/top.sv

VERILATOR_COMMON := -sv -DSIMULATION -Wno-TIMESCALEMOD $(INCDIRS) \
	$(VORTEX_RTL)/VX_platform.vh $(SV_SRCS) --top-module top

.PHONY: all lint build run clean

all: lint

lint:
	$(VERILATOR) --lint-only $(VERILATOR_COMMON)

build:
	$(VERILATOR) --binary $(VERILATOR_COMMON)

run: build
	./obj_dir/Vtop

clean:
	rm -rf obj_dir

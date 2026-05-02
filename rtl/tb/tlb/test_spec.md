# L1 TLB Testbench Implementation Specification

## 1) Objective
Implement a directed SystemVerilog testbench for `l1_tlb` that verifies:
- parallel lookup behavior across multiple core ports (`NUM_TLB_PORTS > 2`),
- serialized PTW walk behavior for misses,
- correctness of core<->TLB response signals against a fake VPN->PPN lookup table.

## 2) Scope
In scope:
- Use real `tlb_storage.sv` (no storage stub in TB).
- Leaf-page only testing (normal page case).
- Multi-port mixed traffic: simultaneous hits, simultaneous misses, and queued misses.
- Deterministic PTW/L2 mock with programmable response delay.

Out of scope (for this phase):
- Superpage translation behavior.
- Randomized/constrained-random test generation.
- Performance benchmarking beyond functional sequencing checks.

## 3) DUT and Configuration
Device under test:
- `hw/rtl/mmu/bsc_mmu/rtl/tlb/l1_tlb.sv`

Primary TB configuration:
- `NUM_TLB_PORTS = 4` (default regression case).

Additional regression configurations:
- `NUM_TLB_PORTS = 5`
- Optional stress: `NUM_TLB_PORTS = 8`

Common assumptions:
- `vm_enable = 1` for tested requests unless a test states otherwise.
- Requests remain asserted while miss is unresolved (as expected by TLB interface comments).
- Leaf level only: PTW response `level = LEVELS-1`.

## 4) Testbench Architecture
TB module: `hw/rtl/mmu/bsc_mmu/rtl/tb/tlb/top.sv`

Components:
- Clock/reset generator.
- DUT instance (`l1_tlb`).
- Real `tlb_storage` included through DUT.
- Core request driver per port.
- PTW/L2 mock model.
- Monitors for:
  - `core_tlb_comms_i[*]`
  - `tlb_core_comms_o[*]`
  - `l1_l2_comm_o.req`
  - `l2_l1_comm_i.{ptw_ready,resp,invalidate_tlb}`
- Scoreboard/reference model.
- Assertions and end-of-test checks.

## 5) PTW/L2 Mock Specification
Use an internal static lookup table keyed by `{vpn, asid}`:
- `hit`: whether PTW has a translation for this key.
- `ppn`: expected translated leaf PPN.
- `pte_perms`: permissions bits.
- `pte_a`, `pte_d`.
- `error`.
- `delay_cycles`: response latency after request acceptance.

Mock behavior:
- Accept request only when `l2_l1_comm_i.ptw_ready == 1`.
- On acceptance, schedule exactly one response pulse after `delay_cycles`.
- Response fields must be derived from lookup entry.
- Set `resp.level = LEVELS-1` always in this phase.
- Support ready stalls (`ptw_ready = 0`) to test request persistence/queuing.

## 6) Scoreboard / Reference Rules
Reference state tracks:
- Table-defined translations (source of truth).
- Expected L1-resident translations after PTW fill completion.
- Outstanding miss-walk key (single walk at a time).
- Queue of pending miss keys observed at core side.

Per-cycle checks for each port with `req.valid = 1`:
- Expected miss if key not yet resident in expected L1 state.
- Expected hit if key resident.
- On expected hit, `resp.ppn` must match table-derived PPN.
- `resp.miss` must match expected miss/hit state.

PTW-side checks:
- No more than one in-flight walk accepted at a time.
- No duplicate PTW request for same unresolved key.
- Queued misses eventually generate PTW requests and resolve.

Concurrency check:
- If multiple ports issue same key:
  - all show miss while unresolved,
  - all show hit with same PPN once fill takes effect,
  - transition must occur no later than the cycle after fill write is committed.

## 7) Directed Test Matrix
T0. Reset and idle sanity
- No valid core requests, no PTW traffic.

T1. Single-port miss->walk->fill->hit
- Verify canonical flow and basic table match.

T2. Multi-port simultaneous hits (different keys)
- All selected ports hit in same cycle with correct per-port PPN.

T3. Multi-port simultaneous hits (same key)
- All selected ports hit in same cycle with identical PPN.

T4. Multi-port simultaneous misses (same key)
- Exactly one PTW request generated; all ports resolve to hit after fill.

T5. Multi-port simultaneous misses (different keys)
- PTW requests serialized; all keys eventually resolve correctly.

T6. Mixed hit+miss in same cycle
- Hit ports stay correct while miss ports are serviced serially.

T7. PTW backpressure / stall
- Hold `ptw_ready=0` for several cycles during pending miss.
- Ensure no lost request and no duplicate request generation.

T8. Burst queue drain
- Inject misses faster than PTW response rate.
- Verify queued behavior and final convergence to hits.

## 8) Pass/Fail Criteria
Pass when all are true:
- All directed tests complete without assertion failure.
- Scoreboard reports zero mismatches.
- PTW request count/order matches expected serialization behavior.
- Core-side hit/miss/ppn outputs match table expectations in all checked cycles.

Fail on any:
- PPN mismatch on expected hit.
- Miss/hit mismatch vs expected resident state.
- Duplicate PTW request for unresolved key.
- Missing PTW request for queued unresolved key.
- Non-converging queued misses by end-of-test timeout.

## 9) Implementation Deliverables
- Updated `top.sv` implementing driver, PTW mock, monitors, scoreboard, tests.
- Updated `Makefile` to compile with real `tlb_storage.sv` and TB parameter overrides.
- Optional helper comments in TB for scenario IDs and expected timing.

## 10) Notes
If integration uncovers compile/interface inconsistencies in `tlb_storage.sv`, resolve them first as a prerequisite so the DUT uses the real storage path in simulation.

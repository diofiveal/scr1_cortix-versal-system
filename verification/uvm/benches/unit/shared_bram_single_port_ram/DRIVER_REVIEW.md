# UVM-01 / UVM-02 driver review (IMPLEMENTED, uncompiled)

The independent sequence-side snapshot is published **after** `start_item`
grants the item and **before** `finish_item` hands it to the driver. The driver
clones its accepted item, emits acceptance, drives on a falling edge, then
calls `item_done` exactly once after its interface action. Completion of the
UVM item is distinct from the RAM's later read data or write commit receipt.
The intent audit compares immutable sequence snapshots, driver event copies,
and monitor-observed physical pins; driver event reports alone cannot satisfy
the physical issue check. The existing RAM scoreboard remains responsible for
read data, ticket receipts and scrub correctness.

| Edge | READ/WRITE, hold=1, gap=0 | READ/WRITE, hold=3, gap=0 |
| --- | --- | --- |
| Falling before N | Fetch one item; drive command, address, ticket | Same |
| Rising N | Exactly one physical issue; complete item | Exactly one physical issue; keep item outstanding |
| Falling before N+1 | Drive next item, allowing back-to-back issues | Deassert RD/WR enable |
| Rising N+1 | Next item issues if present | No issue |
| Rising N+2 | Subsequent service proceeds | No issue; complete item |
| Falling before N+3 | Subsequent service proceeds | Next item may be driven |

`gap_cycles` inserts that many idle sampling edges after `item_done`; it is
independent of `hold_cycles`. RESET/INIT keep their level asserted for their
specified `hold_cycles`. WSTRB0 and intentional illegal commands remain one
input sampling edge with **zero** expected normal physical writes/issues.
The fixture does not implement RAM storage or receipt timing.

## Directed UVM component scenarios

Compile `shared_bram_driver_fixture.f` with a UVM-capable simulator and select
`tb_sbm_driver_fixture` as top. Run `+UVM_TESTNAME=sbm_driver_fixture_test`
with each `+SBM_CASE=N`: 0/1 single READ hold 1/3; 2/3 single WRITE hold 1/3;
4 and 5 run 100 back-to-back READ/WRITE; 6 alternates 100 READ/WRITE pairs;
7 uses 1/2/5/20 idle-edge gaps; 8 uses the same address with two tickets;
9 checks WSTRB0, simultaneous RD/WR and X-control. The test checks exact
physical issue counts; cases 4–6/8 check consecutive issue edges and case 7
checks issue spacing. All normal cases require zero intent-audit errors.

For four mutation runs, use `+SBM_CASE=0 +SBM_MUT=1` (MUT-D01: drop READ),
`+SBM_CASE=2 +SBM_MUT=2` (MUT-D02: duplicate WRITE),
`+SBM_CASE=0 +SBM_MUT=3` (MUT-D03: corrupt ticket), and
`+SBM_CASE=0 +SBM_MUT=4` (MUT-D04: complete without READ issue).
Additional directed fault probes use `+SBM_CASE=0 +SBM_MUT=5` (wrong address)
and `+SBM_CASE=2 +SBM_MUT=6` (dropped WRITE).
Each mutation deliberately emits a UVM_ERROR; a failing simulation with the
specific `SBM-INTENT`/`SBM-COUNT` diagnostic is the desired kill evidence.
**None of these simulations has been run in this workspace.** No mutation is
VERIFIED without a retained command, seed, tool version and log.

## Gates and limitations

- UVM-01 / UVM-02: IMPLEMENTED in source, compile and simulation TODO.
- DUT verification: BLOCKED by unavailable approved RTL/pin freeze and UVM
  simulator. The fixture checks UVM components only.
- The existing plan/spec SHA256 mismatch remains unresolved (see README).
- A 64-edge intent acceptance watchdog and an accepted-item completion
  watchdog prevent silent sequencer hangs in the fixture. Longer planned
  service delays require a reviewed bound adjustment.

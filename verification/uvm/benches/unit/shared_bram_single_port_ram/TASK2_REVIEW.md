# TASK 2: monitor, scoreboard and timing review

**Source status:** implementation authored; compilation/simulation/coverage
closure/mutation kills have not been observed. See `TIMING_CONTRACT.md` for
edge N and N+1/N+2 semantics and the unresolved physical pin freeze.

## Reproducible run matrix (requires reviewed RTL and UVM simulator)

Compile `shared_bram_single_port_ram.f` plus the reviewed RTL, define
`SBM_REAL_DUT`, and elaborate `tb_sbm_ram` twice with parameter
`READ_LATENCY=1` and `READ_LATENCY=2`. For **each** elaboration run:

- `+UVM_TESTNAME=sbm_base_test`: masked bytes, snapshot and ordered tickets.
- `+UVM_TESTNAME=sbm_timing_ticket_test`: 100 alternating operations,
  READ→WRITE→READ, WSTRB0→valid WRITE, full 95-bit walking-one/zero,
  all-ones and equal-low32/different-upper tickets.
- `+UVM_TESTNAME=sbm_full_scan_test`: 16,384 independently checked zero
  responses and an exact address bitmap.
- `+UVM_TESTNAME=sbm_address_pattern_test`: write an address-dependent
  pattern to every word and read all words back; this detects data-path
  aliases that an all-zero scan alone cannot expose.
- `+UVM_TESTNAME=sbm_missing_scan_test`: expected negative `SBM-SCAN` on
  deliberately omitted address 7777; this run should report a UVM error.
- `+UVM_TESTNAME=sbm_repeat_init_test` and
  `+UVM_TESTNAME=sbm_illegal_control_test`: scrub concurrency and denial.

`sbm_mutation_probe_test +SBM_MUT_CASE=1..16` selects stimulus for an
**externally injected RTL mutant**. See `task2_mutations.csv` for the fault
definition and the checker expected to reject it. Selection does not mutate
the DUT by itself. A mutation is killed only when the mutant is compiled,
the run produces the expected error, the unmutated baseline passes, and the
full commands, seed, tool version and logs are retained. All 16 rows are
currently BLOCKED: neither the RTL mutant nor a simulator is present here.

## Observable evidence and limits

- `sbm_monitor` samples actual physical enables, address and input ticket
  before N using `pre_cb input #1step`; it samples registered receipts after
  NBA at N. It allocates a new event object for each edge.
- `sbm_scoreboard` snapshots 16,384×32 model memory at a physical READ,
  updates selected byte lanes on physical WRITE, and compares due cycles,
  full-width tickets, data, exact receipt count and INIT address order.
- `sbm_intent_audit` remains connected in `sbm_env`, independently linking
  sequence intent, driver acceptance/completion and actual issue pins. A lost
  READ cannot disappear from the scoreboard's overall verification result.
- INIT addresses 0..16383 and unique write count are checked physically;
  all-zero contents are additionally checked by full readback. A direct
  primitive-level zero WDATA/mask proof is BLOCKED until pins/bind visibility
  is frozen.
- `sbm_coverage` samples observed physical op, address/mask and ticket class
  versus latency. The specified full crosses in SBM-COV-01..05 are still
  incomplete. No numeric coverage percentage or closure is claimed.

The `traceability.csv` preserves all 35 SBM-L2 IDs with planned checker and
coverage IDs, implementation links and current evidence gates. Integration
or physical requirements still BLOCKED: SBM-L2-004, 005, 007, 008, 013,
014, 017, 019, 024, 025, 027, 029, 030, 033, 034, 035. These require
peer reset/isolation evidence, RTL/pin review and/or mapped Vivado reports.

**Actual checks in this workspace:** `git diff --check`, filelist/path and
traceability ID consistency, static source inspection. No UVM-capable
simulator or reviewed RTL source is installed in the workspace. Therefore
latency-1/2 test results, mutation results and a measured coverage report
are unavailable; every claim of VERIFIED remains blocked.

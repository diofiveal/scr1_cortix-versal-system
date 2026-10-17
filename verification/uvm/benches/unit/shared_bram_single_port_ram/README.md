# Shared BRAM single-port RAM unit bench

**Source:** L2 Single-Port RAM v1.2 (review candidate) and VP-SBM-L2-v1.0.
**Implementation:** UVM sources written; RTL pin freeze, compile, simulation,
coverage closure and physical Vivado sign-off remain TODO/BLOCKED as below.

## Composition

- `tb/sbm_ram_if.sv`: physical command/receipt interface, 95-bit default ticket.
- `env/sbm_pkg.sv`: transaction and clock-edge sample types.
- `env/sbm_agent.svh`: active sequencer/driver and passive pin monitor.
- `env/sbm_scoreboard.svh`: independent 16,384-word byte memory, ordered
  issue-edge snapshot/ticket ledger, scrub bitmap and receipt checks.
- `env/sbm_coverage.svh`: coverage sampled from observed physical operations.
- `env/sbm_sequences.svh`, `env/sbm_tests.svh`: directed tests.
- `sva/sbm_ram_sva.sv`: local safety properties and non-vacuity covers.
- `tb/tb_sbm_ram.sv`: DUT pin adapter; elaboration requires real RTL.
- `traceability.csv`, `corner_cases.csv`: 35 L2 IDs and 27 corner cases with
  planned checker/coverage IDs and evidence status.
- `DRIVER_REVIEW.md`, `driver_traceability.csv`: UVM-01/UVM-02 timing,
  component fixture cases, mutations and their current evidence gates.
- `TIMING_CONTRACT.md`, `TASK2_REVIEW.md`, `task2_mutations.csv`,
  `task2_coverage_status.csv`: edge-level contract, new tests, mutation targets,
  planned coverage and evidence gates.
- `tb/tb_sbm_driver_fixture.sv`: independent UVM driver/interface fixture;
  it is not a RAM DUT implementation.

## Compile and run on a UVM-capable simulator

From the repository root, add the simulator's UVM 1.2 package/library and the
reviewed RTL source to `shared_bram_single_port_ram.f`. Define
`SBM_REAL_DUT`, select `tb_sbm_ram` as top, and run each of:

- `+UVM_TESTNAME=sbm_base_test`: mask lanes and read snapshot/ticket ordering.
- `+UVM_TESTNAME=sbm_full_scan_test`: exhaustive 64-KiB zero readback.
- `+UVM_TESTNAME=sbm_missing_scan_test`: expected negative scan with one absent address.
- `+UVM_TESTNAME=sbm_address_pattern_test`: full-array address-dependent readback.
- `+UVM_TESTNAME=sbm_timing_ticket_test`: full-width ticket and back-to-back timing.
- `+UVM_TESTNAME=sbm_repeat_init_test`: repeat INIT and normal attempts during sweep.
- `+UVM_TESTNAME=sbm_unqualified_init_test`: denied scrub without isolation.
- `+UVM_TESTNAME=sbm_illegal_control_test`: simultaneous RD/WR and X command.

Elaborate **twice** with `READ_LATENCY=1` and `READ_LATENCY=2`. Keep exact
commands, tool version, seed, assertion outcomes and logs. A class/test being
present is not evidence of compilation, simulation or verification.

## Scope and open pin-freeze decisions

The specification describes a logical interface and explicitly defers physical
port naming/width freeze. The adapter assumes `ram_issue_ticket_i`,
`SERVICE_TICKET_W`, `init_write_en_o`, `init_commit_o` and the other §2 names.
The same specification also says `ram_service_ticket_i` in §3.4. Confirm the
actual pin name and ticket width before elaboration; change only the adapter
and type parameter as approved. The scoreboard interprets post-NBA registered
write receipt at issue edge N and read result after N+READ_LATENCY. Record an
edge table with the RTL owner if that interface timing is interpreted
differently. Never relax a checker merely to get PASS.

The plan quotes source SHA256 `01eb4d4e501125eef3b78ae358f0d7353d66f71dae076cec3960b1a47d87df52`,
whereas the supplied specification hashes to
`a708cce752f91e6b958ef2017ae123a500f4e1d958dd64fab175e50e650d3024`.
Reconcile the approved source revision before marking any requirement VERIFIED.

`coherent_isolation_proven_i` is a **mocked trusted peer input** at unit level;
this bench cannot establish that the upstream platform certified full fabric
isolation before reset. CPU-only reset, Task reset, owner ACK,
RESULT_CONSUMED, Boot Seal COMMIT, and `FULLY_VALID` are absent from this RAM
pin interface. Their wiring and retention are integration checkers, not unit
pins or fabricated unit transactions.

The logical memory scoreboard cannot prove FPGA block RAM inference, zero INIT
image, ECC configuration, 90-MHz timing, power/resource targets or absence of a
second primitive bypass. These require reviewed synthesis/netlist and routed
Vivado evidence. The UVM simulation covers the behavioral subset of
SBM-L2-001..035; those physical and cross-peer requirements remain BLOCKED until
their separate gates provide evidence.

Functional coverage is a partial implementation of SBM-COV-01, SBM-COV-03
and SBM-COV-05: operation, address class, mask, ticket class and latency are
sampled from physical monitor observations. Required pattern/distance,
isolation-age, reset-distance and full ticket-variation crosses remain TODO. SBM-COV-02 requires
upstream reset/retention signals; SBM-COV-04 requires mapped Vivado evidence.
The CSV coverage IDs name plan targets, not coverage closure. No compile,
simulation, mutation or Vivado result is claimed by these files.

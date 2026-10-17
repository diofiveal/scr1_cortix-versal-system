# TASK 3 — reset and progress review

Status: **IMPLEMENTED in source, not compiled, not simulated, not VERIFIED**. The reviewed L2 v1.2 specification is the contract. This checkout contains no reviewed RAM RTL, UVM simulator or Vivado executable. No mutation outcome or coverage measurement is claimed.

## Changes and checks

| File | Change | Why / check |
| --- | --- | --- |
| `env/sbm_agent.svh` | Independent certificate, reset and init levels; X/Z drivers; fixture-only stuck handshake switch 7 | Stop simultaneous proof/reset; permit directed negative and driver-deadlock probes. Check physical edges with the existing independent monitor. |
| `env/sbm_sequences.svh` | `sbm_supervisor_seq` models certificate history and ordered coherent reset | A supervisor-issued proof must precede reset, then a separate zero-init request. L1 must validate the certificate's actual AXI isolation. |
| `env/sbm_scoreboard.svh` | Qualify reset only on pre-existing certificate, retain pending receipts on unqualified reset, detect early/stray receipts and unsafe scrub | Prevent a reset edge from fabricating its own proof or silently deleting old tickets. Run reset and latency 1/2 traces. |
| `env/sbm_watchdog.svh`, `env/sbm_env.svh`, `env/sbm_intent_audit.svh`, `env/sbm_pkg.sv` | Independent heartbeat, progress and ticket diagnostics, integrated with monitor/intent streams | Bounded failure for monitor silence, stuck item, INIT counter, DONE. Inject `+SBM_DRIVER_FAULT=7`; expect `SBM-PROGRESS`. |
| `env/sbm_resilience_tests.svh`, `tb/tb_sbm_ram.sv` | Reset, stall, negative, seeded stress selectors and driver fault argument | Use manifest commands with RTL and a UVM simulator; inspect logs for `SBM-*`. |
| `regressions/*.csv`, `task3_mutations.csv`, `traceability.csv`, `corner_cases.csv` | Seven sets, 12 mutation hypotheses, updated source trace | Compare actual logs and coverage against expected outcomes before changing status. |

### Reset cases

| ID | Stimulus | Unit observation |
| --- | --- | --- |
| RST-01 | Reset before init | No physical operation or DONE |
| RST-02 | Reset and init without proof | No scrub; fault |
| RST-03 | Pre-reset proof, reset, init | Full sweep, later DONE |
| RST-04 | Renewed proof and reset during sweep | Complete restart, no duplicate address in epoch |
| RST-05 | Renewed reset near address 16383 | No early DONE or stale writes |
| RST-06 | New qualified reset after DONE | Second full sweep |
| RST-07 | Qualified reset after pending latency-2 READ | Old ticket cancellation only under proof; no stale receipt |
| RST-08 | Qualified reset following WRITE edge | Receipt ordering and new epoch; sub-edge issue-to-post-NBA injection remains **BLOCKED** with serial agent |
| RST-09 | Repeat INIT without new certificate | No new physical sweep |
| RST-10 | Reinit then WRITE/READ | Normal operation resumes after DONE |
| RST-11 | Extra unqualified reset after READ | Pending ticket retained; mutation probe R01/R02 |

### Stall and negative cases

| ID | Stimulus | Check |
| --- | --- | --- |
| STALL-01/02 | READ/WRITE followed by 100 idle cycles | Exact issue/receipt counts |
| STALL-03/04 | 100 alternating operations / random 0..50 gaps | Issue ledger, byte memory, receipts |
| STALL-05/06 | READ before DONE / WRITE in sweep | No normal physical issue |
| STALL-07 | READ receipt fault probe | Missing receipt checker; needs RTL mutation |
| STALL-08 | Driver item_done hang via switch 7 | Watchdog diagnosis; needs simulator |
| STALL-09 | Never-ending INIT fault probe | Progress watchdog; needs RTL mutation |
| STALL-10 | Service after rearm | Exact WRITE/READ |
| NEG-01..06 | BOTH, WSTRB0, X RD/WR/WSTRB, Z RD/WR/WSTRB | No forbidden physical WE; X/Z fault next edge |
| NEG-07..10 | WRITE during scrub, READ before DONE, repeat INIT, request without isolation | No normal issue or unauthorized scrub |

The RAM agent has no READY/RREADY/BREADY. CPU-only and Task reset, AXI return backpressure and real isolation proof remain **BLOCKED** at L1. Registered write receipt is visible after the issue edge; the serial agent cannot inject a reset in the infinitesimal interval between that edge and the monitor's post-NBA sample. RST-08 is a boundary stimulus, not proof of that specific interval.

## Timeouts and expected outcome

The watchdog reports test name, simulator seed (`+ntb_random_seed` / `+sv_seed`), cycle, outstanding ticket and operation, pending READ/WRITE counts, INIT state and last physical event. It bounds a stalled item, monitor, scrub counter and DONE. Read/write receipts are checked per exact due cycle by the scoreboard; end-of-test queues and intent counts remain mandatory. `wait_initialized()` and sequence polling also have finite limits. Diagnostic richness of those two local limits still depends on the independent watchdog firing first.

Run from repository root with the reviewed RTL on the file list before `tb_sbm_ram.sv`, for example:

```sh
xrun -64bit -uvm -sv -define SBM_REAL_DUT -f verification/uvm/benches/unit/shared_bram_single_port_ram/shared_bram_single_port_ram.f <REVIEWED_RTL_FILE> -top tb_sbm_ram -defparam tb_sbm_ram.READ_LATENCY=2 +UVM_TESTNAME=sbm_resilience_test +SBM_MODE=1 +SBM_CASE=7 +ntb_random_seed=101
```

Adapt RTL source ordering and the simulator's parameter override syntax to the installed tool. Do not classify a mutation as KILLED solely because a baseline test failed. Run the baseline to PASS first, inject exactly one described fault, retain full logs and confirm the named checker fails. All 12 mutation rows currently read **INCONCLUSIVE**. Coverage is **unmeasured**: the source contains address, mask and ticket checks, but no execution report exists.

Open contract question: L2 says an unqualified reset must not erase accepted ticket history, but the exact pin-level behavior of `init_done` under a bare, unqualified wrapper reset needs a reviewed pin/peer freeze. This checker currently requires retained DONE for a previously initialized epoch, following the stronger safe recovery text. Resolve this before claiming a passing RST-11. RST-07's qualified cancellation is deliberately distinct from RST-11's unqualified preservation. No physical zero-data bus is exposed for INIT; exhaustive independent readback remains necessary.

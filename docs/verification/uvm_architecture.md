# UVM verification repository architecture

**Status:** IMPLEMENTED as a repository layout decision.  
**Verification status:** not applicable; no RTL test result is claimed.  
**Scope:** scalable UVM organization for unit, subsystem, system, and future
platform-level verification of the VD100/SCR1 project.

## 1. Design goals

The layout follows six rules:

1. Keep all DUT-specific verification files together in one bench directory.
2. Keep protocol VIP independent of SCR1 addresses, registers, and task semantics.
3. Reuse interfaces, transactions, reference models, and utilities instead of
   copying them between benches.
4. Separate source files from generated simulator output.
5. Preserve direct traceability from each specification requirement to tests,
   checkers, coverage, and run evidence.
6. Allow new modules and higher integration levels without reorganizing existing
   benches.

The earlier cross-cutting proposal placed one DUT's environment, tests,
sequences, assertions, and testbench in separate top-level trees. That approach
was rejected because navigation and ownership become difficult as the number of
DUTs grows. The final layout is target-centric: everything specific to one DUT
is stored below its bench.

## 2. Repository placement

~~~text
scr1_cortix-versal-system/
├── rtl/
├── firmware/
├── linux/
├── scripts/
├── docs/
│   ├── specifications/          # normative specifications, when added
│   └── verification/            # plans and architecture decisions
└── verification/
    └── uvm/
~~~

Production firmware remains under the repository's existing `firmware/`
directory. Verification manifests may reference it; firmware sources are not
duplicated inside UVM.

## 3. Final UVM layout

~~~text
verification/uvm/
├── README.md
├── common/                      # project-wide interfaces, types and utilities
├── vip/                         # reusable protocol VIP
├── rm/                          # independent shared reference models
├── benches/
│   ├── unit/                    # one RTL block or FSM
│   ├── subsystem/               # connected groups of RTL blocks
│   ├── system/                  # complete PL system
│   └── platform/                # future PS/PL/software integration
├── cfg/                         # address maps, widths, timeouts, profiles
├── tools/                       # compile/run/lint/coverage helper scripts
├── regressions/                 # named regression manifests
├── traceability/                # requirements, test plan and run evidence
└── build/                       # generated locally; ignored by Git
~~~

The repository does not track empty directories. A directory is created when it
has a README, manifest, configuration, or source file with a defined owner.

## 4. Shared layers

### 4.1 common

`common/` contains only project-wide infrastructure:

~~~text
common/
├── interfaces/                  # SystemVerilog interfaces and clocking blocks
├── packages/                    # common types, enums and constants
├── transactions/                # project-neutral transaction objects
├── utilities/                   # logging, timeout and comparison helpers
└── common_pkg.sv
~~~

Files move into `common/` only after at least two benches need them. This avoids
premature frameworks and unused abstractions.

### 4.2 vip

`vip/` owns reusable agents for physical protocols:

~~~text
vip/
├── axi4/
├── axi4lite/
├── clock_reset/
├── irq/
└── memory_slave/
~~~

VIP must not know about `TASK_KICK`, SCR1 lifecycle states, the Shared BRAM
address, or application opcodes. A72, SCR1, and DPC are configured instances of
the same source-aware AXI/AXI-Lite VIP rather than copied agents.

A UVM agent represents a physical interface. Multi-interface behavior such as a
host task submission, BRAM ownership session, lifecycle boot, or fatal recovery
is implemented as a virtual sequence, not as a synthetic bus agent.

### 4.3 rm

`rm/` contains independent shared models:

~~~text
rm/
├── register/
├── lifecycle/
├── task/
├── ownership/
├── shared_bram/
├── source_security/
├── application/
└── branch_isa/
~~~

A model must derive expected behavior from the specification. Copying RTL
algorithms or state-update code into a reference model is forbidden.

## 5. Bench levels

| Level | Purpose | Initial targets |
|---|---|---|
| unit | one RTL block/FSM | trusted gateway, BRAM controller, control, lifecycle FSM, task manager, watchdogs |
| subsystem | several connected blocks | Shared BRAM subsystem, SCR1 subsystem, boot subsystem |
| system | complete PL integration | vd100_scr1_top |
| platform | future PS/PL/software integration | A72+SCR1, later A72+R5F+SCR1 and accelerator |

Not every small RTL module automatically receives a standalone bench. The
verification plan decides whether it is verified directly at unit level or
observably and completely through a parent subsystem.

## 6. Standard bench template

Each DUT-specific bench is self-contained:

~~~text
benches/<level>/<dut>/
├── README.md                     # scope, specification, owners, limitations
├── env/
│   ├── <dut>_env.sv
│   ├── <dut>_env_cfg.sv
│   ├── <dut>_virtual_sequencer.sv
│   ├── monitors/
│   ├── predictors/
│   ├── scoreboards/
│   └── coverage/
├── seq/
│   ├── protocol/
│   └── virtual/
├── tests/
│   ├── <dut>_base_test.sv
│   └── <scenario>_test.sv
├── tb/
│   ├── tb_<dut>.sv
│   └── dut_wrapper.sv
├── sva/
│   ├── <dut>_protocol_sva.sv
│   ├── <dut>_invariants_sva.sv
│   └── <dut>_bind.sv
├── cfg/
└── <dut>.f                       # compilation file list
~~~

Subdirectories are added when their first real file is implemented. Placeholder
SystemVerilog code is not committed merely to make the tree look complete.

## 7. Initial bench map

### Unit

- `trusted_axi_gateway`
- `shared_bram_controller`
- `scr1_control`
- `scr1_lifecycle_fsm`
- `scr1_task_manager`
- `task_watchdog`
- `lifecycle_watchdog`

### Subsystem

- `shared_bram_subsystem`
- `scr1_subsystem`
- `scr1_boot_subsystem`
- `trusted_ingress_subsystem`

### System

- `vd100_scr1_top`

### Future platform

- `a72_scr1_platform`
- `a72_r5f_scr1_platform`
- `verification_accelerator`

Names are planning targets, not claims that the corresponding RTL or UVM code
already exists.

## 8. Composition rule

A higher-level environment reuses shared components and selected passive
monitors/predictors from lower levels. It should not blindly instantiate an
entire hierarchy of nested environments when that duplicates agents,
scoreboards, or coverage.

For example, `vd100_scr1_top_env` should contain configured AXI agents,
project monitors, shared predictors, and system scoreboards. It should not
automatically nest complete gateway, Shared BRAM, and SCR1 subsystem
environments inside one another.

## 9. Configuration

`cfg/` stores declarative project-level data:

- address maps;
- AXI widths and outstanding limits;
- trusted source encodings;
- watchdog and stage timeout defaults;
- memory ABI revisions;
- simulator profiles;
- active/passive agent profiles.

DUT-specific overrides stay in `benches/<level>/<dut>/cfg/`. Configuration is
preferred over copied agent classes.

## 10. Simulation and generated data

All generated artifacts go below `verification/uvm/build/`:

~~~text
build/
├── compile/
├── runs/
├── waves/
├── coverage/
└── reports/
~~~

This directory is ignored by Git. A run directory should contain the resolved
configuration, seed, test name, simulator command, transcript, UVM summary, and
coverage reference. A human-authored verification summary may be committed
under `docs/verification/` after review.

## 11. Traceability

`traceability/` contains three controlled tables:

- `requirements.csv`: one row per normative requirement;
- `testplan.csv`: mapping to tests, checkers, and coverage;
- `runs.csv`: evidence from actual executions.

Required status values are:

- `TODO`: not implemented;
- `IMPLEMENTED`: source exists, but verification evidence is incomplete;
- `VERIFIED`: required checks passed and evidence is recorded;
- `BLOCKED`: cannot proceed, with a documented blocker.

No requirement becomes `VERIFIED` merely because code compiles. Compile,
elaboration, simulation execution, checker results, and verification closure are
distinct milestones.

## 12. Naming rules

| Item | Pattern |
|---|---|
| environment | `<dut>_env` |
| environment configuration | `<dut>_env_cfg` |
| base test | `<dut>_base_test` |
| scenario test | `<dut>_<scenario>_test` |
| sequence | `<scenario>_seq` |
| virtual sequence | `<scenario>_vseq` |
| scoreboard | `<domain>_scoreboard` |
| predictor | `<domain>_predictor` |
| coverage component | `<domain>_coverage` |
| assertion module | `<dut>_<group>_sva` |
| file list | `<dut>.f` |

Verification objects also carry stable IDs, for example `TST-TK-001`,
`CHK-INV-001`, and `COV-BR-004`.

## 13. Compile dependency direction

The allowed dependency direction is:

~~~text
common → vip → shared reference models → bench env
       → bench sequences → bench tests → tb top/bind
~~~

Lower layers must not import a bench-specific package. Cyclic package
dependencies are prohibited.

## 14. Growth procedure

To add a DUT:

1. Identify its approved specification and requirement IDs.
2. Decide its level: unit, subsystem, system, or platform.
3. Create `benches/<level>/<dut>/README.md` with scope and interfaces.
4. Reuse existing VIP and reference models before adding new ones.
5. Add only the bench subdirectories required by implemented files.
6. Add its file list and simulator profile.
7. Add requirement/test/checker/coverage mappings.
8. Mark files `IMPLEMENTED` only after creation and review.
9. Mark requirements `VERIFIED` only after retained run evidence.

## 15. Tool-version rule

The current hardware project is based on Vivado/PetaLinux 2023.2. Availability
of Vivado 2025.2 does not by itself approve migration. Simulator/version
profiles must state the version used, and results from different versions must
not be silently combined.

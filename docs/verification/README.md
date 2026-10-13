# Verification documentation

This directory contains the verification strategy, approved verification plans,
requirement traceability rules, and architecture decisions for the UVM
environment.

## Documents

- [UVM directory architecture](uvm_architecture.md)

A specification is the source of truth. RTL behavior must not silently replace
missing or ambiguous requirements. Requirement status is one of `TODO`,
`IMPLEMENTED`, `VERIFIED`, or `BLOCKED`. `VERIFIED` requires retained
evidence from an actual check or simulation run.

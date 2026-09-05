# Scoped-MCP audit

`pnr_32m_scoped_v25_b6.sdc` publishes every active multicycle exception as a
named record in `mcp_audit_groups`.  The independent
`mcp_audit_manifest.json` is the signoff contract: each group must resolve to
at least the declared number of through/endpoint objects and must retain the
declared setup/hold values.

The runner supplies the GF180 FD technology and cell LEFs before loading the
netlist; this is required even for a synthesis-stage audit because OpenROAD
must recognize the standard-cell masters.

Run the audit on the synthesized netlist and then the final routed netlist:

```bash
rtl-test/scripts/run_mcp_audit.sh --stage synth --netlist <synth-netlist> \
  --sdc src/config/pnr_32m_scoped_v25_b6_signoff.sdc \
  --liberty /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_3v00.lib

rtl-test/scripts/run_mcp_audit.sh --stage route --netlist <final-netlist> \
  --spef <final-max-spef> \
  --sdc src/config/pnr_32m_scoped_v25_b6_signoff.sdc \
  --liberty /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_3v00.lib
```

The first clean, reviewed production run is deliberately not accepted by
default.  Review its `mcp_audit_<stage>.evidence` object lists, then run the
same command with `--update-baseline`.  Subsequent runs
fail if the resolved object set changes, an SDC selector becomes empty, or the
OpenROAD log contains `STA-0361`, `STA-0472`, or `no valid objects`.

The audit evidence names every resolved selector object and the paired OpenROAD
log retains JSON `report_checks` paths for each group: max/setup and min/hold,
with a resolved startpoint and endpoint required in each report. This exposes a
fast-changing sibling accidentally swept in by a broad `-through` scope.

The reports identify timing coverage; they do not prove that the RTL hold
protocol is correct. The `proof` field in the manifest names the required
formal/assertion evidence for each group. No MCP-based signoff is complete
until that evidence and this audit both pass.

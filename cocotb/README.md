# cocotb/ — Trouper functional verification

cocotb testbenches for the Trouper top level (`src/top/trouper_top.v`). Self-contained: the
HDL harness and sim models live under `hdl/`, the Python tests under `tests/`, and each test
setup has its own directory with a `Makefile`.

## Layout

```
cocotb/
  trouper_top/     Makefile — SF7–SF12 × BW250/125 integration suite (Icarus)
  trouper_capture/ Makefile — measured-IQ playback through the full chain (Verilator)
  packet_ctrl_fsm/ Makefile — standalone cycle-accurate PCFSM/model suite (Verilator)
  hdl/
    tb_trouper_cocotb.v   — Verilog test harness (TOPLEVEL)
    psram_model.v         — APS6404L PSRAM behavioural model
  tests/
    test_trouper_top.py       — main integration tests + shared helpers
    test_capture_playback.py  — drives trouper_top with a real capture
    test_packet_ctrl_fsm.py   — standalone PCFSM requirement tests
    packet_ctrl_fsm_model.py  — cycle-accurate reusable PCFSM reference model
    iq_capture.py             — capture → 32 MS/s ΣΔ resampling helper
    sweep_captures.py         — batch sweep driver
```

Each Makefile pulls RTL from `../../src/<block>/`, HDL from `hdl/`, and the Python module from
`tests/` (via `PYTHONPATH`). RTL is referenced — never duplicated — so the DUT always matches
`src/`.

## Running

Inside the `hpretl/iic-osic-tools:chipathon26` container (repo at `/foss/designs/lora-mimo`):

```bash
# Full SF/BW integration suite (Icarus)
cd cocotb/trouper_top && make
make TESTCASE=test_sf7_bw250,test_sf7_bw125     # subset

# Standalone packet-control FSM suite
cd cocotb/packet_ctrl_fsm && make

# Measured-IQ playback (Verilator)
cd cocotb/trouper_capture && \
  make CAPTURE_NPY=/foss/designs/lora-mimo/lora-capture/captures/<file>.npy \
       CAPTURE_SF=7 CAPTURE_BW=250 CAPTURE_NSAMP=60000
```

`DESIGN_ROOT` defaults to `/foss/designs/lora-mimo` (the container mount); override it to run
against a different checkout.

## Regression

`run_toplevel_regression_sge.sh` runs **every** suite in this directory as one SGE job:

```bash
export HLAB_SGE_URL=http://nas.home:4783
hqsub --name top_regression --project lora-mimo --cpus 8 --mem 24G \
      /srv/eda/designs/$USER/lora-mimo/cocotb/run_toplevel_regression_sge.sh
```

Two groups, split by what a suite *needs*, not by how much it is trusted:

| Group | Suites | Notes |
|---|---|---|
| `core` (default) | everything self-contained | RTL + `hdl/` only; ~40 suites |
| `capture` | `trouper_capture`, `weight_gen_spi_flow`, `capture_two_packet` | need a measured `.npy` from `$SHARED_DIR/lora-mimo-captures/captures` (read-only in every SGE job); `capture_two_packet` is ~50 min |

Environment: `SUITE_GROUPS=core|capture|all` (default `core` — **not** `GROUPS`, which
bash owns), `SUITES="a b c"` to override the selection entirely, `JOBS=n` to run n
suites concurrently, `DESIGN_ROOT` / `RUN_DIR` / `SHARED_DIR` for the mounts.

The script **fails if a `cocotb/<dir>/Makefile` is in neither group** — add every new
suite to `SUITES_CORE` or `SUITES_CAPTURE` at the top of the script. That check exists
because the previous hand-maintained list had drifted to 20 of 41 suites while still
printing "REGRESSION CLEAN"; two real breakages were sitting in the unrun half
(2026-08-30). A capture suite whose `.npy` mount is absent reports `SKIPPED`, never
`PASSED`, and a skip keeps the run from being reported clean.

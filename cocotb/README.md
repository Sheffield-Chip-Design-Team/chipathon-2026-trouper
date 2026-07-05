# cocotb/ — Trouper functional verification

cocotb testbenches for the Trouper top level (`src/top/trouper_top.v`). Self-contained: the
HDL harness and sim models live under `hdl/`, the Python tests under `tests/`, and each test
setup has its own directory with a `Makefile`.

## Layout

```
cocotb/
  trouper_top/     Makefile — SF7–SF12 × BW250/125 integration suite (Icarus)
  trouper_capture/ Makefile — measured-IQ playback through the full chain (Verilator)
  hdl/
    tb_trouper_cocotb.v   — Verilog test harness (TOPLEVEL)
    psram_model.v         — APS6404L PSRAM behavioural model
  tests/
    test_trouper_top.py       — main integration tests + shared helpers
    test_capture_playback.py  — drives trouper_top with a real capture
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

# Measured-IQ playback (Verilator)
cd cocotb/trouper_capture && \
  make CAPTURE_NPY=/foss/designs/lora-mimo/lora-capture/captures/<file>.npy \
       CAPTURE_SF=7 CAPTURE_BW=250 CAPTURE_NSAMP=60000
```

`DESIGN_ROOT` defaults to `/foss/designs/lora-mimo` (the container mount); override it to run
against a different checkout.

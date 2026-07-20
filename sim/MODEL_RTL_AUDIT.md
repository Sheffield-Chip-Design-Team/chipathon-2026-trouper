# Python Model ↔ RTL Audit

Audited against `src/` at repository HEAD on 2026-07-18.

| RTL block | Python model | Status | Scope / evidence |
|---|---|---|---|
| `decimator/sd_decimator_poly.v` | `models/decimator.py` | Aligned | CIC-3 R=16 → HB1 /2 → HB2 /2, int8 output, fixed R=64, 500 kS/s and BW-driven `sample_shift`. Covered by `tests/test_decimator.py`. |
| `frontend/dc_removal.v` | `models/dc_removal.py:DCRemovalRTL` | Aligned | Q8.5 accumulator, pre-update DC estimate, alpha 2^-5 and int8 I/O match the shipped block. |
| `frontend/sc_detector.v` | `models/sync.py:SchmidlCoxDetector` | Aligned at algorithm/configuration level | Updated in this audit for the single selected SC branch (`BW_CFG.sc_ant_sel`), reset default 0. It is not a cycle-/truncation-exact model of the serial metric engine; those details are RTL/cocotb verified. |
| `combiner/training_acc.v` | `models/training_accumulator.py:training_accumulate_allpairs` | Aligned at arithmetic-window level | All six complex cross-pairs plus four diagonals, training window endpoint, and optional noise window correspond to the register-visible results. Pipeline pacing is intentionally not modeled. Covered by `tests/test_training_allpairs_stress.py`. |
| `combiner/mrc_combiner.v` | `models/receiver.py:nonfft_combine_rtl_int8w` | Aligned | Four int8 complex weights, 18-bit accumulation, arithmetic `>>> (8 - post_gain_shift)` and int8 saturation match RTL. The older Q1.15 helper is explicitly legacy. |
| `remod/sd_remod.v` | `models/converter.py:SigmaDeltaRemodulator(order=3)` | Aligned | Default third-order CIFF coefficients 205/256, 74/256, 11/256 and saturation behavior match deployed RTL. Order 2 remains an analysis-only candidate. |
| `control/packet_ctrl_fsm.v` | — | No Python behavioral model | The 2026-07-12 `ST_ACQ_SETUP` retiming and packet-state changes are control/timing behavior, verified by RTL/cocotb rather than the DSP models. |
| `control/psram_buf_ctrl.v` | — | No Python behavioral model | `sc_ant_sel`, continuous-delay replay, QSPI ownership, and replay error behavior are transaction-level hardware behavior; cocotb is the source of verification. |
| `control/reg_bank.v`, `control/spi_slave.v` | — | No Python behavioral model | Register/SPI semantics are RTL/cocotb-covered. The DSP models consume their effective configuration values. |

The scope boundary is deliberate: `sim/models/` predicts DSP arithmetic and
system behavior; timing-accurate serial engines, PSRAM transactions, and bus
protocols are verified in `cocotb/` against synthesizable RTL.

## Regression commands

```bash
PYTHONPATH=/usr/lib/python3/dist-packages:/usr/lib/python3.12/site-packages \
  python3 sim/gnuradio/check_environment.py

python3 -m pytest -q \
  sim/tests/test_sync.py \
  sim/tests/test_decimator.py \
  sim/tests/test_comb_post_gain.py \
  sim/tests/test_training_allpairs_stress.py \
  sim/tests/test_weight_generation.py
```

# fpga-emul TODO

Open work for the Arty A7-100T LoRa-MIMO emulator, tracking the block-design and
firmware changes that the MISO front-end test PCB requires. The pin constraints
in `vivado/arty_dsp_emul.xdc` have already been re-pinned to the physical board
(see `miso_frontend_pcb_review_2026-07-08.md`, findings 6 & 7); the items
below are the parts that the XDC alone cannot express and still need BD/firmware
rework.

## Block design / firmware re-pin (from PCB review 2026-07-08)

- [x] **External APS6404L PSRAM.** DONE. `fpga_dsp_wrap` gained a
  `USE_EXT_PSRAM` parameter (default 0 = internal BRAM model for sims; the BD
  sets 1). When 1, four IOBUFs bridge trouper_top's SIO_OUT/OE/IN to the
  bidirectional `psram_sio[3:0]`, and `psram_sck`/`psram_ce_n` become output
  pins. BD creates the ports; XDC constrains JA:
  `psram_sck=D12, psram_ce_n=D13, SIO0=A11, SIO1=G13, SIO2=B11, SIO3=K16`.
- [x] **CLK_OUT sampling clock.** DONE. The DSP domain is now clocked from the
  SX1257 CLK_OUT (matching silicon, where IQ_CLK *is* CLK_OUT), not the MMCM.
  `sx_clk_out` port (C15, CLK_OUT_4) → BUFG → `dsp_clk`, feeding fpga_dsp_wrap,
  axi_inj_ctrl, and rst_32m. XDC has the 32 MHz `create_clock` + async
  `set_clock_groups` vs the MMCM domain. MMCM clk_out2 is now unused.
- [x] **remod_i / remod_q.** DONE. Dropped from the BD (no top-level port, no
  constraint); the wrapper still exposes them as unconnected cell pins. Re-add
  a port + pin if a TX/remod path is ever added to the board.
- [ ] **2-bit encoded NSS.** The board decodes chip-select with an on-board
  SN74LVC1G139 (2-to-4) driven by `RFFE_NSS_A0`/`A1`. The BD now builds
  `axi_quad_spi_0` with `C_NUM_SS_BITS=2` (so `ss_io[3:2]` are gone and the
  unconstrained-port warnings are cleared), but it still emits a **one-hot**
  select on the two lines. Rework the BD/firmware to drive a true 2-bit
  **encoded** address into the decoder. `ss_io[0]`=A18 (A0), `ss_io[1]`=B18 (A1).
  - Note: the 1G139 has no enable pin, so it can never deselect all radios
    (review finding 4). If the board is respun with a 1G138/139A that has an
    enable, add an "SPI active" GPIO to the BD too.

## Validation

- [x] **BD builds + validates.** `make vivado_project` (Vivado 2025.2) runs clean:
  `validate_bd_design` passes, 0 errors, 0 critical warnings. The `util_ds_buf`
  BUFG, the `USE_EXT_PSRAM=1` param, the inout `psram_sio` port, and the
  `axi_inj_ctrl` AXI-CDC automation (Clk_slave `/sx_clk_bufg/BUFG_O (32 MHz)`)
  all resolved without error. Remaining warnings are pre-existing/benign.
- [ ] **Synthesis + timing.** `make vivado_synth` — confirm it maps (IOBUFs,
  BUFG on C15) and meets timing on the 32 MHz sample clock. Not yet run.
- [ ] **Reset/bring-up ordering.** rst_32m now releases the DSP domain only once
  CLK_OUT is toggling. Confirm firmware configures the SX1257 (over RFFE SPI,
  100 MHz domain) to start CLK_OUT before expecting any DSP-domain activity.
- [ ] **Scope CLK_OUT_4 edge quality** at C15 (0 Ω) at 32 MHz before trusting
  captures; if marginal, the 200 Ω CLK_OUT_1..3 on JD are the fallback set.
- [ ] Fold the finalized pin map into `HARDWARE_SETUP.md` once verified against a
  physical board.

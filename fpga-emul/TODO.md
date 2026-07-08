# fpga-emul TODO

Open work for the Arty A7-100T LoRa-MIMO emulator, tracking the block-design and
firmware changes that the MISO front-end test PCB requires. The pin constraints
in `vivado/arty_dsp_emul.xdc` have already been re-pinned to the physical board
(see `miso_frontend_pcb_review_2026-07-08.md`, findings 6 & 7); the items
below are the parts that the XDC alone cannot express and still need BD/firmware
rework.

The MISO front-end test board (AFE) design is at
<https://gitlab.com/m0rtal/miso_frontend>.

## Block design / firmware re-pin (from PCB review 2026-07-08)

- [x] **External APS6404L PSRAM.** DONE. `fpga_dsp_wrap` gained a
  `USE_EXT_PSRAM` parameter (default 0 = internal BRAM model for sims; the BD
  sets 1). When 1, four IOBUFs bridge trouper_top's SIO_OUT/OE/IN to the
  bidirectional `psram_sio[3:0]`, and `psram_sck`/`psram_ce_n` become output
  pins. BD creates the ports; XDC constrains JA:
  `psram_sck=D12, psram_ce_n=D13, SIO0=A11, SIO1=G13, SIO2=B11, SIO3=K16`.
- [x] **CLK_OUT sampling clock.** DONE. The DSP domain is now clocked from the
  SX1257 CLK_OUT (matching silicon, where IQ_CLK *is* CLK_OUT), not the MMCM.
  `sx_clk_out` port (**F4, CLK_OUT_2**) → BUFG → `dsp_clk`, feeding fpga_dsp_wrap,
  axi_inj_ctrl, and rst_32m. XDC has the 32 MHz `create_clock` + async
  `set_clock_groups` vs the MMCM domain. MMCM clk_out2 is now unused.
  - Design intent: the ASIC needs only ONE clock. The board exposes all four
    CLK_OUTs so the other three can be measured against this one to prove they
    are phase-locked before committing the single-clock design to silicon. A
    shared TCXO guarantees *frequency* lock (no drift); static inter-chip *phase*
    skew is the open question (set by each SX1257's ÷2^n divider start, which a
    synchronized RFFE_RST would align — but RFFE_RST currently floats, review
    finding 5). See the "Clock-sync measurement harness" item below.
  - Pin choice: F4 is the ONLY one of the four CLK_OUTs on a P-side MRCC pin, so
    it is the only one the FPGA accepts as a single-ended clock. A single-ended
    clock is legal only on the P (master) pin — the dedicated low-skew route to
    the clock buffers is bonded to P; an N pin reaches the clock tree only via
    the differential input buffer, so the placer rejects it (Place 30-876). The
    review's preferred C15 (0 Ω) is N-side and electrically unusable as a clock.
    F4 has 200 Ω series (measure the edge). Pairing (Vivado-verified on this part):
    | CLK_OUT | pin | P/N | P-partner | partner status |
    |---|---|---|---|---|
    | 1 | F3 | N | F4 | = CLK_OUT_2 (our clock) |
    | 2 | **F4** | **P** | F3 | **USE THIS** |
    | 3 | D3 | N | E3 | = Arty 100 MHz oscillator — dead end |
    | 4 | C15 | N | D15 | = JB pin 3, n/c — respin target |
  - **BOARD RESPIN FIX**: move the CLK_OUT_4 net one pin, C15 → D15 (JB pin 3),
    the P-partner of the same L12_15 pair — a P-side MRCC on the 0 Ω JB header,
    so it is both clock-legal *and* clean-edged. (CLK_OUT_3 can't be rescued:
    its P partner E3 is the onboard oscillator, not on a header.)
  - [ ] **Clock-sync measurement harness** (new; de-risks the single-clock ASIC):
    bring F3/D3/C15 in as ordinary SAMPLED inputs (they're fine as data pins,
    only illegal as clocks) and capture them against the F4 dsp_clk. A static
    sampled level ⇒ frequency-locked; a slowly walking pattern ⇒ not locked. For
    phase magnitude, sweep an IDELAY (~78 ps/tap) or MMCM fine phase on the F4
    clock to find each input's edge. Expose lock/phase over the reg/UART path.
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
- [x] **Synthesis + timing.** DONE. `make vivado_synth` (Vivado 2025.2) runs
  synth → impl → bitstream clean, **all timing met**. Sample clock `sx_clk_out`
  (32 MHz on F4): intra-clock setup WNS **+9.98 ns**, hold WHS **+0.022 ns**
  (thin but positive), 0 failing / 13,331 endpoints. `clk_out1` 100 MHz WNS
  +1.37 ns. Util comfortable (LUT 15%, FF 8%, BRAM 15%, DSP 10%, IOB 41/210).
  BUFG on F4 (`system_sx_clk_bufg_0`) + external PSRAM IOBUFs confirmed mapped.
  Bitstream written to `fpga-emul/arty_dsp_emul.bit`.
  - (First impl attempt failed on the C15 N-side clock-pin error; fixed by
    moving the sample clock to the P-side F4 pin, as documented above.)
- [ ] **Reset/bring-up ordering.** rst_32m now releases the DSP domain only once
  CLK_OUT is toggling. Confirm firmware configures the SX1257 (over RFFE SPI,
  100 MHz domain) to start CLK_OUT before expecting any DSP-domain activity.
- [ ] **Scope CLK_OUT_2 edge quality** at F4 (200 Ω) at 32 MHz before trusting
  captures — the 200 Ω series may soften the edge. A board respin to a P-side
  0 Ω pin (D15, see above) would remove this concern.
- [ ] Fold the finalized pin map into `HARDWARE_SETUP.md` once verified against a
  physical board.

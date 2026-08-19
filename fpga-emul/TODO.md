# fpga-emul TODO

Open work for the Arty A7-100T LoRa-MIMO emulator, tracking the block-design and
firmware changes that the MISO front-end test PCB requires. The pin constraints
in `vivado/arty_dsp_emul.xdc` have already been re-pinned to the physical board
(see `miso_frontend_pcb_review_2026-07-08.md`, findings 6 & 7); the items
below are the parts that the XDC alone cannot express and still need BD/firmware
rework.

The MISO front-end test board (AFE) design is at
<https://gitlab.com/m0rtal/miso_frontend>.

## Automatic MRC benchmark (WIP 2026-07-11)

- [x] Enable MicroBlaze hardware MUL, DIV, and barrel shift; keep FPU/caches off.
- [x] Add the 100 MHz `axi_timer_0` benchmark counter at `0x41C0_0000`.
- [x] Port the current 8-iteration fixed-point eigenvector kernel to `sw/main.c`.
- [x] On `IRQ_TRAINING_DONE`, read the 48-byte matrix over the real internal SPI
  path, compute, write Q1.15 weights, commit, clear the IRQ, and calculate
  compute-only plus end-to-end cycle counts.
- [x] Rebuild/P&R: all constraints met (overall WNS +1.341 ns, WHS +0.051 ns),
  bitstream and 28,192-byte ELF generated and programmed successfully.
- [x] Fix the regenerated build's UARTLite AXI stall. Root cause was FPGA AXI
  helper slaves clocked from absent-at-boot SX1257 `CLK_OUT`, which deadlocked
  shared SmartConnect traffic. They now use free-running MMCM `clk_out2`.
  Follow-up hardware tracing found a second cause: the 100 MHz AXI resets had
  been tied permanently inactive, so UART/SPI/Ethernet IP never received a
  configuration-time reset and powered up indeterminately. They are restored to
  `rst_100m/peripheral_aresetn`; firmware also resets the UART FIFOs before boot
  text so MDM-only processor resets remain deterministic.
- [x] Trigger training and capture the first measured `compute` and `total`
  latency figures. Self-trigger benchmark on the Arty reports
  `n_acc=1024`, `compute=3768 cyc`, `total=3792 cyc` at 100 MHz
  (`37.68 us` / `37.92 us`); result added to the SF timing note.

## Block design / firmware re-pin (from PCB review 2026-07-08)

- [x] **External APS6404L PSRAM.** DONE. `fpga_dsp_wrap` gained a
  `USE_EXT_PSRAM` parameter (default 0 = internal BRAM model for sims; the BD
  sets 1). When 1, four IOBUFs bridge trouper_top's SIO_OUT/OE/IN to the
  bidirectional `psram_sio[3:0]`, and `psram_sck`/`psram_ce_n` become output
  pins. BD creates the ports; XDC constrains JA:
  `psram_sck=D12, psram_ce_n=D13, SIO0=A11, SIO1=G13, SIO2=B11, SIO3=K16`.
- [x] **CLK_OUT sampling clock.** DONE. The DSP domain is now clocked from the
  SX1257 CLK_OUT (matching silicon, where IQ_CLK *is* CLK_OUT), not the MMCM.
  `sx_clk_out` port (**F4, CLK_OUT_2**) → BUFG → `dsp_clk`, feeding
  `fpga_dsp_wrap` and `rst_32m`. XDC has the 32 MHz `create_clock` + async
  `set_clock_groups` vs the MMCM domain. MMCM `clk_out2` clocks the FPGA-only
  AXI control helpers so the bus remains usable before `CLK_OUT` starts.
  - [ ] Add/audit explicit CDC for `axi_inj_ctrl` outputs crossing from MMCM
    `clk_out2` into the SX1257-driven DSP domain.
  - Design intent: the ASIC needs only ONE clock. The board exposes all four
    CLK_OUTs so the other three can be measured against this one to prove they
    are phase-locked before committing the single-clock design to silicon. A
    shared TCXO guarantees *frequency* lock (no drift); static inter-chip *phase*
    skew and RX pipeline latency are open questions. The SX1257 datasheet does
    not guarantee that synchronized RFFE_RST aligns internal divider state,
    sampling-clock phase, ADC latency, or RF PLL phase. See
    `SX1257_CLOCK_RESET_SYNCHRONIZATION.md` and the "Clock-sync measurement
    harness" item below.
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
  - [x] **Clock-sync measurement harness** (de-risks the single-clock ASIC).
    DONE at RTL/BD/FW level. `rtl/axi_clk_sync_mon.v`: AXI4-Lite peripheral on
    dsp_clk that samples the other three CLK_OUTs (F3/D3/C15 as ordinary inputs
    via `clk_meas[2:0]`, 2-FF synced) and counts toggles over a 2^W window —
    ~0 ⇒ frequency-locked, large ⇒ not locked; captured LEVEL is a coarse phase
    bit. BD instantiates it at **0x0002_0000** (dsp_clk AXI automation); XDC
    constrains F3/D3/C15 (respin: C15→D15) with `set_false_path`. Firmware
    `clk_sync_measure()` in `sw/main.c` arms/polls/prints over UART at startup
    (2^20 window). Verified in xsim: `make sim_clksync` (TB PASS — classifies
    locked=0 vs unlocked toggles correctly).
    - Firmware change needs a Vitis rebuild against a regenerated `.xsa` (the new
      BD adds the peripheral); until then the ELF won't see 0x0002_0000.
    - Fine phase magnitude (IDELAY ~78 ps/tap or MMCM fine phase sweep) is a
      future extension; this block gives lock/no-lock + coarse phase only.
    - Found while writing the tb: `axi_inj_ctrl.v`'s AXI read channel asserts
      `rvalid` one cycle before `rdata` is valid (registered-on-do_read mux), so
      reads return the *previous* transaction's data. `axi_clk_sync_mon.v` uses a
      combinational read mux to avoid it. Worth auditing axi_inj_ctrl reads.
- [x] **remod_i / remod_q.** DONE. Dropped from the BD (no top-level port, no
  constraint); the wrapper still exposes them as unconnected cell pins. Re-add
  a port + pin if a TX/remod path is ever added to the board.
- [x] **External host-SPI slave (real RPi path).** DONE. trouper_top's host SPI
  slave + IRQ_OUT are now selectable between the internal axi_quad_spi master
  (CI) and real external pins via `spi_sel` (Arty SW0=A8). `fpga_dsp_wrap` muxes
  the three slave inputs before spi_slave (so the external SCK pin need not be
  clock-capable — the BUFG sits on the fabric mux output). Pins (ChipKit header,
  from Arty-A7-100-Master.xdc): ext_host_cs=C1, ext_spi_sck=F1, ext_spi_mosi=H1,
  ext_spi_miso=G1, ext_irq=R11(ck_io30). XDC has a 10 MHz async `create_clock`
  on ext_spi_sck. Full P&R clean: all timing met, ext_spi_sck +39.4 ns setup /
  +0.143 hold (0 failing/80), IOB 50/210. (The 2 `Place 30-73` critical warnings
  are PRE-EXISTING axi_quad_spi_1 IOB-packing artifacts, not from this change.)
  - GRP bus intentionally NOT exposed: it is an on-die inter-project bus (not
    bond pads — see trouper_top pad count 23, GRP excluded), tied idle here;
    arbitration is covered by rtl-test tb_trouper_grp_arb. IRQ_GROUPER unused.
  - `tb_fpga_spi_reg.v` ties spi_sel=0 + ext_* inputs low (internal path). When
    spi_sel=1 the internal master is muxed out; firmware SPI is then a no-op.
- [x] **NSS decoder enable (1E-bar), FPGA side.** DONE 2026-08-19. The board
  side of PCB review finding 4 was fixed 2026-07-12 (1G139 → 139A, has a
  per-decoder enable) and 2026-07-13 (1E routed to a spare header pin, PCB
  J7.10 = Arty J15) — confirmed by netlist export against miso_frontend
  commit `97d4322`. That fix had no FPGA-side counterpart until now: added
  `axi_gpio_nss_en_0` (1-bit output, default HIGH = all-deselected) exposed
  as BD port `rffe_nss_en`, constrained to J15 in `arty_dsp_emul.xdc`.
  Firmware `rffe_nss_enable()` in `sw/main.c` drives it low once before the
  SX1257 init loop and leaves it enabled (the 2-bit address already keeps
  exactly one decoder output asserted per transaction). Needs a BD/XSA
  rebuild (`gen_xsa.tcl` + BSP) before firmware picks up
  `XPAR_AXI_GPIO_NSS_EN_0_BASEADDR`; falls back to `0x00030000` until then.
  **This is a narrower fix than the I2C-expander plan below** — it only
  restores all-deselect capability on the existing 139A decoder, using the
  board's actual current hardware. The I2C-expander item remains open/undone
  if 4 fully discrete NSS lines are still wanted later.
- [ ] **NSS + RFFE_RST via I2C IO expander (DECIDED 2026-07-09; supersedes the
  2-bit-encoded-NSS plan; NOT built on the board that shipped — see the 1E-bar
  fix above for what's actually on hardware).** Replace the on-board SN74LVC1G139 decoder with an
  I2C IO expander (TCA-family, e.g. TCA9535 16-bit) on the daughterboard, driving
  **four discrete active-low NSS lines** plus **RFFE_RST** (and spare bits for RX
  enables). Rationale — all-deselect is essential on a shared-MISO multi-drop SPI
  bus (clean idle, correct NSS-rising frame termination, matches the ASIC host's
  ability to deselect); the 1G139 (no enable) can never deselect all radios
  (review finding 4). Bonus: the expander lives next to the SX1257s, so RFFE_RST
  gets a short daughterboard trace — this **retires the PMOD reset-pin crosstalk
  hunt** (no need for the J15 dedicated pin).
  - Board respin: drop the 1G139; add the expander (SDA/SCL to 2 FPGA pins via a
    PMOD + 4.7k pull-ups; address straps; its own RESET tied high/to board rst).
    Expander push-pull outputs: 4× NSS (active-low), 1× RFFE_RST, spares. The
    RFFE SPI *data* path (MOSI/SCK/MISO) stays FPGA-driven; only chip-select and
    reset move to I2C. **Frees A18/B18** (old NSS_A0/A1).
  - Crosstalk: I2C is slow open-drain and **idle during I/Q capture** (all of
    NSS/reset is config-time), so SDA/SCL are non-aggressors — they may even use
    the JC diff-pair pins that were rejected for a floating reset. Keep the bus
    idle while sampling.
  - RESET sequence (satisfies both datasheet §6.2 and crosstalk): expander POR =
    Hi-Z ⇒ RFFE_RST floats at power-on (datasheet-compliant, safe — nothing is
    switching yet). Firmware then drives it HIGH >100 us (reset pulse), waits
    5 ms, then drives it **LOW** for the whole capture (actively deasserted ⇒
    crosstalk-immune, not floating). Shared net ⇒ all four resets are inherently
    simultaneous, which the clock-sync experiment needs.
  - FPGA/BD rework: add an AXI IIC master (2 pins). axi_quad_spi_0 SS no longer
    goes to pins (hardware auto-SS is lost) — chip-select becomes firmware-
    sequenced: I2C select chip N → SPI frame → I2C all-deselect. Slower per
    access but SX1257 config is one-time, so fine. Set/leave axi_quad_spi_0
    C_NUM_SS_BITS minimal/unused.
  - Expander choice matters: use a TCA-type whose POR state is inputs/Hi-Z (float
    at POR); a PCF8574 powers up outputs weakly HIGH → would assert RFFE_RST at
    POR. Confirm push-pull drive for the RESET-low-during-capture step.

## Validation

- [x] **BD builds + validates.** `make vivado_project` (Vivado 2025.2) runs clean:
  `validate_bd_design` passes, 0 errors, 0 critical warnings. The `util_ds_buf`
  BUFG, the `USE_EXT_PSRAM=1` param, the inout `psram_sio` port, and the
  `axi_inj_ctrl` AXI-CDC automation (Clk_slave `/clk_wiz_0/clk_out2 (32 MHz)`)
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
  - Re-run WITH the axi_clk_sync_mon peripheral + clk_meas[2:0] inputs also
    passes: all timing met, sx_clk_out setup WNS +9.94 ns / hold +0.034 ns,
    overall WNS +1.03 ns, IOB 44/210, LUT 15.7% / FF 8.2%. clk_meas false-paths
    honored (3 new IOBs, no clock created).
- [ ] **Reset/bring-up ordering.** rst_32m now releases the DSP domain only once
  CLK_OUT is toggling. Confirm firmware configures the SX1257 (over RFFE SPI,
  100 MHz domain) to start CLK_OUT before expecting any DSP-domain activity.
  RFFE_RST is now driven from the I2C IO expander (see the NSS+RFFE_RST item
  above), not a dedicated FPGA pin: float (Hi-Z) at POR, pulse high >100 us,
  wait >=5 ms, then drive low for capture. Shared net ⇒ inherently simultaneous
  across the four devices — but this gives repeatable init, NOT phase alignment;
  prove alignment with the measurement harness.
- [ ] **Scope CLK_OUT_2 edge quality** at F4 (200 Ω) at 32 MHz before trusting
  captures — the 200 Ω series may soften the edge. A board respin to a P-side
  0 Ω pin (D15, see above) would remove this concern.
- [~] Pin map + control-plane wiring documented in `HARDWARE_SETUP.md` §6 (MISO
  board map, CLK_OUT monitor, external-RPi host-SPI wiring + RPi pinout). Mark
  fully done once verified against a physical board (pins/switch/RPi link).

# FPGA Emulation — Hardware Setup (Arty A7-100T)

Bring-up reference for the LoRa MIMO DSP-chain FPGA emulation on the Digilent
Arty A7-100T (`xc7a100tcsg324-1`). Covers the clock tree, UART console, and
Ethernet datapath. Verified working 2026-06-15 (UART console + `ping` to the
board both functional).

The Vivado block design is built script-only by `vivado/create_project.tcl`
(no checked-in `.bd`/`.xpr`). Build flow and firmware are at the end.

> **⚠ Sections 1–4 describe the ORIGINAL 2026-06 bring-up.** The 2026-07 re-pin
> to the MISO front-end test PCB changed several of these — notably the DSP
> **is no longer clocked by the MMCM `clk_out2`** (it now runs from the SX1257
> `CLK_OUT` on pin **F4**), `axi_dsp_ctrl` is now `axi_inj_ctrl`, the SX1257 I/Q
> pins moved, PSRAM is now a real external chip, and the host SPI slave can be
> driven by a real RPi. **Section 6 is the current pin map and takes precedence.**

---

## 1. Clock setup

Single MMCM (`clk_wiz_0`) fed by the on-board 100 MHz oscillator. **VCO = 800 MHz**
(`M=8`, `D=1`) so all three outputs use **integer** dividers — important, see the
Ethernet note below.

| clk_wiz output | Freq    | Divider   | Drives                                                     |
|----------------|---------|-----------|------------------------------------------------------------|
| `clk_in1`      | 100 MHz | (input)   | board oscillator, pin **E3**                               |
| `clk_out1`     | 100 MHz | 800/8     | MicroBlaze + AXI bus: EmacLite, Quad SPI, UARTLite, MDM    |
| `clk_out2`     | 32 MHz  | 800/25    | DSP chain (`axi_dsp_ctrl` → `fpga_dsp_wrap`)               |
| `clk_out3`     | 25 MHz  | 800/32    | Ethernet PHY reference clock → `eth_ref_clk` (pin **G18**) |

Reset input `ext_resetn` on pin **C2** (active-low) feeds `clk_wiz` and two
`proc_sys_reset` blocks (`rst_100m`, `rst_32m`).

**Two clock domains:**
- **100 MHz** — MicroBlaze and all standard AXI peripherals.
- **32 MHz** — the DSP chain. The MicroBlaze peripheral bus (100 MHz) reaches the
  32 MHz `axi_dsp_ctrl` through the **AXI SmartConnect**, which performs the
  100→32 MHz clock-domain crossing. No manual `axi_clock_converter` is needed.

The DSP chain is internally synchronous to `clk_out2` only (32 MHz); `axi_dsp_ctrl`
uses it for both `dsp_clk` and `s_axi_aclk`.

---

## 2. UART console

USB-UART bridge (FTDI) on the Arty, exposed as `/dev/ttyUSB1` on the host.

| Signal             | FPGA dir | Pin  | Notes                                  |
|--------------------|----------|------|----------------------------------------|
| `UART_0_txd` (TX)  | output   | D10  | Digilent net `uart_rxd_out` (FPGA → host) |
| `UART_0_rxd` (RX)  | input    | A9   | Digilent net `uart_txd_in`  (host → FPGA) |

- IP: `axi_uartlite`, base **0x40600000**, **115200** 8N1.
- Register map: RX_FIFO `+0x00`, TX_FIFO `+0x04`, STATUS `+0x08`
  (bit2 = TX_EMPTY, bit3 = TX_FULL), CTRL `+0x0C`.

> **Pin-direction gotcha:** the Digilent net names are from the *host's*
> perspective. `uart_rxd_out` (D10) is what the FPGA **drives** (FPGA TX);
> `uart_txd_in` (A9) is what the FPGA **receives** (FPGA RX). Wiring TX to A9
> makes the FPGA fight the FTDI's TX line → host sees 0 bytes.

Read the console:
```bash
stty -F /dev/ttyUSB1 115200 raw -echo
cat /dev/ttyUSB1
```

---

## 3. Ethernet setup

On-board **TI DP83848** PHY in **MII** mode, driven by `axi_ethernetlite`
(EmacLite), base **0x40E00000**, on the 100 MHz AXI clock.

### Network parameters (firmware `sw/main.c`)
| | |
|---|---|
| FPGA IP  | `192.168.10.2` |
| FPGA MAC | `02:12:34:56:78:9b` |
| Host IP  | `192.168.10.1/24` (direct cable) |
| UDP data port   | 5005 (FPGA → host) |
| UDP status port | 5006 (FPGA → host) |
| UDP inject port | 5007 (host → FPGA) |
| UDP control port| 5008 (host → FPGA) |

EmacLite also answers ARP and ICMP echo, so `ping 192.168.10.2` is the quickest
link test.

### Pinout (Arty A7 master XDC, MII)
| Signal | Pin | | Signal | Pin |
|--------|-----|---|--------|-----|
| `eth_ref_clk` (25 MHz out) | **G18** | | `MII_0_rx_clk` | F15 |
| `phy_rst_n` | C16 | | `MII_0_rx_dv`  | G16 |
| `phy_mdc`   | F16 | | `MII_0_rxd[0..3]` | D18, E17, E18, G17 |
| `MDIO_0_mdio_io` | K13 | | `MII_0_rx_er` | C17 |
| `MII_0_tx_clk` | H16 | | `MII_0_col` | D17 |
| `MII_0_tx_en`  | H15 | | `MII_0_crs` | G14 |
| `MII_0_txd[0..3]` | H14, J14, J13, H17 | | | |

### Two requirements that are easy to miss

1. **PHY reference clock (`eth_ref_clk`, pin G18).** The DP83848 has no crystal —
   the FPGA must drive it a 25 MHz reference. Without it the PHY PLL never starts:
   no link, no link LED, host NIC shows `carrier=0`. Driving the MMCM `clk_out3`
   straight to the pin is fine (no ODDR needed; ~175 ps clk jitter is normal).

2. **EmacLite must run at ~100 MHz AXI, not 32 MHz.** EmacLite crosses its AXI
   clock to the 25 MHz MII clock internally. At 32 MHz AXI (only 1.28:1 over MII)
   that CDC is marginal and produces **MII bit-slips** — random CRC + alignment
   errors on *every* frame, in *both* directions, even though the link still
   negotiates 100M full-duplex. Running EmacLite at 100 MHz (4:1 over MII) fixes
   it. This is why the MicroBlaze/peripheral bus is 100 MHz and only the DSP is 32.

### Host-side bring-up & test
```bash
# one-time: give the host NIC connected to the Arty an address on the subnet
sudo ip addr add 192.168.10.1/24 dev <nic>
sudo ip link set <nic> up

ping 192.168.10.2                 # expect 0% loss
ip neigh show 192.168.10.2        # expect lladdr 02:12:34:56:78:9b REACHABLE
```

Diagnosing MII corruption (link up but no ping): let the NIC pass bad-FCS frames,
then inspect raw bytes —
```bash
sudo ethtool -K <nic> rx-fcs on rx-all on
sudo tcpdump -i <nic> -e -xx -c 20
```
Constant fields (EtherType `0800`, src MAC) decoding *differently each frame* +
variable frame lengths ⇒ random **bit-slips** ⇒ a clock/CDC problem (not a wiring
bug). Watch `rx_crc_errors` / `rx_align_errors` in `ethtool -S <nic>`.

---

## 4. Other peripherals

| Peripheral | IP | Base | Clock |
|------------|----|------|-------|
| DSP control | `axi_dsp_ctrl` (custom) | **0x00010000** | 32 MHz |
| Quad SPI (→ SX1257 ×4) | `axi_quad_spi` | 0x44A00000 | 100 MHz |

`axi_dsp_ctrl` register map and modes are documented in `rtl/axi_dsp_ctrl.v`.
SX1257 I/Q inputs arrive on PMOD pins synchronous to the 32 MHz `dsp_clk`.

> Base addresses are assigned by `assign_bd_address`. After any BD change,
> regenerate the XSA (`vivado/gen_xsa.tcl`) and rebuild the BSP so firmware picks
> up current addresses (`make eth_fw`). Read live values from the generated
> `xparameters.h`.

---

## 5. Build & program

All from `fpga-emul/`. Vivado/Vitis 2025.2 (paths in the `Makefile`).

```bash
# 1. Block design + project (script-only; -force recreates)
vivado -mode batch -source vivado/create_project.tcl

# 2. Synthesis + implementation + bitstream  (~25-35 min on xc7a100t)
vivado -mode batch -source vivado/run_synth.tcl
#    → fpga-emul/arty_dsp_emul.bit

# 3a. Bare-metal smoke test firmware (UART + DSP reg check, no BSP)
make test_fw          # builds sw/test_fw.elf via mb-gcc
make run_test_fw      # xsdb: program .bit + download/run over JTAG

# 3b. Full Ethernet/SPI/DSP firmware (sw/main.c, needs Vitis BSP)
make eth_fw           # xsct (under xvfb) builds BSP from the XSA, then links
                      #   sw/main.c against libxil → sw/lora_mimo_fw.elf
make run_eth_fw       # xsdb: program .bit + download/run over JTAG
```

Notes:
- The `.bit`, `.xsa`, `.elf`, and `sw/vitis_ws/` are git-ignored (regenerable).
- Vitis 2025.2 `xsct` needs an X display; `make eth_fw` wraps it in `xvfb-run`
  (`sudo apt-get install -y xvfb` once).
- JTAG scripts: `vivado/run_test_fw.tcl`, `vivado/run_eth_fw.tcl`. A
  firmware-independent UART TX poke is in `vivado/uart_poke.tcl`.

---

## 6. MISO front-end test PCB — current pin map (2026-07)

The emulator now targets the MISO front-end daughterboard (four SX1257 + external
APS6404L PSRAM), which mounts over the four Arty PMODs with the **header order
reversed**: PCB **J5→JD, J6→JC, J7→JB, J8→JA**. Full derivation and the PCB review
are in `vivado/arty_dsp_emul.xdc` and `tmp/miso_frontend_pcb_review_2026-07-08.md`.

> **⚠ This bitstream needs the daughterboard to run the DSP chain.** The DSP
> domain is clocked by the SX1257 `CLK_OUT` (pin **F4**), which only toggles after
> the SX1257 is configured over the RFFE SPI. Until then `rst_32m` holds the DSP
> in reset (by design — it mirrors silicon, where `IQ_CLK` *is* the front-end
> sample clock). PSRAM is also external (`USE_EXT_PSRAM=1`). The MicroBlaze /
> UART / Ethernet (100 MHz + 25 MHz MMCM) still run standalone.

### 6.1 SX1257 I/Q + SPI + PSRAM

| Function | FPGA pins | Header |
|----------|-----------|--------|
| SX1257 I/Q data `hw_iq_i/q[0..3]` | G2 H2 / V11 U13 / V12 V14 / E16 J18 | JD/JC/JC/JB |
| RFFE SPI to SX1257 (MOSI/MISO)     | E2 / D2 | JD |
| RFFE NSS address `ss_io[0..1]` (→1G139) | A18 / B18 | JA |
| **DSP sample clock** `sx_clk_out` = CLK_OUT_2 | **F4** | JD |
| External APS6404L PSRAM (SCK/nCE)  | D12 / D13 | JA |
| PSRAM SIO0..3                       | A11 G13 B11 K16 | JA |

### 6.2 CLK_OUT phase-lock monitor (`axi_clk_sync_mon`, base 0x0002_0000)

Samples the *other* three CLK_OUTs against the F4 sample clock to prove they are
phase-locked before trusting the single-clock design (see `rtl/axi_clk_sync_mon.v`).
Inputs are ordinary data pins (not clocks): `clk_meas[0]=F3` (CLK_OUT_1),
`clk_meas[1]=D3` (CLK_OUT_3), `clk_meas[2]=C15` (CLK_OUT_4; **change to D15 after
the C15→D15 respin**). Firmware `clk_sync_measure()` prints per-channel
LOCKED/NOT-LOCKED over UART at startup.

### 6.3 Host SPI slave — internal master vs. real RPi (`spi_sel` = SW0)

The ASIC host-SPI register interface (`trouper_top` `spi_slave`) is driven either
by the internal `axi_quad_spi` master (MicroBlaze plays the host — the CI path) or
by a **real external RPi**, selected by the **SW0 slide switch (pin A8)**:

| SW0 (A8) | Host SPI source |
|----------|-----------------|
| **down (0)** | internal `axi_quad_spi_1` master (default; no external wiring needed) |
| **up (1)**   | external RPi on the pins below |

External pins are on the Arty **dedicated SPI header** (ChipKit/Arduino SPI) plus
one ChipKit digital pin for IRQ:

| ASIC signal | FPGA dir | Arty pin | ChipKit net | RPi (SPI0, 40-pin header) |
|-------------|----------|----------|-------------|---------------------------|
| `ext_host_cs`  | in  | **C1**  | `ck_ss`   | CE0  — GPIO8  (pin 24) |
| `ext_spi_sck`  | in  | **F1**  | `ck_sck`  | SCLK — GPIO11 (pin 23) |
| `ext_spi_mosi` | in  | **H1**  | `ck_mosi` | MOSI — GPIO10 (pin 19) |
| `ext_spi_miso` | out | **G1**  | `ck_miso` | MISO — GPIO9  (pin 21) |
| `ext_irq`      | out | **R11** | `ck_io30` | any GPIO input (e.g. pin 22) |
| — GND          | —   | header GND | GND    | GND (pin 20/25) |

RPi SPI settings: **mode 0** (CPOL=0, CPHA=0), **≤10 MHz**, 8-bit, CS active-low.
The frame format matches the internal master exactly (address byte then data
byte — see `sw/main.c` `reg_write`/`reg_read` and `src/control/spi_slave.v`).

Notes:
- `SPI_SCK` is a real clock (`spi_slave` clocks flops on it), but it is muxed
  ahead of the clock buffer, so **F1 need not be clock-capable** — the BUFG sits
  on the fabric mux output. Set SW0 *before* starting SPI traffic (static select).
- With SW0 up, the internal MicroBlaze SPI master is muxed out; firmware SPI
  writes become no-ops (harmless).
- `ext_irq` (R11) mirrors the internal sticky IRQ; poll it on the RPi instead of
  the AXI GPIO when using the external host.

### 6.4 Updated peripheral base addresses

| Peripheral | IP / module | Base | Clock |
|------------|-------------|------|-------|
| Injection FIFO/pacer | `axi_inj_ctrl` (custom) | 0x0001_0000 | dsp_clk (F4) |
| CLK_OUT phase-lock monitor | `axi_clk_sync_mon` (custom) | 0x0002_0000 | dsp_clk (F4) |
| RFFE Quad SPI (→ SX1257) | `axi_quad_spi_0` | 0x44A0_0000 | 100 MHz |

> After any BD change, regenerate the XSA (`vivado/gen_xsa.tcl`) and rebuild the
> BSP so firmware picks up current addresses — read live values from the generated
> `xparameters.h` (the `#define`s in `sw/main.c` are only fallbacks).

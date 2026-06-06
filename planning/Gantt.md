# Project Schedule

Tapeout deadline: **1 September 2026**. Design review: **July 2026**. Today: **19 May 2026**.

See [Chipathon 2026](Chipathon%202026.md) for official phase definitions.

---

```mermaid
gantt
    title LoRa MIMO ASIC — Tapeout Schedule
    dateFormat  YYYY-MM-DD
    axisFormat  %d %b

    section Milestones
    Team kickoff                         :milestone, m1, 2026-05-09, 0d
    Phase 1 close (project defined)      :milestone, m_p1, 2026-05-31, 0d
    Phase 2 close (blocks implemented)   :milestone, m_p2, 2026-06-30, 0d
    Design review (Phase 3)              :milestone, crit, m2, 2026-07-01, 0d
    FPGA validation pass                 :milestone, m3,     2026-08-10, 0d
    GDS freeze (Phase 4)                 :milestone, crit, m4, 2026-09-01, 0d

    section DSP Simulation
    Python golden reference model        :crit, vf1,  2026-05-09, 28d

    section DSP Implementation
    ΣΔ Decimator ×4 (CIC + FIR)         :rx1,  2026-05-17, 21d
    ΣΔ Re-modulator ×2                   :rx6,  2026-05-17, 14d
    DC Removal ×4                        :rx0,  2026-05-24, 7d
    Energy Measurement (in SC path)     :rx2,  2026-05-24, 14d
    Correlator Bank ×8                   :crit, rx3,  2026-05-24, 28d
    Training Accumulator                 :crit, rx4,  2026-05-24, 21d
    Weight Generation                    :crit, rx5,  2026-06-01, 21d
    Noise Floor Estimator                :rx7,  2026-06-01, 7d

    section Control Plane
    AHB-Lite Bus                         :cb4,  2026-05-24, 10d
    IRQ Controller                       :cb3,  2026-05-23, 7d
    SPI Master + Slave                   :cb1,  2026-05-17, 21d
    Packet Control FSM                   :cb5,  2026-05-24, 7d
    PSRAM Controller                     :cb6,  2026-06-15, 14d
    SRAM macro path                      :crit, cm1,  2026-05-24, 21d
    SRAM macro BIST                      :cm2,  2026-05-30, 7d
    PicoRV32 integration + arbiter       :crit, cm3,  2026-05-18, 21d

    section Software
    Bootloader + SX1257 startup          :fw0,  2026-05-31, 28d
    AGC loop                             :fw4,  2026-06-15, 14d
    RPi host driver + ASIC SPI config    :fw6,  2026-06-01, 21d
    RPi ChirpStack integration + demo    :fw7,  2026-07-06, 21d

    section Verification + FPGA
    JTAG TAP                             :cm4,  2026-07-01, 14d
    Block testbenches (cocotb)           :vf2,  after vf1, 70d
    FPGA bring-up (SPI blocks)           :fp0,  2026-06-01, 10d
    FPGA sigma-delta capture path        :fp1,  2026-06-11, 10d
    FPGA AFE common-tone characterization:fp2,  2026-06-21, 14d
    Integration simulation               :crit, vf4,  2026-06-15, 56d
    FPGA synthesis, MIMO bring-up + OTA  :fp3,  2026-07-13, 28d

    section RF / Hardware
    First test PCB design                :hw2,  2026-05-17, 7d
    First test PCB fab + assembly        :hw3,  2026-05-24, 14d
    First test PCB available (~3 weeks)  :milestone, hw4, 2026-06-07, 0d
    PCB bring-up                         :hw5,  2026-06-07, 14d

    section Physical Design
    Trial synthesis + floorplan          :pd0,  2026-07-01, 21d
    Yosys synthesis (GF180MCU)           :crit, pd1,  2026-08-10, 7d
    OpenROAD place & route               :crit, pd2,  2026-08-17, 10d
    DRC / LVS clean (KLayout + netgen)   :crit, pd3,  2026-08-27, 5d
    Chipathon submission package         :pd4,  2026-08-28, 4d
```

---

## Critical path

The chain that determines whether September 1 is achievable:

1. **Correlator Bank RTL** (May 9 → Jun 6) — 8 coherent integrators; determines lock quality and timing handoff
2. **Training Accumulator + Weight Generation RTL** (May 17 → Jun 15) — replaces the old FFT/ALMMSE path and is now the main packet-training critical path
3. **SRAM macro path / GF180 enablement** (May 9 → May 30) — SRAM selection and integration must settle early because the DSP and CPU paths both depend on it
4. **PicoRV32 integration** (May 18 → Jun 8) — needs SRAM and bus; firmware and control-plane integration can't be exercised until this is done
5. **Integration simulation** (Jun 15 → Aug 10) — first full-system connection of DSP, control, and firmware paths; expect debug iterations here
6. **FPGA AFE characterization + OTA test** (Jun 21 → Aug 10) — FPGA first validates sigma-delta capture and AFE coherence, then later validates NT=1 + NT=2 before GDS
7. **OpenROAD P&R → DRC/LVS** (Aug 17 → Sep 1) — 2.5 weeks; no float

Trial synthesis runs from Jul 1 to catch area/timing surprises while RTL is still in flux. Final P&R begins Aug 17 once RTL is frozen. FPGA MIMO / OTA test and final P&R overlap deliberately (Aug 10–17) — if FPGA finds an RTL bug after Aug 17, P&R must restart. Keep FPGA scope staged: first SPI + sigma-delta capture + AFE coherence work, then packet RX, MIMO combining, and IRQ.

---

## Float / risk

| Risk | Float | Mitigation |
| --- | --- | --- |
| Training accumulator / weight path runs late | 1 week | Start cocotb testbench in parallel with RTL and validate against the Python chain early |
| SRAM macro path unresolved on GF180MCU | 0 days (critical path) | Treat SRAM enablement as a first-class task; evaluate OpenRAM support, alternative SRAM generators, compiler macros, or split behavioural/placeholder SRAM path early |
| Correlator bank coherence issues | 3 days | Validate with Python golden model before RTL; test each correlator independently |
| PSRAM controller integration churn | 3 days | Keep replay mode optional and stage bring-up after the live path is stable |
| Phase coherence across SX1257s 2–4 | TBD | Use FPGA sigma-delta capture plus common-tone AFE tests before full OTA work |
| DRC violations in P&R | 3 days | GF180MCU standard cells only; let OpenROAD handle fill |
| Chipathon shuttle deadline shifts | — | Monitor SSCS announcements; July design review gives early warning |

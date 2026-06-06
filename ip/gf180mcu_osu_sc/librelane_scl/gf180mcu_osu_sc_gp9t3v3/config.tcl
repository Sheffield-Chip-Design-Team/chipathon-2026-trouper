# LibreLane/OpenLane SCL config for the OSU 3.3 V cells gp9t3v3.
# Mirrors gf180mcu_fd_sc_mcu7t5v0/config.tcl with OSU-specific values.
# Staged into $PDK_ROOT/$PDK/libs.tech/openlane/gf180mcu_osu_sc_gp9t3v3/ by
# stage_osu_scl.sh, alongside libs.ref/gf180mcu_osu_sc_gp9t3v3/{lib,lef,gds,techlef,cdl}.
# NOTE: OSU cells use A (in) / Y (out). Tieh/Tiel output pin is Y.
# OSU ships NO welltap and NO endcap cell -> treated as tapless (empty).
# OSU ships only the TT_25C corner -> all three corner libs point at it.
set current_folder [file dirname [file normalize [info script]]]

# Placement site (from OSU tlef): 0.10 x 6.300 um, 9-track
set ::env(PLACE_SITE) "gf180mcu_osu_sc_gp9t3v3"
set ::env(PLACE_SITE_WIDTH) 0.10
set ::env(PLACE_SITE_HEIGHT) 6.300

# OSU has no welltap/endcap cells -> tapless. Empty disables insertion.
set ::env(FP_WELLTAP_CELL) ""
set ::env(FP_ENDCAP_CELL) ""

# Synthesis driving / tie / min-buf (OSU pins: A in, Y out)
set ::env(SYNTH_DRIVING_CELL) "$::env(STD_CELL_LIBRARY)__inv_1"
set ::env(SYNTH_DRIVING_CELL_PIN) "Y"
set ::env(SYNTH_CLK_DRIVING_CELL) "$::env(STD_CELL_LIBRARY)__clkbuf_4"
set ::env(SYNTH_CLK_DRIVING_CELL_PIN) "Y"
set ::env(SYNTH_MIN_BUF_PORT) "$::env(STD_CELL_LIBRARY)__buf_1 A Y"
set ::env(SYNTH_TIEHI_PORT) "$::env(STD_CELL_LIBRARY)__tieh Y"
set ::env(SYNTH_TIELO_PORT) "$::env(STD_CELL_LIBRARY)__tiel Y"

# Required PDK var: default output load for synthesis/STA (fF). Reasonable
# GF180 default; refine from OSU liberty pin caps later if needed.
set ::env(OUTPUT_CAP_LOAD) "10.0"

# Fill / decap (OSU: fill_*, decap_*)
set ::env(FILL_CELL) "$::env(STD_CELL_LIBRARY)__fill_*"
set ::env(DECAP_CELL) "$::env(STD_CELL_LIBRARY)__decap_*"
set ::env(CELL_PAD_EXCLUDE) "$::env(STD_CELL_LIBRARY)__fill_* $::env(STD_CELL_LIBRARY)__decap_*"

# Antenna diode (OSU: ant). Pin TBD — confirm on first run; disable if it errors.
set ::env(DIODE_CELL) "$::env(STD_CELL_LIBRARY)__ant"
set ::env(DIODE_CELL_PIN) "A"

# CTS buffers
set ::env(CTS_ROOT_BUFFER) "$::env(STD_CELL_LIBRARY)__clkbuf_16"
set ::env(CTS_CLK_BUFFER_LIST) "$::env(STD_CELL_LIBRARY)__clkbuf_2 $::env(STD_CELL_LIBRARY)__clkbuf_4 $::env(STD_CELL_LIBRARY)__clkbuf_8"
set ::env(CTS_MAX_CAP) 0.5

set ::env(FP_PDN_RAIL_WIDTH) 0.6

# Constraints (lib max transition per OSU .lib; tighten as needed)
set ::env(MAX_TRANSITION_CONSTRAINT) 3
set ::env(MAX_FANOUT_CONSTRAINT) 10
set ::env(MAX_CAPACITANCE_CONSTRAINT) 0.2
set ::env(GPL_CELL_PADDING) {0}
set ::env(DPL_CELL_PADDING) {0}

# OSU ships ONLY TT_25C. Point all corner libs at it, but via DOUBLE-underscore
# corner-named symlinks (staged by stage_osu_scl.sh) because LibreLane's
# pdk_compat parses the PVT by `filename.split("__")[1]` — a single-underscore
# name (..._TT_25C.ccs.lib) crashes with IndexError.
set libdir "$::env(PDK_ROOT)/$::env(PDK)/libs.ref/$::env(STD_CELL_LIBRARY)/lib"
set ::env(LIB_SYNTH)   "$libdir/$::env(STD_CELL_LIBRARY)__tt_025C_3v30.lib"
set ::env(LIB_FASTEST) "$libdir/$::env(STD_CELL_LIBRARY)__ff_n40C_3v60.lib"
set ::env(LIB_SLOWEST) "$libdir/$::env(STD_CELL_LIBRARY)__ss_125C_3v00.lib"
set ::env(LIB_TYPICAL) $::env(LIB_SYNTH)

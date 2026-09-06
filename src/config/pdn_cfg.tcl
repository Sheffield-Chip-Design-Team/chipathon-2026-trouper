# Custom PDN config for trouper_top.
# Note: FD SRAM macro removed; no hard-macro PDN grids required.
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd
        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }
    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd
        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) -secondary_power $secondary

# Optional hard keepout for shared-die floorplans (e.g. the L-shape config's
# corner reserved for the Grouper project). FP_OBSTRUCTIONS only blocks cell
# placement, not PDN stripe generation or routing, so without this the power
# grid and signal routing both cross straight through a "blocked" corner.
# Guarded on an env var set only by the configs that need it (see
# config_lshape_1100_550_v26_pins.json) — inert for every other config.
# Region format: "x1 y1 x2 y2" in microns, matching FP_OBSTRUCTIONS' box.
# create_obstruction blocks PG routing too unless -except_pg is passed, which
# is exactly what we want here (see OpenROAD ODB.tcl create_obstruction).
if { [info exists ::env(PDN_KEEPOUT_REGION)] } {
    set pdn_keepout_region $::env(PDN_KEEPOUT_REGION)
    foreach pdn_keepout_layer {Metal1 Metal2 Metal3 Metal4 Metal5} {
        create_obstruction -region $pdn_keepout_region -layer $pdn_keepout_layer
    }
}

# SIGNAL-only keepouts over the post-flow A40 PDN bridge landing zones
# (tools/build_a40_pdn_bridges.py). The bridges are inserted into the GDS by
# fixed absolute coordinates with no awareness of the router's result; on
# job 5650 the router ran three SIGNAL nets (_20360_ 3-pin, _20338_ 12-pin,
# _18690_) straight through the north VDD fingers' M3 via-enclosure / via2
# band -> 12x M3.2a + 4x V2.1 in the guarded 63-table KLayout DRC (job 5653).
#
# METAL2 + METAL3 ONLY. Two earlier attempts failed:
#   - plain create_obstruction on M2..M5 (job 5674): blocks PG routing too,
#     which severs Trouper's own PDN where the bridges tap in -- the VDD M5
#     north ring got cut x[1329.5,1405.5] and the VSS M4 west ring y[4,82.3],
#     leaving the post-flow bridges floating (LVS runs on the base streamout,
#     not the bridged GDS, so it never catches this).
#   - the same M2..M5 boxes WITH -except_pg (job 5681): the signal router
#     honours except-pg, but the PDN generator (add_pdn_ring / add_pdn_stripe)
#     carves around ANY obstruction regardless of the flag -- ring still cut.
# The 16 job-5653 DRC violations are all Metal3 (M3.2a x12) and Via2 (V2.1 x4,
# needs an M2+M3 landing), all on SIGNAL nets (_20360_/_20338_/_18690_,
# verified per-net). The Trouper core ring is on Metal5 (VDD) / Metal4 (VSS),
# and job 5650's keepout-free DRC had ZERO M4/M5 violations in the bridge
# zones. So blocking only M2+M3 evicts the offending signal routing while
# leaving M4/M5 clear for the ring -> bridges reconnect. -except_pg kept for
# intent (no-op here: M2/M3 carry no PDN in these edge strips, only signal).
#
# Metal1 is NOT blocked (followpin rails); cell placement is not blocked (the
# strips have zero cell rows / pins -- verified in job 5650's DEF). Hardcoded
# (LibreLane 2.x drops unrecognised config keys before the step env), guarded
# on DIE_AREA so it fires only on the A40 ACV die. Re-verify against the next
# guarded KLayout DRC AND confirm VDD-M5 / VSS-M4 ring continuity through the
# zones. "x1 y1 x2 y2" in microns.
if { [info exists ::env(DIE_AREA)] && [string match "*1675*1110*" $::env(DIE_AREA)] } {
    set a40_bridge_keepouts {
        {1330 1094 1405 1110}
        {0 4 8 82}
    }
    foreach a40_bridge_keepout $a40_bridge_keepouts {
        foreach a40_bridge_keepout_layer {Metal2 Metal3} {
            create_obstruction -region $a40_bridge_keepout -layer $a40_bridge_keepout_layer -except_pg
        }
        puts "PDN: A40 bridge SIGNAL keepout (M2/M3, -except_pg) over ($a40_bridge_keepout) um"
    }
}

if { $::env(PDN_MULTILAYER) == 1 } {
    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }
    define_pdn_grid -name stdcell_grid -starts_with POWER -voltage_domain CORE {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_VERTICAL_LAYER) -width $::env(PDN_VWIDTH) -pitch $::env(PDN_VPITCH) -offset $::env(PDN_VOFFSET) -spacing $::env(PDN_VSPACING) -starts_with POWER {*}$arg_list
    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_HORIZONTAL_LAYER) -width $::env(PDN_HWIDTH) -pitch $::env(PDN_HPITCH) -offset $::env(PDN_HOFFSET) -spacing $::env(PDN_HSPACING) -starts_with POWER {*}$arg_list
    add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
} else {
    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
    }
    define_pdn_grid -name stdcell_grid -starts_with POWER -voltage_domain CORE {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_VERTICAL_LAYER) -width $::env(PDN_VWIDTH) -pitch $::env(PDN_VPITCH) -offset $::env(PDN_VOFFSET) -spacing $::env(PDN_VSPACING) -starts_with POWER {*}$arg_list
}

if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_RAIL_LAYER) -width $::env(PDN_RAIL_WIDTH) -followpins
    add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}

if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        append_if_flag arg_list PDN_CORE_RING_CONNECT_TO_PADS -connect_to_pads
        append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

        set pdn_core_vertical_layer $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)
        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }
        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring -grid stdcell_grid -layers "$pdn_core_vertical_layer $pdn_core_horizontal_layer" -widths "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" -core_offset "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" {*}$arg_list

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
        }
        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_CORE_HORIZONTAL_LAYER) $::env(PDN_VERTICAL_LAYER)"
        }
        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] && [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_CORE_HORIZONTAL_LAYER)"
        }
    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}


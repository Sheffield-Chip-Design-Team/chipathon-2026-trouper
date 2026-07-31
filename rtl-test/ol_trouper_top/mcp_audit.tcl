# MCP SDC audit for a post-synthesis or post-route netlist.
#
# Required environment: MCP_AUDIT_LIBERTY, MCP_AUDIT_TECH_LEF,
# MCP_AUDIT_CELL_LEF, MCP_AUDIT_NETLIST, MCP_AUDIT_SDC, MCP_AUDIT_STAGE,
# MCP_AUDIT_REPORT.  MCP_AUDIT_SPEF is optional.
# The SDC is sourced unchanged.  Its mcp_audit_groups table is the contract
# between the timing constraints and the independent JSON manifest.

foreach required {MCP_AUDIT_LIBERTY MCP_AUDIT_TECH_LEF MCP_AUDIT_CELL_LEF MCP_AUDIT_NETLIST MCP_AUDIT_SDC MCP_AUDIT_STAGE MCP_AUDIT_REPORT} {
    if {![info exists ::env($required)] || $::env($required) eq ""} {
        puts stderr "MCP audit: required environment variable $required is unset"
        exit 2
    }
}
set liberty $::env(MCP_AUDIT_LIBERTY)
set tech_lef $::env(MCP_AUDIT_TECH_LEF)
set cell_lef $::env(MCP_AUDIT_CELL_LEF)
set netlist $::env(MCP_AUDIT_NETLIST)
set sdc     $::env(MCP_AUDIT_SDC)
set stage   $::env(MCP_AUDIT_STAGE)
set report  $::env(MCP_AUDIT_REPORT)
set spef    ""
if {[info exists ::env(MCP_AUDIT_SPEF)]} { set spef $::env(MCP_AUDIT_SPEF) }

read_lef $tech_lef
read_lef $cell_lef
read_liberty $liberty
read_verilog $netlist
link_design trouper_top
if {$spef ne ""} { read_spef $spef }
source $sdc

set fp [open $report w]
proc emit {line} {
    global fp
    puts $fp $line
    puts $line
}
proc collection_size {variable_name} {
    if {$variable_name eq ""} { return 0 }
    upvar #0 $variable_name object_collection
    if {![info exists object_collection]} {
        error "MCP audit collection '$variable_name' was not defined by SDC"
    }
    # OpenROAD 26Q2 exposes timing-object collections as Tcl lists; unlike
    # older OpenSTA builds it does not provide sizeof_collection.
    return [llength $object_collection]
}
proc collection_object_names {variable_name} {
    if {$variable_name eq ""} { return {} }
    upvar #0 $variable_name object_collection
    set result {}
    foreach object $object_collection {
        lappend result [get_full_name $object]
    }
    return [lsort $result]
}

emit "MCP_AUDIT|stage|$stage"
foreach group $mcp_audit_groups {
    lassign $group id setup hold through_variable endpoint_variable
    set through_count [collection_size $through_variable]
    set endpoint_count [collection_size $endpoint_variable]
    emit "MCP_GROUP|$id|$setup|$hold|$through_count|$endpoint_count"
    foreach object_name [collection_object_names $through_variable] {
        emit "MCP_OBJECT|$id|through|$object_name"
    }
    foreach object_name [collection_object_names $endpoint_variable] {
        emit "MCP_OBJECT|$id|endpoint|$object_name"
    }

}
close $fp

# Magic spice extraction of the BRIDGED trouper_top GDS, std cells forced to
# LEF-abstract so this is a top-level-interconnect extraction (same class as the
# base-streamout flow LVS) -- but from the GDS, so the 12 PDN bridges are in it.
gds readonly true
gds rescale false
gds read /foss/designs/pd/bridged_lvs/trouper_top_bridged.gds

# annotate std-cell port order from the PDK spice
readspice /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/spice/gf180mcu_fd_sc_mcu7t5v0.spice

# abstract every std cell (do not descend into it during extraction)
set n 0
foreach cell [cellname list allcells] {
    if {[regexp {^gf180mcu_fd_sc_mcu7t5v0__} $cell]} {
        load $cell
        property LEFview true
        incr n
    }
}
puts "abstracted $n std cells"

load trouper_top -dereference
select top cell

set extdir /foss/runs/extraction
file mkdir $extdir
cd $extdir

extract do local
extract no capacitance
extract no coupling
extract no resistance
extract no adjust
extract unique all
extract

ext2spice lvs
ext2spice -o /foss/runs/trouper_top_bridged.spice trouper_top.ext
puts "EXTRACTION DONE"
quit -noprompt

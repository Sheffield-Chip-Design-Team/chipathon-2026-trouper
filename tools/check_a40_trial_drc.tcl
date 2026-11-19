# Magic batch DRC for the review-only A40 assembled-GDS trial.
gds readonly true
gds read $::env(TRIAL_GDS)
if {[info exists ::env(TRIAL_TOP)]} {
    load $::env(TRIAL_TOP)
} else {
    load SSCS_2026_01
}
drc euclidean on
drc check
drc catchup
puts "A40_TRIAL_DRC_COUNT [drc count total]"
set drc_details [drc listall why]
puts "A40_TRIAL_DRC_DETAILS $drc_details"
quit -noprompt

gds readonly true
gds read $::env(TRIAL_GDS)
load $::env(TRIAL_TOP)
drc euclidean on
drc check
drc catchup
puts "TOTAL [drc count total]"
for {set i 0} {$i < 12} {incr i} {
    drc find
    puts "SAMPLE $i BOX=[box values] WHY=[drc why]"
}
quit -noprompt

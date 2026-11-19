puts "== step1 =="
if {[catch {open_hw_manager} err]} { puts "ERR1: $err" }
puts "== step2 =="
if {[catch {connect_hw_server} err]} { puts "ERR2: $err" }
puts "== step3 =="
if {[catch {set targets [get_hw_targets]} err]} { puts "ERR3: $err" } else { puts "TARGETS: $targets" }
puts "== done =="
exit

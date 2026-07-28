# Census: do the egress_agg counter flops exist, and under what name, in
#   (a) the ROUTED design the .bit came from, vs (b) the user SYNTH checkpoint?
# agg6 found ZERO cells named *egress_agg_*_reg[0]* in the routed dcp -- find out if they were
# deleted, renamed, or merged.
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg7.tcl -tclargs build-34 | tee agg7_out.txt

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }

proc census {tag} {
    foreach pat {*egress_agg* *egress* *agg_beats* *agg_window* *agg_stalled*} {
        set cs [get_cells -hier -quiet -filter "NAME =~ $pat"]
        puts "\n  \[$tag\] cells matching $pat : [llength $cs]"
        set i 0
        foreach c $cs {
            puts "      [get_property REF_NAME $c]  [get_property NAME $c]"
            if {[incr i] >= 15} { puts "      ... ([llength $cs] total)"; break }
        }
    }
    set ns [get_nets -hier -quiet -filter "NAME =~ *egress_agg*"]
    puts "\n  \[$tag\] nets matching *egress_agg* : [llength $ns]"
    set i 0
    foreach n $ns {
        puts "      TYPE=[get_property TYPE $n]  [get_property NAME $n]"
        if {[incr i] >= 15} { puts "      ... ([llength $ns] total)"; break }
    }
}

puts "\n################ ROUTED ($build/checkpoints/shell_routed.dcp) ################"
open_checkpoint "$build/checkpoints/shell_routed.dcp"
census ROUTED
close_project

puts "\n################ SYNTH ($build/checkpoints/config_0/user_synthed_c0_0.dcp) ################"
open_checkpoint "$build/checkpoints/config_0/user_synthed_c0_0.dcp"
census SYNTH
close_project

puts "\n== done =="

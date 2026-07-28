# The decisive dump: the RESET cone of the aggregate counters.
# PROVEN on hardware: reading local reg 18 (beats) CLEARS the set; reading 20 alone does not.
# Source says agg_stop fires at read_addr==20. So dump what actually drives the counter flops'
# R pins in the netlist: the comparator LUT(s), their INITs, and which read_addr bits feed them.
# Run on BOTH checkpoints to see where the wrong constant appears (synth vs link-opt).
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg8.tcl -tclargs build-34 | tee agg8_out.txt

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }

proc dump_reset_cone {} {
    foreach fname {egress_agg_window_reg[0] egress_agg_beats_reg[0] egress_agg_started_reg} {
        set fs [get_cells -hier -quiet -filter "NAME =~ *inst_user_c0_0*${fname}*"]
        if {[llength $fs] == 0} { puts "\n  -- $fname : NOT FOUND"; continue }
        set f [lindex $fs 0]
        puts "\n  -- $fname : [get_property NAME $f] REF=[get_property REF_NAME $f] ([llength $fs] match(es))"
        # FDRE reset pin is R; also dump CE for completeness
        foreach pinname {R CE D} {
            set p [get_pins -quiet -of $f -filter "REF_PIN_NAME == $pinname"]
            if {[llength $p] == 0} { continue }
            set n [get_nets -quiet -of $p]
            if {[llength $n] == 0} { continue }
            puts "     pin $pinname <= net [get_property NAME $n] (TYPE=[get_property TYPE $n])"
            set drv [get_pins -leaf -quiet -of $n -filter {DIRECTION == OUT}]
            if {[llength $drv] == 0} { continue }
            set dc [lindex [get_cells -of [lindex $drv 0]] 0]
            set init ""
            catch { set init [get_property INIT $dc] }
            puts "        L1 driver [get_property NAME $dc] REF=[get_property REF_NAME $dc] INIT=$init"
            if {![string match LUT* [get_property REF_NAME $dc]]} { continue }
            foreach p2 [lsort [get_pins -of $dc -filter {DIRECTION == IN}]] {
                set n2 [get_nets -quiet -of $p2]
                if {[llength $n2] == 0} { continue }
                puts "           [get_property REF_PIN_NAME $p2] <= [get_property NAME $n2] (TYPE=[get_property TYPE $n2])"
                set drv2 [get_pins -leaf -quiet -of $n2 -filter {DIRECTION == OUT}]
                if {[llength $drv2] == 0} { continue }
                set dc2 [lindex [get_cells -of [lindex $drv2 0]] 0]
                set init2 ""
                catch { set init2 [get_property INIT $dc2] }
                puts "              L2 driver [get_property NAME $dc2] REF=[get_property REF_NAME $dc2] INIT=$init2"
                if {[string match LUT* [get_property REF_NAME $dc2]]} {
                    foreach p3 [lsort [get_pins -of $dc2 -filter {DIRECTION == IN}]] {
                        set n3 [get_nets -quiet -of $p3]
                        if {[llength $n3] == 0} { continue }
                        puts "                 [get_property REF_PIN_NAME $p3] <= [get_property NAME $n3]"
                    }
                }
            }
        }
    }
}

puts "\n################ SYNTH (user_synthed_c0_0.dcp) ################"
open_checkpoint "$build/checkpoints/config_0/user_synthed_c0_0.dcp"
dump_reset_cone
close_project

puts "\n################ ROUTED (shell_routed.dcp) ################"
open_checkpoint "$build/checkpoints/shell_routed.dcp"
dump_reset_cone
close_project

puts "\n== done =="

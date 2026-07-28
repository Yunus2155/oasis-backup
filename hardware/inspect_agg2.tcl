# Trace where the aggregate counter register OUTPUTS (Q) go. beats reads correctly, window reads 0,
# yet both registers exist. This checks whether window's Q actually fans out into the profile-config
# read path (like beats does) or is left dangling / tied.
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg2.tcl -tclargs build-34

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }
open_checkpoint "$build/checkpoints/config_0/user_synthed_c0_0.dcp"

proc trace_q {sig} {
    puts "\n===== $sig : Q fanout ====="
    set cells [get_cells -hier -filter "NAME =~ *${sig}_reg*"]
    puts "  flops: [llength $cells]"
    if {[llength $cells] == 0} { return }
    # take bit 0
    set c0 [lindex [lsort $cells] 0]
    set qpin [get_pins -of $c0 -filter "REF_PIN_NAME == Q"]
    if {[llength $qpin] == 0} { puts "  (no Q pin?)"; return }
    set qnet [get_nets -of $qpin]
    puts "  bit0 Q-net = [get_property NAME $qnet]"
    # loads on that net (input pins it drives)
    set loads [get_pins -leaf -of $qnet -filter "DIRECTION == IN"]
    puts "  #loads on bit0 Q-net = [llength $loads]"
    set i 0
    foreach l $loads {
        if {$i >= 6} { puts "  ... ([expr [llength $loads]-6] more)"; break }
        puts "    load: [get_property NAME $l]"
        incr i
    }
    # Does ANY bit of this register reach the profile-config read register file?
    set reached 0
    foreach c $cells {
        set qp [get_pins -of $c -filter "REF_PIN_NAME == Q"]
        set qn [get_nets -of $qp]
        set ld [get_pins -leaf -of $qn -filter "DIRECTION == IN"]
        foreach l $ld {
            if {[string match "*zscore_profile_config*" [get_property NAME $l]] ||
                [string match "*inst_read_regs*"       [get_property NAME $l]] ||
                [string match "*config*read*"          [get_property NAME $l]]} {
                set reached 1; break
            }
        }
        if {$reached} break
    }
    puts "  reaches profile-config read path? => $reached"
}

trace_q egress_agg_beats
trace_q egress_agg_window
trace_q egress_agg_stalled

puts "\n== done =="
close_project

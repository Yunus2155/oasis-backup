# Interrogate the synthesized user netlist for the egress aggregate counter registers.
# Decides: did synthesis keep egress_agg_stalled / egress_agg_window as real driven flops,
# or prune/tie them (which would explain the hardware reading 0)?
#
# Run (Yunus, on hacc-build-02, after sourcing Vivado settings):
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg.tcl -tclargs build-34
#
# (defaults to build-34 if no arg)

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }
set dcp "$build/checkpoints/config_0/user_synthed_c0_0.dcp"
puts "== opening $dcp =="
open_checkpoint $dcp

foreach sig {egress_agg_beats egress_agg_stalled egress_agg_window egress_agg_started} {
    puts "\n===== $sig ====="
    # Flops synthesize to one cell per bit, named <sig>_reg[<bit>] (possibly hierarchical).
    set cells [get_cells -hier -filter "NAME =~ *${sig}_reg*"]
    if {[llength $cells] == 0} {
        puts "  NO FLOPS FOUND  -> synthesis removed/absorbed '$sig' (likely optimized to constant)."
        # Is there a tied constant net where the register output should be?
        set nets [get_nets -hier -filter "NAME =~ *${sig}*"]
        puts "  nets matching name: [llength $nets]"
        continue
    }
    puts "  flop cells: [llength $cells]"
    # Sample a few: report each flop's D-input driver. If D is tied to GND/const, the counter is dead.
    set i 0
    foreach c $cells {
        if {$i >= 4} { puts "  ... ([expr [llength $cells]-4] more)"; break }
        set dpin [get_pins -of $c -filter "REF_PIN_NAME == D"]
        set dnet [get_nets -of $dpin]
        set drv  [get_pins -leaf -of $dnet -filter "DIRECTION == OUT"]
        puts "  $c  D-net=[get_property NAME $dnet]  driver=[get_property NAME $drv]"
        incr i
    }
}

# Also: is values[19]/[20] (1-lane) reachable in the profile config read mux? Check the config cell.
puts "\n===== ConfigReadRegisterFile inside zscore_profile_config ====="
set cfg [get_cells -hier -filter "NAME =~ *zscore_profile_config*inst_read_regs*" ]
puts "  read-reg-file cells matched: [llength $cfg]"

puts "\n== done =="
close_project

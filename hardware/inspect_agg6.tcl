# Forward-trace the three aggregate counters through the read mux in the ROUTED netlist.
# beats (works) vs stalled/window (read 0): diff their select cones to find where they diverge.
# Fixes over inspect_agg5.tcl: string-based dedup (no object lsearch), no fragile generic walk.
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg6.tcl -tclargs build-34 | tee agg6_out.txt

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }
open_checkpoint "$build/checkpoints/shell_routed.dcp"

proc dump_driver {net indent} {
    set drv [get_pins -leaf -of $net -filter {DIRECTION == OUT}]
    if {[llength $drv] == 0} {
        puts "${indent}driver: (none) net TYPE=[get_property TYPE $net]"
        return ""
    }
    set dc [lindex [get_cells -of [lindex $drv 0]] 0]
    set init ""
    catch { set init [get_property INIT $dc] }
    puts "${indent}driver: [get_property NAME $dc] REF=[get_property REF_NAME $dc] INIT=$init"
    return $dc
}

foreach ctr {egress_agg_beats egress_agg_stalled egress_agg_window} {
    puts "\n########## $ctr ##########"
    # bit-0 flop of the counter (there may be replicas; take them all, dedup by name)
    set flops [get_cells -hier -filter "NAME =~ *inst_user_c0_0*${ctr}_reg\\\[0\\\]*"]
    puts "  [llength $flops] flop(s) for ${ctr}\[0\]"
    if {[llength $flops] == 0} { continue }

    set seen_luts {}
    foreach f $flops {
        set qnet [get_nets -of [get_pins -of $f -filter {REF_PIN_NAME == Q}]]
        if {[llength $qnet] == 0} { continue }
        # every non-flop cell this counter bit feeds
        foreach lp [get_pins -leaf -of $qnet -filter {DIRECTION == IN}] {
            set lc [lindex [get_cells -of $lp] 0]
            set lname [get_property NAME $lc]
            set lref  [get_property REF_NAME $lc]
            if {![string match LUT* $lref]} { continue }
            if {[lsearch -exact $seen_luts $lname] >= 0} { continue }
            lappend seen_luts $lname
            set init ""
            catch { set init [get_property INIT $lc] }
            puts "\n  MUX-LUT $lname"
            puts "      REF=$lref INIT=$init   (counter enters on pin [get_property REF_PIN_NAME $lp])"
            # dump every input of this mux LUT and one level of its drivers
            foreach p [lsort [get_pins -of $lc -filter {DIRECTION == IN}]] {
                set n [get_nets -of $p]
                if {[llength $n] == 0} { continue }
                puts "      [get_property REF_PIN_NAME $p] <= [get_property NAME $n]"
                set dc [dump_driver $n "          "]
                # if the driver is itself a LUT (comparator candidate), dump ITS input nets too
                if {$dc ne "" && [string match LUT* [get_property REF_NAME $dc]]} {
                    foreach p2 [lsort [get_pins -of $dc -filter {DIRECTION == IN}]] {
                        set n2 [get_nets -of $p2]
                        if {[llength $n2] == 0} { continue }
                        puts "              [get_property REF_PIN_NAME $p2] <= [get_property NAME $n2]"
                    }
                }
            }
        }
    }
}

puts "\n== done =="
close_project

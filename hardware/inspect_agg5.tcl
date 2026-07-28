# Fresh-eye follow-up to inspect_agg4.tcl, with two fixes:
#   1. Inspect the ROUTED checkpoint (shell_routed.dcp) -- the exact netlist the .bit was written
#      from. All earlier inspection used user_synthed_c0_0.dcp, which is PRE link-time
#      opt_design/phys_opt; those passes can transform or constant-fold logic, so a clean synth
#      netlist does not prove the flashed netlist is clean.
#   2. Find the comparator cones by CONNECTIVITY (walk drivers backward from the resp_data mux),
#      not by guessed cell names -- the old name filters missed the "in\." prefix / "__0" replicas.
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg5.tcl -tclargs build-34 | tee agg5_out.txt
#
# What to look for in the output:
#   - Any read_addr-related net whose driver is GND/VCC (const-folded address bit) = smoking gun.
#   - The select-input drivers of the resp_data mux LUT: three comparator LUTs should appear, one
#     per aggregate register. If only ONE comparator exists (beats) the decode for 19/20 was lost.
#   - Each comparator's INIT + its input nets: decode by hand which local address it matches.

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }
open_checkpoint "$build/checkpoints/shell_routed.dcp"

set SP "*inst_user_c0_0*inst_read_config_splitter*"

# -- 1. Constant-tied nets anywhere in the user config subsystem -----------------------------------
puts "\n===== const-tied (GROUND/POWER) nets matching *read_addr* / *araddr* in the user region ====="
foreach pat {*inst_user_c0_0*read_addr* *inst_user_c0_0*araddr*} {
    foreach n [get_nets -hier -filter "NAME =~ $pat"] {
        set t [get_property TYPE $n]
        if {$t eq "GROUND" || $t eq "POWER"} { puts "  $t : [get_property NAME $n]" }
    }
}
puts "  (nothing above this line except the header = no address bit was const-folded)"

# -- 2. The final resp_data mux LUTs and everything driving their select pins ----------------------
# The 64 resp_data bits share the same select tree; bit 0 is enough. Walk 2 levels of drivers.
puts "\n===== resp_data mux cone (2 levels of drivers) ====="
set muxes [get_cells -hier -filter "NAME =~ ${SP}*resp_data*i_*"]
puts "  [llength $muxes] cells match ${SP}*resp_data*i_* :"
foreach c $muxes {
    puts "  CELL [get_property NAME $c]  REF=[get_property REF_NAME $c]"
    catch { puts "       INIT=[get_property INIT $c]" }
}

# -- 3. Walk backward from one final mux LUT: level-1 and level-2 driver cells with INITs ----------
puts "\n===== backward walk from the first resp_data mux LUT ====="
if {[llength $muxes] > 0} {
    set seen {}
    set frontier [lindex $muxes 0]
    for {set lvl 1} {$lvl <= 2} {incr lvl} {
        set next {}
        foreach c $frontier {
            foreach p [get_pins -of $c -filter {DIRECTION == IN}] {
                set n [get_nets -of $p]
                if {[llength $n] == 0} { continue }
                set drv [get_pins -leaf -of $n -filter {DIRECTION == OUT}]
                if {[llength $drv] == 0} { puts "    L$lvl [get_property REF_PIN_NAME $p] <= [get_property NAME $n]  (const/undriven: TYPE=[get_property TYPE $n])"; continue }
                set dc [get_cells -of [lindex $drv 0]]
                if {[lsearch $seen $dc] >= 0} { continue }
                lappend seen $dc
                lappend next $dc
                set init ""
                catch { set init [get_property INIT $dc] }
                puts "    L$lvl [get_property REF_PIN_NAME $p] <= [get_property NAME $n]"
                puts "         drv cell [get_property NAME $dc] REF=[get_property REF_NAME $dc] INIT=$init"
            }
        }
        set frontier $next
    }
}

# -- 4. For each driver cell that looks like an address comparator, dump its full input list ------
puts "\n===== input nets of every LUT under the splitter whose name suggests addr compare ====="
foreach c [get_cells -hier -filter "NAME =~ ${SP}*"] {
    set ref [get_property REF_NAME $c]
    if {![string match LUT* $ref]} { continue }
    set nm [get_property NAME $c]
    # comparators typically end up named after the signal they drive; be permissive
    if {![string match *addr* $nm] && ![string match *match* $nm]} { continue }
    set init ""
    catch { set init [get_property INIT $c] }
    puts "  CMP $nm REF=$ref INIT=$init"
    foreach p [lsort [get_pins -of $c -filter {DIRECTION == IN}]] {
        set n [get_nets -of $p]
        puts "      [get_property REF_PIN_NAME $p] <= [get_property NAME $n]"
    }
}

puts "\n== done =="
close_project

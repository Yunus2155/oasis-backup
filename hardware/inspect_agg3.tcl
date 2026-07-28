# Dump the resp_data mux LUT that all three aggregate counters feed. beats(I1) reads correctly but
# stalled(I3)/window(I4) read 0 -- so this LUT (or its select inputs) is the culprit. Report its
# INIT equation and what drives each input pin, especially the select lines.
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg3.tcl -tclargs build-34

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }
open_checkpoint "$build/checkpoints/config_0/user_synthed_c0_0.dcp"

# The mux LUT the trace found. Match loosely in case the name escaping differs.
set luts [get_cells -hier -filter {NAME =~ *inst_read_config_splitter*resp_data*i_2__0*}]
puts "\n== matched mux LUTs: [llength $luts] =="
foreach lut $luts {
    puts "\n---- $lut ----"
    puts "  REF   = [get_property REF_NAME $lut]"
    puts "  INIT  = [get_property INIT $lut]"
    # For each input pin, show the driver so we can tell data inputs from select inputs.
    foreach p [lsort [get_pins -of $lut -filter {DIRECTION == IN}]] {
        set n   [get_nets -of $p]
        set drv [get_pins -leaf -of $n -filter {DIRECTION == OUT}]
        set dn  ""
        if {[llength $drv]} { set dn [get_property NAME [lindex $drv 0]] }
        puts "  [get_property REF_PIN_NAME $p]  <=  net [get_property NAME $n]   drv=$dn"
    }
}

# Also dump the whole bit-0 resp_data mux cone (a couple levels) so we see the select tree.
puts "\n== all resp_data\[0\] mux LUTs in the splitter =="
foreach c [get_cells -hier -filter {NAME =~ *inst_read_config_splitter*resp_data\[0\]*}] {
    puts "  [get_property REF_NAME $c]  $c"
}

# And what feeds the address compare: the read_addr bits into this config's register file.
puts "\n== nets named *read_addr* feeding the profile config =="
set an [get_nets -hier -filter {NAME =~ *zscore_profile_config*read_addr*}]
puts "  count=[llength $an]"
foreach n [lrange $an 0 8] { puts "  [get_property NAME $n]" }

puts "\n== done =="
close_project

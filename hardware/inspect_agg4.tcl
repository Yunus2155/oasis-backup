# The mux is correct; beats reads. So addr_matches_19 / addr_matches_20 must not be asserting.
# Dump those comparators + addr_matches_18 (works) and the read_addr bits feeding them, to see if
# read_addr is truncated / mis-decoded for the top-of-map addresses.
#
#   cd ~/oasis/hardware
#   vivado -mode batch -source inspect_agg4.tcl -tclargs build-34

set build "build-34"
if {$argc >= 1} { set build [lindex $argv 0] }
open_checkpoint "$build/checkpoints/config_0/user_synthed_c0_0.dcp"

# The comparator carry-LUTs that drive addr_matches_18/19/20 (found earlier: _i_8/_i_9/_i_10).
foreach idx {8 9 10} {
    puts "\n===== resp_data_reg\[63\]_i_$idx (addr compare -> addr_matches_[expr 10+$idx]) ====="
    set c [get_cells -hier -filter "NAME =~ *inst_read_config_splitter*resp_data_reg\\\[63\\\]_i_$idx"]
    if {[llength $c]==0} { puts "  (not found)"; continue }
    set c [lindex $c 0]
    puts "  cell = $c   REF=[get_property REF_NAME $c]"
    catch { puts "  INIT = [get_property INIT $c]" }
    foreach p [lsort [get_pins -of $c -filter {DIRECTION == IN}]] {
        set n [get_nets -of $p]
        set drv [get_pins -leaf -of $n -filter {DIRECTION == OUT}]
        set dn ""; if {[llength $drv]} { set dn [get_property NAME [lindex $drv 0]] }
        puts "    [get_property REF_PIN_NAME $p] <= [get_property NAME $n]   drv=$dn"
    }
}

# All nets carrying the profile config's local read_addr, to see its width.
puts "\n===== read_addr nets into zscore_profile_config ====="
set an [get_nets -hier -filter {NAME =~ *inst_read_config_splitter*read_addr*}]
puts "  matched [llength $an] nets:"
foreach n [lsort $an] { puts "    [get_property NAME $n]" }

puts "\n== done =="
close_project

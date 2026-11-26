# HDLPhy stage 4: clock tree synthesis and timing repair (only buffering when there is no clock).
source [file join $::env(HDLPHY_SCRIPTS) common.tcl]
load_stage 3_place.odb

if {[env_or HAS_CLOCK 0]} {
  clock_tree_synthesis -root_buf $::env(SCL)__clkbuf_16 \
    -buf_list [list $::env(SCL)__clkbuf_4 $::env(SCL)__clkbuf_8] -sink_clustering_enable
  set_propagated_clock [all_clocks]
  estimate_parasitics -placement
  repair_clock_nets
  detailed_placement
  estimate_parasitics -placement
  repair_timing -setup -hold -hold_margin 0.05
  detailed_placement
} else {
  puts "No clock: skipping clock tree synthesis"
  estimate_parasitics -placement
  repair_timing -setup
  detailed_placement
}
check_placement -verbose

report_metrics cts
save_stage 4_cts

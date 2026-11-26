# HDLPhy stage 5: routing — global and detailed routing on met1..met5, then filler cells.
source [file join $::env(HDLPHY_SCRIPTS) common.tcl]
load_stage 4_cts.odb
if {[llength [all_clocks]] && [env_or HAS_CLOCK 1]} { catch { set_propagated_clock [all_clocks] } }

set_routing_layers -signal met1-met5 -clock met1-met5
global_route -congestion_iterations 50 -verbose
estimate_parasitics -global_routing

detailed_route -output_drc [report_file drc.rpt] -verbose 1

# fill the empty sites (decaps first, then plain fill cells)
filler_placement [list $::env(SCL)__decap_* $::env(SCL)__fill_*]
check_placement

# power grid: every cell's VPWR/VGND/VPB/VNB pin on its net, and every VPWR/VGND shape connected to the pins
connect_pg
metric pg_unconnected_pins [unconnected_pg_pins]
foreach net {VPWR VGND} {
  set ok 0
  catch { set ok [check_power_grid -net $net -error_file [report_file pdn_$net.rpt]] }
  metric pdn_[string tolower $net]_connected [expr {$ok ? 1 : 0}]
}

# reports
set_propagated_clock [all_clocks]
report_checks -path_delay max -fields {slew cap input nets fanout} -format full_clock_expanded > [report_file timing_setup.rpt]
report_checks -path_delay min -fields {slew cap input nets fanout} -format full_clock_expanded > [report_file timing_hold.rpt]
report_power > [report_file power.rpt]
report_design_area > [report_file area.rpt]
report_metrics route

# wire length and the DRC count come from the router log (hdlphy_flow.py)
catch {
  set pw [sta::design_power [sta::cmd_scene]]
  metric power_total_w [format %.4g [lindex $pw 3]]
}

save_stage 5_route
write_def [result final.def]
write_verilog [result final.v]
write_verilog -include_pwr_gnd [result final_pg.v]

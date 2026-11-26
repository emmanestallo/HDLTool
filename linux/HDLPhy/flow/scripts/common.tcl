# HDLPhy: helpers shared by the OpenROAD stage scripts.
# Parameters come from the environment (set by hdlphy_flow.py).

proc env_or {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $default
}

# One "##HDLPHY-METRIC <key> <value>" line per metric; hdlphy_flow.py collects them into metrics.json.
proc metric {key value} { puts "##HDLPHY-METRIC $key $value" }

proc result {name} { return [file join $::env(RESULTS) $name] }
proc report_file {name} { return [file join $::env(REPORTS) $name] }

proc read_libs {} {
  read_liberty $::env(LIB)
}

# Parasitics from the technology LEF: signal wires on met2, clock wires on met5.
proc set_rc {} {
  set_wire_rc -signal -layer met2
  set_wire_rc -clock -layer met5
}

proc set_dont_use_cells {} {
  set cells [env_or DONT_USE_CELLS ""]
  if {$cells ne ""} { set_dont_use $cells }
}

# Loads the database written by the previous stage.
proc load_stage {odb} {
  read_libs
  read_db [result $odb]
  read_sdc $::env(SDC)
  set_rc
  set_dont_use_cells
}

# Power and ground pins of every cell to VPWR/VGND. The rules (floorplan.tcl) are kept in the database,
# so this also connects the cells added since: buffers from repair_design/repair_timing, clock buffers, fillers.
proc connect_pg {} { global_connect }

# Number of cell power/ground pins with no net (0 when connect_pg has run after the last cell was added)
proc unconnected_pg_pins {} {
  set n 0
  foreach inst [[ord::get_db_block] getInsts] {
    foreach it [$inst getITerms] {
      set st [[$it getMTerm] getSigType]
      if {($st eq "POWER" || $st eq "GROUND") && [$it getNet] eq "NULL"} { incr n }
    }
  }
  return $n
}

proc save_stage {name} {
  connect_pg
  write_db [result $name.odb]
  write_def [result $name.def]
}

proc report_metrics {stage} {
  # worst setup / hold slack and total negative slack (ns), when the design has timing paths
  if {[catch {
    metric ${stage}_wns [sta::format_time [sta::worst_slack_cmd max] 4]
    metric ${stage}_whs [sta::format_time [sta::worst_slack_cmd min] 4]
    metric ${stage}_tns [sta::format_time [sta::total_negative_slack_cmd max] 4]
  } err]} { puts "timing metrics unavailable: $err" }
  metric ${stage}_design_area [format %.2f [expr {[rsz::design_area] * 1e12}]]
  metric ${stage}_instances [llength [[ord::get_db_block] getInsts]]
}

# HDLPhy stage 3: placement — global placement, I/O pins, electrical repair, detailed placement.
source [file join $::env(HDLPHY_SCRIPTS) common.tcl]
load_stage 2_floorplan.odb

set density [env_or PLACE_DENSITY 0.6]
global_placement -skip_io -density $density
place_pins -hor_layers met3 -ver_layers met2
global_placement -density $density

estimate_parasitics -placement
repair_design
detailed_placement
optimize_mirroring
check_placement -verbose

report_metrics place
save_stage 3_place

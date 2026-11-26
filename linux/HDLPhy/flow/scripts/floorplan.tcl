# HDLPhy stage 2: floorplan — die and core, rows, routing tracks, tap cells, power grid.
source [file join $::env(HDLPHY_SCRIPTS) common.tcl]

read_lef $::env(TECH_LEF)
read_lef $::env(CELL_LEF)
read_libs
read_verilog [result netlist.v]
link_design $::env(TOP)
read_sdc $::env(SDC)
set_rc
set_dont_use_cells

initialize_floorplan -die_area $::env(DIE_AREA) -core_area $::env(CORE_AREA) -site unithd

# Routing tracks from the PDK's tracks.info (layer, direction, offset, pitch)
set tracks [dict create]
set fh [open $::env(TRACKS_INFO)]
while {[gets $fh line] >= 0} {
  if {[regexp {^\s*(\S+)\s+([XY])\s+(\S+)\s+(\S+)} $line -> layer dir off pitch]} {
    dict set tracks $layer $dir [list $off $pitch]
  }
}
close $fh
dict for {layer d} $tracks {
  lassign [dict get $d X] xo xp
  lassign [dict get $d Y] yo yp
  make_tracks $layer -x_offset $xo -x_pitch $xp -y_offset $yo -y_pitch $yp
}

# Well taps every 13 um, decap_3 as end caps (LibreLane's sky130_fd_sc_hd settings)
tapcell -distance 13 -tapcell_master $::env(SCL)__tapvpwrvgnd_1 -endcap_master $::env(SCL)__decap_3

# Power grid: met1 rails along the rows, met4 vertical and met5 horizontal stripes
add_global_connection -net VPWR -pin_pattern {^VPWR$} -power
add_global_connection -net VPWR -pin_pattern {^VPB$}
add_global_connection -net VGND -pin_pattern {^VGND$} -ground
add_global_connection -net VGND -pin_pattern {^VNB$}
global_connect
set_voltage_domain -power VPWR -ground VGND
define_pdn_grid -name stdcell -pins {met4 met5}
add_pdn_stripe -grid stdcell -layer met1 -width 0.48 -followpins
add_pdn_stripe -grid stdcell -layer met4 -width $::env(PDN_WIDTH) -spacing $::env(PDN_SPACING) \
  -pitch $::env(PDN_VPITCH) -offset $::env(PDN_VOFFSET) -starts_with POWER
add_pdn_stripe -grid stdcell -layer met5 -width $::env(PDN_WIDTH) -spacing $::env(PDN_SPACING) \
  -pitch $::env(PDN_HPITCH) -offset $::env(PDN_HOFFSET) -starts_with POWER
add_pdn_connect -grid stdcell -layers {met1 met4}
add_pdn_connect -grid stdcell -layers {met4 met5}
pdngen

report_metrics floorplan
set die [[ord::get_db_block] getDieArea]
metric die_width_um [format %.2f [ord::dbu_to_microns [$die dx]]]
metric die_height_um [format %.2f [ord::dbu_to_microns [$die dy]]]
save_stage 2_floorplan

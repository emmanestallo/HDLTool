# HDLPhy stage 3: placement — global placement, I/O pins, electrical repair, detailed placement.
source [file join $::env(HDLPHY_SCRIPTS) common.tcl]
load_stage 2_floorplan.odb

set density [env_or PLACE_DENSITY 0.6]
global_placement -skip_io -density $density

# Die edge for each group of I/O pins (PIN_*_SIDE: left, right, top or bottom; any other value leaves the
# group to the pin placer). Pins on the left/right edges are on met3, on the top/bottom edges on met2.
proc constrain_pin_sides {} {
  set block [ord::get_db_block]
  set clk [env_or CLOCK_PORT ""]
  set side(input) [string tolower [env_or PIN_INPUT_SIDE any]]
  set side(output) [string tolower [env_or PIN_OUTPUT_SIDE any]]
  set side(clock) [string tolower [env_or PIN_CLOCK_SIDE inputs]]
  if {$side(clock) eq "inputs"} { set side(clock) $side(input) }
  foreach g {input output clock} { set pins($g) {} }
  foreach bt [$block getBTerms] {
    if {[$bt getSigType] in {POWER GROUND}} { continue }
    if {$clk ne "" && [$bt getName] eq $clk} {
      lappend pins(clock) $bt
    } else {
      switch -- [$bt getIoType] { INPUT { lappend pins(input) $bt } OUTPUT { lappend pins(output) $bt } }
    }
  }
  foreach g {input output clock} {
    set edge $side($g)
    if {$edge ni {left right top bottom} || ![llength $pins($g)]} { continue }
    # the whole edge, as set_io_pin_constraint -region $edge:* would give; the pin objects are passed
    # directly, so bus bits such as data[3] need no name matching
    set region [$block findConstraintRegion $edge [ppl::get_edge_extreme "-region" 1 $edge] \
                [ppl::get_edge_extreme "-region" 0 $edge]]
    $block addBTermsToConstraint $pins($g) $region
    puts "HDLPhy: [llength $pins($g)] $g pin(s) on the $edge edge"
  }
}
constrain_pin_sides

# Buses in bit order (PIN_BUS_ORDER ascending or descending; free leaves the order to the pin placer). Each bus
# becomes one ordered pin group: its bits sit next to each other, with the bit index rising (ascending) or
# falling (descending) upwards along the left/right edges and rightwards along the top/bottom edges.
proc group_buses {} {
  set mode [string tolower [env_or PIN_BUS_ORDER free]]
  if {$mode ni {ascending descending}} { return }
  set block [ord::get_db_block]
  set buses [dict create]
  foreach bt [$block getBTerms] {
    if {[$bt getSigType] in {POWER GROUND}} { continue }
    if {[regexp {^(.+)\[(\d+)\]$} [$bt getName] -> base idx]} { dict lappend buses $base [list $idx $bt] }
  }
  dict for {base bits} $buses {
    if {[llength $bits] < 2} { continue }
    set bits [lsort -integer -index 0 [expr {$mode eq "ascending" ? "-increasing" : "-decreasing"}] $bits]
    $block addBTermGroup [lmap b $bits {lindex $b 1}] 1
    puts "HDLPhy: bus $base, [llength $bits] pins in $mode bit order"
  }
}
group_buses
place_pins -hor_layers met3 -ver_layers met2
global_placement -density $density

estimate_parasitics -placement
repair_design
detailed_placement
optimize_mirroring
check_placement -verbose

report_metrics place
save_stage 3_place

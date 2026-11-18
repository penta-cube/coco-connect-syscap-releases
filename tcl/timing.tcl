# Optional developer timings. No arguments, credentials, CAD values or results
# are recorded. Loading this file while idle also permits disabling diagnostics.
namespace eval ::coco_syscap_timing {
 if {![info exists installed]} {variable installed {}}
 variable starts {};variable log ""
}
foreach hook $::coco_syscap_timing::installed {
 lassign $hook command op callback
 catch {trace remove execution $command $op $callback}
}
set ::coco_syscap_timing::installed {}
set _coco_timing_file ""
catch {set _coco_timing_file $::env(COCO_SYSCAP_TIMING_FILE)}
if {$_coco_timing_file eq ""} {return}
set ::coco_syscap_timing::log $_coco_timing_file
unset _coco_timing_file
if {[catch {file mkdir [file dirname $::coco_syscap_timing::log]}]} {return}
proc ::coco_syscap_timing::enter {label command op} {
 variable starts
 catch {dict lappend starts $label [list [clock microseconds] [clock clicks -microseconds]]}
 return
}
proc ::coco_syscap_timing::leave {label command code result op} {
 variable starts;variable log
 catch {
  set stack [dict get $starts $label];lassign [lindex $stack end] start tick
  dict set starts $label [lrange $stack 0 end-1]
  set elapsed [expr {([clock clicks -microseconds]-$tick)/1000.0}]
  set f [open $log a]
  try {puts $f [format {{"source":"native","stage":"%s","startUs":%s,"durationMs":%.3f,"code":%s}} $label $start $elapsed $code]} finally {close $f}
 }
 return
}
foreach command {
 ::coco_syscap_circuit::profiles ::coco_syscap_circuit::probe ::coco_syscap_electrical::probe
 ::coco_syscap_generation::prepare ::coco_syscap_generation::create ::coco_syscap_generation::inspect
 ::coco_syscap_generation::validateManifest ::coco_syscap_generation::inventory ::coco_syscap_generation::existingState
 ::coco_syscap_generation::persist ::coco_syscap_generation::load ::coco_syscap_generation::snapshot
 ::coco_syscap_generation::applyAppearance ::coco_syscap_generation::appearanceLabels
 ::coco_syscap_electrical::create ::coco_syscap_electrical::snapshot
 ::coco_syscap_native_library::exportCurrent ::cpb::exportDesignCache
 ::insertPageAtEnd ::addComponent ::drawWire ::openItem ::move
 ::update ::cpbf::processEvents ::addPower ::addPort ::annotate ::modifyProp ::textAlign ::rotate
 ::coco_syscap_generation::appearanceRows
 ::coco_syscap_registered::targets ::coco_syscap_registered::checkPins ::coco_syscap_registered::checkAnchor
 ::coco_syscap_registered::inventory ::coco_syscap_registered::pageSymbols ::sch::extractSymbolData
 ::coco_syscap_generation::pages ::sch::dbGetPageItems
} {
 if {[llength [info commands $command]]} {
  set label [string trimleft $command :]
  foreach {op callback} [list enter ::coco_syscap_timing::enter leave ::coco_syscap_timing::leave] {
   set hook [list $callback $label]
   catch {trace remove execution $command $op $hook}
   trace add execution $command $op $hook
   lappend ::coco_syscap_timing::installed [list $command $op $hook]
  }
 }
}

# Fixed, data-only electrical-symbol operations. No source-CAD lookup.
namespace eval ::coco_syscap_electrical {}
proc ::coco_syscap_electrical::anchors {cache library cell view} {
 set lib [::coco_syscap_native_library::directory [file join $cache cache flatlib] $library]
 set cd [::coco_syscap_native_library::directory $lib $cell]
 set vd [::coco_syscap_native_library::directory $cd $view]
 set ascii [glob -nocomplain -directory $vd *.ascii]
 if {[llength $ascii]==1} {
  set pins [::coco_syscap_native_library::pins [::coco_syscap_native_library::textFile [lindex $ascii 0]]]
 } elseif {[llength $ascii]==0} {
  set css [glob -nocomplain -directory $vd *.css]
  if {[llength $css]!=1} {error "Electrical view is not uniquely available"}
  set pins [::coco_syscap_native_library::cssPins [::coco_syscap_native_library::textFile [lindex $css 0]]]
 } else {error "Ambiguous electrical view"}
 if {[dict size $pins]!=1} {error "Electrical symbol requires exactly one declared anchor"}
 return [lindex [dict values $pins] 0]
}
# Palette entries establish Port category and direction; source/cache names do not.
proc ::coco_syscap_electrical::placement {library cell view role} {
 set result [::coco_syscap_native_library::placementCell $library $cell]
 if {![dict get $result available]} {return $result}
 set lcv "$library.$cell:$view";set directions {}
 foreach {key direction} {INPORT 1 OUTPORT 2 IOPORT 3} {
  if {[catch {cps::getDirectiveValue CANVAS $key} entries]} {
   if {$role eq "port"} {return [dict create available false reason "Cannot query native Port palette: $entries"]}
   continue
  }
  foreach entry $entries {if {[string equal -nocase $entry $lcv]} {lappend directions $direction;break}}
 }
 if {[llength $directions]>1} {return [dict create available false reason "Port $lcv has ambiguous palette directions"]}
 if {[llength $directions]==1} {dict set result role port;dict set result portDirection [lindex $directions 0]}
 if {$role eq "port" && ![llength $directions]} {return [dict create available false reason "Port $lcv is not registered in the native Port palette"]}
 return $result
}
proc ::coco_syscap_electrical::probe {arg {sharedCacheVar ""}} {
 foreach key {project library cell view} {
  if {![dict exists $arg $key]} {error "Missing symbol query field $key"}
  set value [dict get $arg $key]
  if {[string length $value]>4096 || [string first \x00 $value]>=0 || ($key ne "view" && [string trim $value] eq "")} {error "Invalid symbol query"}
 }
 if {![string equal -nocase [file normalize [dict get $arg project]] [::coco_syscap_generation::project]]} {error "Symbol query project changed"}
 set library [dict get $arg library];set cell [dict get $arg cell];set view [dict get $arg view]
 set role "";if {[dict exists $arg role]} {set role [dict get $arg role]}
 # Report missing placement libraries/palette entries before attempting cache lookup.
 set availability [::coco_syscap_native_library::placementCell $library $cell]
 if {[dict get $availability available] && $view ne ""} {set availability [placement $library $cell $view $role]}
 if {![dict get $availability available]} {
  set unavailable [::coco_syscap_generation::J [list view [::coco_syscap_generation::Q $view] placement_available false placement_issue [::coco_syscap_generation::Q [dict get $availability reason]]]]
  return [::coco_syscap_utils::json_success [::coco_syscap_generation::J [list version 1 profile_kind [::coco_syscap_generation::Q electrical] session_id [::coco_syscap_generation::Q [::coco_syscap_generation::session]] project [::coco_syscap_generation::Q [::coco_syscap_generation::project]] library [::coco_syscap_generation::Q $library] cell [::coco_syscap_generation::Q $cell] coordinate_frame [::coco_syscap_generation::Q syscap-mil-y-up] symbols [::coco_syscap_generation::A [list $unavailable]]]]]
 }
 if {$sharedCacheVar ne ""} {upvar 1 $sharedCacheVar cache} else {set cache ""}
 if {$cache eq ""} {set cache [::coco_syscap_native_library::exportCurrent]}
 set lib [::coco_syscap_native_library::directory [file join $cache cache flatlib] $library]
 set cd [::coco_syscap_native_library::directory $lib $cell]
 set views {}
 if {$view ne ""} {set views [list $view]} else {
  foreach dir [glob -nocomplain -type d -directory $cd sym_*] {lappend views [file tail $dir]}
 }
 set symbols {}
 foreach candidate $views {
  set pin [anchors $cache $library $cell $candidate]
  set role "";if {[dict exists $arg role]} {set role [dict get $arg role]}
  set placement [placement $library $cell $candidate $role]
  set fields [list view [::coco_syscap_generation::Q $candidate] anchor [::coco_syscap_generation::point $pin] placement_available [dict get $placement available] placement_issue [::coco_syscap_generation::Q [dict get $placement reason]]]
  foreach key {role portDirection} {if {[dict exists $placement $key]} {lappend fields $key [::coco_syscap_generation::Q [dict get $placement $key]]}}
  lappend fields bodyGeometry [::coco_syscap_native_library::bodyGeometry $cache $library $cell $candidate]
  lappend symbols [::coco_syscap_generation::J $fields]
 }
 if {![llength $symbols]} {error "No native electrical symbol view"}
 return [::coco_syscap_utils::json_success [::coco_syscap_generation::J [list version 1 profile_kind [::coco_syscap_generation::Q electrical] \
  session_id [::coco_syscap_generation::Q [::coco_syscap_generation::session]] project [::coco_syscap_generation::Q [::coco_syscap_generation::project]] \
  library [::coco_syscap_generation::Q $library] cell [::coco_syscap_generation::Q $cell] coordinate_frame [::coco_syscap_generation::Q syscap-mil-y-up] symbols [::coco_syscap_generation::A $symbols]]]]
}
proc ::coco_syscap_electrical::validate {manifest cache} {
 if {![dict exists $manifest symbols]} return
 set seen {}
 foreach symbol [dict get $manifest symbols] {
  set id [dict get $symbol id]
  if {$id in $seen} {error "Duplicate electrical symbol identity"};lappend seen $id
  if {[dict get $symbol role] ni {power ground port}} {error "Unconfirmed electrical role"}
  if {[dict get $symbol role] eq "port" && [dict get $symbol portDirection] ni {1 2 3}} {error "Unconfirmed native port direction"}
  set availability [placement [dict get $symbol library] [dict get $symbol cell] [dict get $symbol view] [dict get $symbol role]]
  if {![dict get $availability available]} {error [dict get $availability reason]}
  if {[dict get $symbol role] eq "port" && [dict get $availability portDirection] ne [dict get $symbol portDirection]} {error "Native Port palette direction changed"}
  set r [dict get $symbol rotation]
  if {$r ni {0 90 180 270}} {error "Invalid electrical rotation"}
  if {$cache ne "@registered"} {
  set pin [anchors $cache [dict get $symbol library] [dict get $symbol cell] [dict get $symbol view]]
  if {[dict get $symbol mirrorY]} {dict set pin y [expr {-[dict get $pin y]}]}
  set angle [expr {$r*acos(-1)/180.0}]
  set x [::coco_syscap_generation::number [dict get $symbol position x]];set y [::coco_syscap_generation::number [dict get $symbol position y]]
  set ax [expr {$x+[dict get $pin x]*cos($angle)-[dict get $pin y]*sin($angle)}]
  set ay [expr {$y+[dict get $pin x]*sin($angle)+[dict get $pin y]*cos($angle)}]
  if {abs($ax-[dict get $symbol anchor x])>0.0001 || abs($ay-[dict get $symbol anchor y])>0.0001} {error "Electrical anchor does not match declared pose"}
  } else {
   foreach key {x y} {::coco_syscap_generation::number [dict get $symbol position $key];::coco_syscap_generation::number [dict get $symbol anchor $key]}
  }
  set matches 0
  foreach net [dict get $manifest nets] {
   if {[dict get $net id] ne [dict get $symbol netId]} continue
   incr matches
   if {[dict get $symbol role] in {power ground} && [dict get $net kind] ne [dict get $symbol role]} {error "Net/symbol electrical role conflict"}
  }
  if {$matches!=1} {error "Electrical symbol refers to an unknown net"}
 }
}
proc ::coco_syscap_electrical::create {operation} {
 set record [::coco_syscap_generation::checkpoint $operation]
 set manifest [dict get $record manifest]
 if {![dict exists $manifest symbols]} return
 foreach symbol [dict get $manifest symbols] {
  update
  set record [::coco_syscap_generation::checkpoint $operation]
  set page [dict get $record page];set before [sch::dbGetPageItems $page]
  set pos [list [dict get $symbol position x] [expr {-[dict get $symbol position y]}]]
  set name [dict get [dict get $record netNames] [dict get $symbol netId]]
  dict set record message "Placing electrical symbol [dict get $symbol id]";::coco_syscap_generation::persist $record
  selectWindow canvas
  if {[dict get $symbol role] eq "port"} {
   # Keep -pos as a Tcl list object: a brace-quoted string returns Incomplete
   # in native addPort even when its text contains the same coordinates.
   set command [list addPort [dict get $symbol library] [dict get $symbol cell] [dict get $symbol view] -pg [dict get $record sheetId] -r [expr {-[dict get $symbol rotation]}] -m 0 -pos $pos]
  } else {
   set command [list addPower [dict get $symbol library] [dict get $symbol cell] [dict get $symbol view] -i [list "signame=$name"] -pg [dict get $record sheetId] -r [expr {-[dict get $symbol rotation]}] -m 0 -pos $pos]
   if {[dict get $symbol role] eq "ground"} {lappend command -g}
  }
  set result [{*}$command]
  if {[string equal -nocase [string trim $result] Incomplete]} {error "Native electrical symbol command did not complete"}
  set fresh {}
  foreach item [sch::dbGetPageItems $page] {if {$item ni $before && [sch::dbGetType $item] in {19 20 21}} {lappend fresh $item}}
  if {[llength $fresh]!=1} {error "Expected exactly one native electrical object"}
  set item [lindex $fresh 0]
  set record [::coco_syscap_generation::load $operation];dict set record symbolMap [dict get $symbol id] $item;::coco_syscap_generation::persist $record
  if {[dict get $symbol role] eq "port"} {
   set direction "";foreach pair [sch::dbGetCSPropNameVal $item] {if {[lindex $pair 0] eq "_PORT_DIR_"} {set direction [lindex $pair 1]}}
   if {[sch::dbGetType $item]!=20 || $direction ne [dict get $symbol portDirection]} {error "Native Port category/direction differs from plan"}
  }
  ::coco_syscap_generation::applyPose $item [dict get $record sheetId] $symbol
 }
}
proc ::coco_syscap_electrical::snapshot {record} {
 set out {}
 foreach item [sch::dbGetPageItems [dict get $record page]] {
  set type [sch::dbGetType $item]
  if {$type ni {19 20 21}} continue
  set pins {}
  foreach pin [sch::dbGetChildren $item] {if {[sch::dbGetType $pin]==32} {lappend pins $pin}}
  if {[llength $pins]!=1} {error "Electrical object anchor readback is incomplete"}
  set pin [lindex $pins 0];set routes {};set nets {};set names {}
  foreach route [sch::dbGetConnectedItems $pin] {
   if {[sch::dbGetType $route]!=26} continue
   if {![sch::dbIsPinRouteConnected $pin $route]} {error "Electrical pin/route readback mismatch"}
   lappend routes $route;lappend nets [sch::dbGetSPath $route];lappend names [sch::dbGetItemName $route]
  }
  set nets [lsort -unique $nets]
  if {[llength $nets]>1} {error "Electrical anchor is connected to multiple logical nets"}
  set net null;if {[llength $nets]} {set net [::coco_syscap_generation::Q [lindex $nets 0]]}
  set names [lsort -unique $names];if {[llength $names]>1} {error "Electrical anchor net name conflict"}
  set name "";if {[llength $names]} {set name [lindex $names 0]}
  set direction "";foreach pair [sch::dbGetCSPropNameVal $item] {if {[lindex $pair 0] eq "_PORT_DIR_"} {set direction [lindex $pair 1]}}
  set lcv {};foreach pair [sch::dbGetLibCellView $item] {dict set lcv [lindex $pair 0] [lindex $pair 1]}
  set pose [::coco_syscap_generation::readPose $item]
  lappend out [::coco_syscap_generation::J [list id [::coco_syscap_generation::Q $item] nativeType $type library [::coco_syscap_generation::Q [dict get $lcv library]] \
   cell [::coco_syscap_generation::Q [dict get $lcv cell]] view [::coco_syscap_generation::Q [dict get $lcv view]] \
   bodyGeometry [::coco_syscap_native_library::bodyGeometry [expr {[dict exists $record appearanceCache] ? [dict get $record appearanceCache] : ""}] [dict get $lcv library] [dict get $lcv cell] [dict get $lcv view]] position [dict get $pose position] rotation [dict get $pose rotation] mirrorY [dict get $pose mirrorY] \
   anchor [::coco_syscap_generation::dbpoint [sch::dbGetPos $pin]] pinId [::coco_syscap_generation::Q $pin] \
   netId $net name [::coco_syscap_generation::Q $name] portDirection [::coco_syscap_generation::Q $direction] routeIds [::coco_syscap_generation::strings [lsort -unique $routes]]]]
 }
 return [::coco_syscap_generation::A $out]
}

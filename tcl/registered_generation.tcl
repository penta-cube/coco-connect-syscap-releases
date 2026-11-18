# Registered-source generation. No full-library export or unrelated-page reads.
namespace eval ::coco_syscap_registered {}
proc ::coco_syscap_registered::scoped {manifest} {
 if {![dict exists $manifest readScope]} {return 0}
 if {[dict get $manifest readScope] ni {project generated-sheet}} {error "Unsupported inspection scope"}
 return [expr {[dict get $manifest readScope] eq "generated-sheet"}]
}
proc ::coco_syscap_registered::cache {} {
 set f [file tempfile path [file join $::env(TEMP) coco-syscap-views-]];close $f
 file delete $path;file mkdir $path
 return $path
}
proc ::coco_syscap_registered::encoded {value} {
 if {[string trim $value] eq "" || [string length $value]>4096 || [string first \x00 $value]>=0} {error "Invalid library identifier"}
 set out ""
 foreach c [split $value ""] {scan $c %c n;if {$n<256} {append out [format #%02x $n]} else {append out $c}}
 return $out
}
proc ::coco_syscap_registered::extract {cache library cell view} {
 set path [file join $cache cache flatlib [encoded $library] [encoded $cell] [encoded $view]]
 set file [file join $path symbol.css]
 if {[catch {
  if {![file exists $file]} {
   file mkdir $path
   sch::extractSymbolData $library $cell $view $file
  }
  if {![file isfile $file] || [file size $file]==0} {error "Native symbol extraction returned no data"}
  ::coco_syscap_native_library::cssPins [::coco_syscap_native_library::textFile $file]
 } reason options]} {
  catch {file delete $file}
  return -options $options $reason
 }
 return $file
}
proc ::coco_syscap_registered::targets {arg} {
 set requests [dict get $arg requests]
 if {[llength $requests]>4096} {error "Too many target requests"}
 set project [::coco_syscap_generation::project];set session [::coco_syscap_generation::session]
 set cache [cache];set rows {}
 try {
  foreach request $requests {
   if {[catch {
    set symbols {}
    if {[dict get $request kind] eq "part"} {
     set p [dict get $request params]
     if {[llength $p]!=5} {error "Invalid target identity"}
     lassign $p requested library cell name package
     if {![string equal -nocase [file normalize $requested] $project]} {error "Target project changed"}
     set placement [::coco_syscap_native_library::placementCell $library $cell]
     if {![dict get $placement available]} {error [dict get $placement reason]}
     set views [lsort -unique [sch::getSymbolsListForPart $library $cell $name $package]]
     if {![llength $views] || [llength $views]>64} {error "No bounded symbol views for target part"}
     foreach view $views {
      extract $cache $library $cell $view
      set logical {}
      dict for {key pin} [::coco_syscap_native_library::cssPins [::coco_syscap_native_library::textFile [extract $cache $library $cell $view]]] {
       lappend logical [::coco_syscap_generation::J [list name [::coco_syscap_generation::Q [dict get $pin name]] x [dict get $pin x] y [dict get $pin y]]]
      }
      lappend symbols [::coco_syscap_generation::J [list view [::coco_syscap_generation::Q $view] primitive [::coco_syscap_generation::Q ${name}_$package] logical_pins [::coco_syscap_generation::A $logical] bodyGeometry [::coco_syscap_native_library::bodyGeometry $cache $library $cell $view]]]
     }
     set fields [list metadata_only true library [::coco_syscap_generation::Q $library] cell [::coco_syscap_generation::Q $cell] part_name [::coco_syscap_generation::Q $name] package [::coco_syscap_generation::Q $package] placement_available true]
    } elseif {[dict get $request kind] eq "symbol"} {
     set p [dict get $request params]
     if {![string equal -nocase [file normalize [dict get $p project]] $project]} {error "Target project changed"}
     set library [dict get $p library];set cell [dict get $p cell];set view [dict get $p view];set role [dict get $p role]
     extract $cache $library $cell $view
     set placement [::coco_syscap_electrical::placement $library $cell $view $role]
     if {![dict get $placement available]} {error [dict get $placement reason]}
     set pin [::coco_syscap_electrical::anchors $cache $library $cell $view]
     set fields [list profile_kind [::coco_syscap_generation::Q electrical] library [::coco_syscap_generation::Q $library] cell [::coco_syscap_generation::Q $cell]]
     set symbol [list view [::coco_syscap_generation::Q $view] anchor [::coco_syscap_generation::point $pin] placement_available true bodyGeometry [::coco_syscap_native_library::bodyGeometry $cache $library $cell $view]]
     foreach key {role portDirection} {if {[dict exists $placement $key]} {dict set symbol $key [::coco_syscap_generation::Q [dict get $placement $key]]}}
     lappend symbols [::coco_syscap_generation::J $symbol]
    } else {error "Unsupported target query"}
    dict set fields coordinate_frame [::coco_syscap_generation::Q syscap-mil-y-up]
    dict set fields session_id [::coco_syscap_generation::Q $session];dict set fields project [::coco_syscap_generation::Q $project]
    dict set fields symbols [::coco_syscap_generation::A $symbols]
    set row [::coco_syscap_utils::json_success [::coco_syscap_generation::J $fields]]
   } reason]} {set row [::coco_syscap_utils::json_error target_unavailable $reason]}
   lappend rows $row
  }
  if {$project ne [::coco_syscap_generation::project] || $session ne [::coco_syscap_generation::session]} {error "Target changed during metadata query"}
  return [::coco_syscap_utils::json_success [::coco_syscap_generation::J [list generation_mode [::coco_syscap_generation::Q registered-sheet-v1] profiles [::coco_syscap_generation::A $rows]]]]
 } finally {file delete -force $cache}
}
# Called after native placement, before the first wire. Read actual PN and position.
proc ::coco_syscap_registered::checkPins {item expected} {
 set actual {}
 foreach pin [sch::dbGetChildren $item] {
  if {[sch::dbGetType $pin]!=32} continue
  set pn [sch::dbGetPropertyValueFromSPath [sch::dbGetSPath $pin] PN]
  if {$pn eq "" || [dict exists $actual $pn]} {error "Ambiguous actual physical pin number"}
  dict set actual $pn [sch::dbGetPos $pin]
 }
 if {[dict size $actual]!=[llength $expected]} {error "Placed pin count differs from registration; wiring stopped"}
 foreach pin $expected {
  set pn [dict get $pin number]
  if {![dict exists $actual $pn]} {error "Placed pin number differs from registration; wiring stopped"}
  lassign [dict get $actual $pn] x y
  if {abs($x/254.0-[dict get $pin x])>0.0001 || abs(-$y/254.0-[dict get $pin y])>0.0001} {error "Placed pin position differs from registration; wiring stopped"}
 }
}
proc ::coco_syscap_registered::pageSymbols {page} {
 set cache [cache];set seen {}
 try {
  foreach item [sch::dbGetPageItems $page] {
   if {[sch::dbGetType $item] ni {16 19 20 21}} continue
   set lcv {};foreach pair [sch::dbGetLibCellView $item] {dict set lcv {*}$pair}
   set key [list [dict get $lcv library] [dict get $lcv cell] [dict get $lcv view]]
   if {[dict exists $seen $key]} continue
   dict set seen $key 1
   # A failed view remains explicitly unavailable to the existing appearance comparator.
   catch {extract $cache {*}$key}
  }
  return $cache
 } on error {reason options} {file delete -force $cache;return -options $options $reason}
}
# Only objects/routes on this sheet. ConnectedItems is a query on the relevant net,
# so named global nets can still expose their actual native connectivity.
proc ::coco_syscap_registered::inventory {page} {
 set names {};set members {};set netNames {}
 foreach item [sch::dbGetPageItems $page] {
  if {[sch::dbGetType $item]!=26} continue
  set name [sch::dbGetItemName $item];set key [sch::dbGetSPath $item]
  if {$name eq "" || $key eq ""} {error "Incomplete generated net identity"}
  dict set names [string toupper $name] $name;dict lappend netNames [string toupper $name] $key
  foreach pin [sch::dbGetConnectedItems $item] {if {[sch::dbGetType $pin]==32} {dict lappend members $key $pin}}
 }
 return [dict create names $names members $members netNames $netNames pages {}]
}

proc ::coco_syscap_registered::checkAnchor {item expected} {
 set pins {};foreach pin [sch::dbGetChildren $item] {if {[sch::dbGetType $pin]==32} {lappend pins $pin}}
 if {[llength $pins]!=1} {error "Placed electrical anchor is ambiguous; wiring stopped"}
 lassign [sch::dbGetPos [lindex $pins 0]] x y
 if {abs($x/254.0-[dict get $expected x])>0.0001 || abs(-$y/254.0-[dict get $expected y])>0.0001} {error "Placed electrical anchor differs from registration; wiring stopped"}
}

# Actual native display text, including inherited pin/static template text.
proc ::coco_syscap_generation::appearanceSelect {item} {
 selectWindow canvas
 foreach selected [sch::dbGetSelectedItems [sch::dbGetActivePage]] {sch::dbUnselectObjectById $selected $::sch::DBFalse}
 sch::dbSelectObjectById $item $::sch::DBTrue
 set selected [sch::dbGetSelectedItems [sch::dbGetActivePage]]
 if {[llength $selected]!=1 || [lindex $selected 0] ne $item} {error "Display operation selection is not isolated"}
}
proc ::coco_syscap_generation::appearanceJust {just} {lindex {lowerLeft lowerCenter lowerRight upperLeft upperCenter upperRight middleLeft middleCenter middleRight} $just}
proc ::coco_syscap_generation::appearanceRows {record} {
 set rows {};set unavailable {};set seen {};set owners {}
 regexp {^(@[^:]+):} [dict get $record sheetId] -> design
 dict for {source native} [dict get $record partMap] {lappend owners [list $native component $source]}
 if {[dict exists $record symbolMap]} {dict for {source native} [dict get $record symbolMap] {foreach symbol [dict get [dict get $record manifest] symbols] {if {[dict get $symbol id] eq $source} {lappend owners [list $native net [dict get $symbol netId]]}}}}
 foreach owner $owners {
  lassign $owner native kind source
  set pose [readPose $native]
  set queue [sch::dbGetChildren $native]
  while {[llength $queue]} {
   set child [lindex $queue 0];set queue [lrange $queue 1 end]
   if {$child in $seen} continue
   lappend seen $child;set type [sch::dbGetType $child]
   if {$type==32} {lappend queue {*}[sch::dbGetChildren $child];continue}
   if {$type==2} {
    set value [sch::dbGetItemText $child]
    set rotation [expr {fmod([dict get $pose rotation]-[sch::dbGetRotationValue $child]+720.0,360.0)}]
    if {$rotation>90.0001 && $rotation<270.0-0.0001} {set rotation [expr {$rotation-180.0}]}
    lappend rows [dict create native $child owner $native key @static kind $kind source $source value $value position [dbpoint [sch::dbGetPos $child]] rotation $rotation justify unknown]
    continue
   }
   if {$type!=5} continue
   if {[catch {
    set visibility [sch::dbGetPropVisibility $child]
    if {$visibility==0} continue
    if {$visibility ni {1 2 3}} {error "Unknown property display mode"}
    set properties [sch::dbGetPropNameVal $child $design]
    if {[llength $properties]==2 && [llength [lindex $properties 0]]==1} {set properties [list $properties]}
    if {[llength $properties]!=1 || [llength [lindex $properties 0]]!=2} {error "Ambiguous displayed property"}
    lassign [lindex $properties 0] key value
    # Empty $LOCATION is an unbound library placeholder, not a displayed RefDes.
    if {$key in {PN $PN}} {set value [string trim $value {()}]}
    if {$visibility==1} {set value $key} elseif {$visibility==3} {set value "$key=$value"}
    if {$value eq "" || $value in {{<< NULL >>} {~~ NULL ~~}}} continue
    set cs {};foreach pair [sch::dbGetCSPropNameVal $child] {dict set cs {*}$pair}
    set just 0;if {[dict exists $cs just]} {set just [dict get $cs just]}
    set relative [expr {-[sch::dbGetRotationValueOfProp $child]}];if {[dict get $pose mirrorY]} {set relative [expr {-$relative}]}
    lappend rows [dict create native $child owner $native key $key kind $kind source $source value $value position [dbpoint [sch::dbGetPos $child]] rotation [expr {fmod([dict get $pose rotation]+$relative+720.0,360.0)}] justify [appearanceJust $just]]
   } reason]==1} {lappend unavailable [dict create target $child message $reason]}
  }

 }
 foreach item [sch::dbGetPageItems [dict get $record page]] {
  set type [sch::dbGetType $item]
  if {$type==3} {lappend unavailable [dict create target $item message "Native free drawing readback is not implemented"]}
  if {$type!=4} continue
  set value [sch::dbGetItemText $item];set props {};foreach pair [sch::dbGetCSPropNameVal $item] {dict set props {*}$pair}
  if {[dict exists $props vis] && [dict get $props vis]==0} continue
  set source "";dict for {id name} [dict get $record netNames] {if {$value eq $name} {set source $id;break}}
  if {$source eq "" || ![dict exists $props CGTYPE] || [dict get $props CGTYPE]!=65571} {lappend unavailable [dict create target $item message "Native free text is not a bound net label"];continue}
  set pose [readPose $item];set just 0;if {[dict exists $props just]} {set just [expr {([dict get $props just]+3)%6}]}
  lappend rows [dict create native $item owner $item key @net kind net source $source value $value position [dbpoint [sch::dbGetPos $item]] rotation [dict get $pose rotation] justify [appearanceJust $just]]
 }
 return [dict create rows $rows unavailable $unavailable]
}
proc ::coco_syscap_generation::appearanceLabels {record} {
 set read [appearanceRows $record];set rows {};set unavailable {}
 foreach row [dict get $read rows] {lappend rows [J [list target [J [list kind [Q [dict get $row kind]] [dict get $row kind]Id [Q [dict get $row source]]]] value [Q [dict get $row value]] position [dict get $row position] rotation [dict get $row rotation] justify [Q [dict get $row justify]]]]}
 foreach gap [dict get $read unavailable] {lappend unavailable [J [list target [Q [dict get $gap target]] message [Q [dict get $gap message]]]]}
 return [J [list complete [expr {[llength $unavailable]?"false":"true"}] labels [A $rows] unavailable [A $unavailable]]]
}
proc ::coco_syscap_generation::applyAppearance {operation} {
 set record [load $operation];set manifest [dict get $record manifest]
 if {![dict exists $manifest appearance labels]} return
 openItem [dict get $record sheetId] SCH PAGE
 cpbf::processEvents
 set labels [dict get $manifest appearance labels]
 # drawWire creates route-name annotations by default. Keep logical names while
 # suppressing these extra displays; source electrical-symbol captions are real
 # native type-2 children and remain visible.
 foreach item [sch::dbGetPageItems [dict get $record page]] {
  if {[sch::dbGetType $item]!=26} continue
  appearanceSelect $item
  annotate -pg [dict get $record sheetId] OFF
 }

 # Materialize the real native RefDes only when it is actually displayed in source.
 foreach label $labels {
  if {![dict get $label visible] || [dict get $label target kind] ne "component"} continue
  set source [dict get $label target componentId]
  foreach part [dict get $manifest parts] {
   if {[dict get $part id] ne $source || [dict get $label value] ne [dict get $part reference]} continue
   appearanceSelect [dict get $record partMap $source]
   modifyProp -name LOCATION -display valOnly
  }
 }
 set gridBefore [sch::getGridSettings];set g [json::json2dict $gridBefore]
 # Pin spacing/electrical grid stay unchanged; changing those clears native undo.
 set oldDoc [dict get $g {Documentation Grid}];set doc [expr {min(double($oldDoc),0.1)}]
 set pp [dict get $g {Pin-to-Pin Spacing}];set elec [dict get $g {Electrical Grid}]
 set style [string tolower [dict get $g {Grid Style}]];set display [dict get $g {Display Electrical Grid}];set units [dict get $g {Grid Units}]
 set mode none
 if {[dict get $g {Electrical Grid Visibility}] && [dict get $g {Documentation Grid Visibility}]} {set mode both} elseif {[dict get $g {Electrical Grid Visibility}]} {set mode electrical} elseif {[dict get $g {Documentation Grid Visibility}]} {set mode documentation}
 try {
  if {$doc!=$oldDoc} {grid $mode -size [list $pp $elec $doc] -style $style $display -unit $units}
  foreach label $labels {
   set current [checkpoint $operation]
   if {![dict get $label visible]} continue
   set kind [dict get $label target kind];set source [dict get $label target ${kind}Id];set value [dict get $label value];set key ""
   if {$kind eq "component"} {
    foreach part [dict get $manifest parts] {
     if {[dict get $part id] ne $source} continue
     if {$value eq [dict get $part reference]} {set key LOCATION;set value [sch::dbGetPropertyValueFromSPath [sch::dbGetSPath [dict get $record partMap $source]] LOCATION]}
     if {$value eq [dict get $part value]} {set key VALUE}
     if {[dict exists $part displayProperties]} {foreach prop [dict get $part displayProperties] {if {$value eq [dict get $prop value]} {set key [dict get $prop name]}}}
    }
   } elseif {$kind eq "net"} {set key @net;dict for {id name} [dict get $record netNames] {if {$id eq $source} {foreach net [dict get $manifest nets] {if {[dict get $net id] eq $source && $value eq [dict get $net name]} {set value $name}}}}}
   # Inherited pin/static text is read from the native template and kept in place.
   if {$key eq ""} continue
   set candidates {};foreach row [dict get [appearanceRows $record] rows] {if {[dict get $row kind] eq $kind && [dict get $row source] eq $source && [dict get $row value] eq $value && [dict get $row key] eq $key} {lappend candidates $row}}
   if {[llength $candidates]!=1} {continue}
   set row [lindex $candidates 0];set item [dict get $row native]
   appearanceSelect $item
   if {[dict exists $label justify] && [dict get $row justify] ne [dict get $label justify]} {
    set alignment [dict create lowerLeft left lowerCenter center lowerRight right]
    if {![dict exists $alignment [dict get $label justify]]} {error "Unsupported native text vertical alignment"}
    textAlign [dict get $alignment [dict get $label justify]]
   }
   set delta [expr {fmod([dict get $row rotation]-[dict get $label rotation]+720.0,360.0)}]
   if {abs($delta)>0.0001} {rotate right $delta}
   set actual [json::json2dict [dbpoint [sch::dbGetPos $item]]];set expected [dict get $label position]
   set dx [expr {[dict get $expected x]-[dict get $actual x]}];set dy [expr {[dict get $actual y]-[dict get $expected y]}]
   if {abs($dx)>0.0001 || abs($dy)>0.0001} {
    move
    set result [move -pg [dict get $record sheetId] -offset $dx $dy]
    if {[string equal -nocase [string trim $result] Incomplete]} {error "Native text move did not complete"}
   }
  }
 } finally {
  if {$doc!=$oldDoc} {grid $mode -size [list $pp $elec $oldDoc] -style $style $display -unit $units}
  foreach item [sch::dbGetSelectedItems [sch::dbGetActivePage]] {sch::dbUnselectObjectById $item $::sch::DBFalse}
 }
 if {[sch::getGridSettings] ne $gridBefore} {error "Native text operation did not restore grid settings"}
}

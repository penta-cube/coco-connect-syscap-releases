# SDAX cache reader for native library physical anchors. Deliberately rejects
# unsupported rich/raw strings and transforms instead of inferring geometry.
namespace eval ::coco_syscap_native_library { variable nodes 0 }
proc ::coco_syscap_native_library::node {textVar posVar {depth 0}} {
 upvar 1 $textVar text $posVar pos
 variable nodes
 incr nodes
 if {$depth > 64 || $nodes > 200000} { error "Excessive native library data" }
 set length [string length $text]
 while {$pos < $length && [string is space [string index $text $pos]]} { incr pos }
 if {[string index $text $pos] ne "<"} { error "Invalid native library node" }
 incr pos
 set kind ""
 if {[string range $text $pos [expr {$pos+1}]] in {{n } {v } {e }}} { set kind [string index $text $pos]; incr pos }
 while {$pos < $length && [string is space [string index $text $pos]]} { incr pos }
 if {[string index $text $pos] ne "<" || $kind in {n v}} {
  set tail " />"
  if {$kind in {n v}} {set tail " $kind/>"}
  set end [string first $tail $text $pos]
  if {$end < 0} {error "Unterminated native library value"}
  set value [string trim [string range $text $pos [expr {$end-1}]]]
  set pos [expr {$end+[string length $tail]}]
  return [dict create kind $kind value $value children {}]
 }
 set children {}
 while {$pos < $length} {
  while {$pos < $length && [string is space [string index $text $pos]]} {incr pos}
  if {[string range $text $pos [expr {$pos+1}]] eq "/>"} {
   incr pos 2
   return [dict create kind $kind value "" children $children]
  }
  lappend children [node text pos [expr {$depth+1}]]
 }
 error "Unterminated native library collection"
}
proc ::coco_syscap_native_library::at {node index} {
 set children [dict get $node children]
 if {$index >= [llength $children]} {error "Missing native library field $index"}
 return [lindex $children $index]
}
proc ::coco_syscap_native_library::value {node index} {dict get [at $node $index] value}
proc ::coco_syscap_native_library::records {node} {
 set children [dict get $node children]
 set count [value $node 0]
 if {![string is integer -strict $count] || $count < 0 || [llength $children] != 1+2*$count} {error "Invalid native typed collection"}
 return [lrange $children 1 end]
}
proc ::coco_syscap_native_library::props {node} {
 set children [dict get $node children]; set out {}
 for {set i 0} {$i < [llength $children]} {incr i} {
  set item [lindex $children $i]
  if {[dict get $item kind] ne "n"} continue
  set found 0
  for {set j [expr {$i+1}]} {$j < min([llength $children],$i+5)} {incr j} {
   set next [lindex $children $j]
   if {[dict get $next kind] eq "v"} {
    set key [dict get $item value]
    if {[dict exists $out $key]} {error "Duplicate native property"}
    dict set out $key [dict get $next value];set found 1;break
   }
  }
  if {!$found} {error "Missing native property value"}
 }
 return $out
}
proc ::coco_syscap_native_library::identity {properties} {
 foreach {key expected} {rotation 0 transform 1,0,0,0,1,0,0,0,1} {
  if {[dict exists $properties $key] && [dict get $properties $key] ne $expected} {error "Unsupported native pin transform"}
 }
}
proc ::coco_syscap_native_library::textFile {path} {
 if {![file isfile $path] || [file size $path] > 1048576} {error "Native library view unavailable or excessive"}
 set f [open $path r];fconfigure $f -encoding utf-8
 try {set text [read $f]} finally {close $f}
 return $text
}
proc ::coco_syscap_native_library::pins {ascii} {
 variable nodes;set nodes 0;set pos 0
 set version [dict get [node ascii pos] value]
 if {$version ni {{version 12} {version 13}} || [dict get [node ascii pos] value] ne "15"} {error "Unsupported native library format"}
 set symbol [node ascii pos]
 if {[string trim [string range $ascii $pos end]] ne ""} {error "Trailing native library data"}
 identity [props [at $symbol 17]]
 set out {}
 foreach {type group} [records [at $symbol 4]] {
  if {[dict get $type value] ne "19"} {error "Bus/multi-pin library groups are not supported"}
  set body [at $group 4]
  set properties [props [at $group 5]];identity $properties
  set translation [at $body 22]
  if {[value $translation 1] != 0 || [value $translation 3] != 0} {error "Unsupported translated library pin group"}
  set anchors [records [at $body 8]]
  if {[llength $anchors] != 2} {error "Ambiguous native library pin anchor"}
  set point [at [lindex $anchors 1] 3]
  set x [value $point 3];set y [value $point 1]
  foreach number [list $x $y] {if {![string is double -strict $number] || abs($number) > 1e10} {error "Invalid native pin coordinate"}}
  set name [value $body 5]
  if {$name eq "" || [dict exists $out [string tolower $name]]} {error "Ambiguous native pin name"}
  dict set out [string tolower $name] [dict create name $name x [expr {$x/254.0}] y [expr {-$y/254.0}]]
 }
 if {![dict size $out]} {error "Native library has no physical pins"}
 return $out
}
proc ::coco_syscap_native_library::directory {parent logicalName} {
 set found {}
 foreach child [glob -nocomplain -directory $parent -types d *] {
  set encoded [file tail $child];set decoded ""
  while {[regexp -indices {#[0-9a-fA-F]{2}} $encoded match]} {
   lassign $match a b
   append decoded [string range $encoded 0 [expr {$a-1}]]
   scan [string range $encoded [expr {$a+1}] $b] %x code
   append decoded [format %c $code]
   set encoded [string range $encoded [expr {$b+1}] end]
  }
  append decoded $encoded
  if {[string equal -nocase $decoded $logicalName]} {lappend found $child}
 }
 if {[llength $found] != 1} {error "Native cached library directory not uniquely resolved: $logicalName"}
 return [lindex $found 0]
}
proc ::coco_syscap_native_library::resolve {cache library cell view part_name package} {
 set libdir [directory [file join $cache cache flatlib] $library]
 set celldir [directory $libdir $cell]
 set viewdir [directory $celldir $view]
 set candidates [glob -nocomplain -directory $viewdir *.ascii]
 if {[llength $candidates] == 1} {
  set pins [pins [textFile [lindex $candidates 0]]]
  set anchorSource "native SDAX ASCII pin anchors (254 DB units per mil)"
 } elseif {[llength $candidates] == 0} {
  set candidates [glob -nocomplain -directory $viewdir *.css]
  if {[llength $candidates] != 1} {error "Native cached CSS symbol not uniquely resolved"}
  set pins [cssPins [textFile [lindex $candidates 0]]]
  set anchorSource "native-exported Cadence CSS C anchors (0.002 inch per coordinate unit)"
 } else {error "Native cached symbol not uniquely resolved"}
 set chips [textFile [file join $celldir chips chips.prt]]
 set selected {}
 foreach {full names body} [regexp -all -inline -nocase {(?s)\mprimitive\s+((?:'[^']+'\s*,\s*)*'[^']+')\s*;(.*?)\mend_primitive\s*;} $chips] {
  foreach {quoted name} [regexp -all -inline {'([^']+)'} $names] {
   if {[string equal -nocase $name "${part_name}_$package"]} {
    if {$selected ne ""} {error "Ambiguous library package primitive"}
    set selected [list $name $body]
   }
  }
 }
 if {$selected eq ""} {error "Package primitive was not confirmed in native chips data"}
 lassign $selected primitive body
 if {![regexp -nocase {\mPART_NAME\s*=\s*'([^']+)'} $body -> declared] || ![string equal -nocase $declared $part_name]} {error "Package part identity conflict"}
 if {![regexp -nocase {(?s)\mpin\s+?(.*?)\mend_pin\s*?;} $body -> pinBody]} {error "Package has no physical pin definitions"}
 set matches [regexp -all -inline -indices {'([^']+)'\s*:} $pinBody]
 set out {};set pinData {};set used {};set names {}
 for {set i 0} {$i < [llength $matches]} {incr i 2} {
  lassign [lindex $matches $i] start end
  lassign [lindex $matches [expr {$i+1}]] a b
  set name [string range $pinBody $a $b]
  set next [string length $pinBody]
  if {$i+2 < [llength $matches]} {set next [lindex [lindex $matches [expr {$i+2}]] 0]}
  set definition [string range $pinBody [expr {$end+1}] [expr {$next-1}]]
  if {![regexp -nocase {\mPIN_NUMBER\s*=\s*'\(([[:alnum:]_+.-]+)\)'\s*;} $definition -> number]} {error "Unsupported multi-section/hidden physical pin mapping"}
  set key [string tolower $name]
  if {$number in $used || $key in $names || ![dict exists $pins $key]} {error "Physical pin mapping conflicts with native symbol"}
  lappend used $number;lappend names $key
  set pin [dict get $pins $key]
  lappend pinData [dict merge $pin [dict create number $number]]
  lappend out [::coco_syscap_utils::json_object_from_pairs [list \
    [::coco_syscap_utils::json_field_string name $name] \
    [::coco_syscap_utils::json_field_string number $number] \
    [::coco_syscap_utils::json_field_number x [dict get $pin x]] \
    [::coco_syscap_utils::json_field_number y [dict get $pin y]]]]
 }
 if {![llength $out] || [llength $out] != [dict size $pins]} {error "Incomplete native physical pin mapping"}
 return [dict create primitive $primitive pins [::coco_syscap_utils::json_array_from_values $out] pinData $pinData anchorSource $anchorSource]
}
proc ::coco_syscap_native_library::exportCurrent {} {
 if {![info exists ::coco_syscap_circuit::cache_sequence]} {set ::coco_syscap_circuit::cache_sequence 0}
 set cache [file join $::env(TEMP) coco-syscap-library $::coco_syscap_circuit::session_id [incr ::coco_syscap_circuit::cache_sequence]]
 file mkdir $cache
 if {![cpb::exportDesignCache $cache]} {error "Native library cache export failed"}
 return $cache
}

# Cadence CSS C records store explicit logical pin anchors. The documented CSS
# nominal coordinate unit is 0.002 inch, independently of the displayed bbox.
# Read data only; never source/eval a library file or fit a scale to its size.
proc ::coco_syscap_native_library::cssPins {text} {
 set out {}
 foreach line [split $text \n] {
  if {![regexp {^\s*C(?:\s|$)} $line]} continue
  if {![regexp {^\s*C\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+("[^"\\]*"|[^\s"\\]+)(?:\s|$)} $line -> x y name]} {
   error "Unsupported native CSS pin record"
  }
  set name [string trim $name \"]
  foreach coordinate [list $x $y] {
   if {![string is double -strict $coordinate] || abs($coordinate)>1e10} {error "Invalid native CSS pin coordinate"}
  }
  set key [string tolower $name]
  if {$name eq "" || [dict exists $out $key]} {error "Ambiguous native CSS pin name"}
  dict set out $key [dict create name $name x [expr {2.0*$x}] y [expr {2.0*$y}]]
 }
 if {![dict size $out]} {error "Native CSS has no declared pin anchors"}
 return $out
}

# Cache geometry is not evidence that the placement library is accessible.
# dbGetCellNames queries libraries accessible to the current project (read only).
proc ::coco_syscap_native_library::placementCell {library cell} {
 if {[catch {sch::dbGetCellNames $library} cells]} {
  return [dict create available false reason "Cannot query placement library ${library}: $cells"]
 }
 foreach name $cells {
  if {[string equal -nocase $name $cell]} {return [dict create available true reason ""]}
  set decoded ""
  while {[regexp -indices {#[0-9a-fA-F]{2}} $name match]} {
   lassign $match a b
   append decoded [string range $name 0 [expr {$a-1}]]
   scan [string range $name [expr {$a+1}] $b] %x code
   append decoded [format %c $code]
   set name [string range $name [expr {$b+1}] end]
  }
  append decoded $name
  if {[string equal -nocase $decoded $cell]} {return [dict create available true reason ""]}
 }
 return [dict create available false reason "Cell $library/$cell is not available in the project's placement libraries"]
}

# Supported native CSS body geometry. Unsupported records remain explicit gaps.
proc ::coco_syscap_native_library::bodyGeometry {cache library cell view} {
 set failure {"complete":false,"segments":[],"circles":[],"unsupported":["Native CSS body unavailable"]}
 if {[catch {
  set lib [directory [file join $cache cache flatlib] $library]
  set cd [directory $lib $cell];set vd [directory $cd $view]
  set files [glob -nocomplain -directory $vd *.css]
  if {[llength $files]!=1} {error "No unique CSS body"}
  set text [textFile [lindex $files 0]]
 }]} {return "\{$failure\}"}
 set lines {};set circles {};set unsupported {};set complete true;set textPayload false
 foreach line [split $text \n] {
  set line [string trim $line];if {$textPayload} {set textPayload false;continue};if {$line eq ""} continue
  set kind "";regexp {^([A-Z])(?:\s|$)} $line -> kind
  if {$kind in {L M} && [llength $line]>=5} {
   lassign [lrange $line 1 4] x y u v
   foreach n [list $x $y $u $v] {if {![string is double -strict $n]} {error "Invalid CSS body coordinate"}}
   lappend lines [::coco_syscap_generation::A [list [::coco_syscap_generation::point [dict create x [expr {2.0*$x}] y [expr {2.0*$y}]]] [::coco_syscap_generation::point [dict create x [expr {2.0*$u}] y [expr {2.0*$v}]]]]]
  } elseif {$kind eq "A" && [llength $line]>=6} {
   lassign [lrange $line 1 5] x y radius start end
   foreach n [list $x $y $radius $start $end] {if {![string is double -strict $n]} {error "Invalid CSS arc coordinate"}}
   if {abs($end-$start)>=359.9999} {
    lappend circles [::coco_syscap_generation::J [list center [::coco_syscap_generation::point [dict create x [expr {2.0*$x}] y [expr {2.0*$y}]]] radius [expr {2.0*$radius}]]]
   } else {set complete false;lappend unsupported [::coco_syscap_generation::Q "Partial CSS arc"]}
  } elseif {$kind eq "T"} {set textPayload true
  } elseif {$kind ni {C P X}} {set complete false;lappend unsupported [::coco_syscap_generation::Q "CSS record $kind"]}
 }
 return [::coco_syscap_generation::J [list complete $complete segments [::coco_syscap_generation::A $lines] circles [::coco_syscap_generation::A $circles] unsupported [::coco_syscap_generation::A $unsupported]]]
}

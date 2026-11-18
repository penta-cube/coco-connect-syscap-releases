# Data-only generation contract. Existing design objects are never edited/saved/deleted.
namespace eval ::coco_syscap_generation {
 if {![info exists active]} {variable active {}}
 if {![info exists project_epoch]} {variable project_epoch 0}
}
proc ::coco_syscap_generation::invalidate {args} {variable project_epoch;incr project_epoch}
foreach command {::openProject ::closeProject ::cps::closeProject} {
 if {[llength [info commands $command]] && ![string match *coco_syscap_generation::invalidate* [trace info execution $command]]} {
  trace add execution $command enter ::coco_syscap_generation::invalidate
 }
}
proc ::coco_syscap_generation::session {} {
 return "$::coco_syscap_circuit::session_id-$::coco_syscap_generation::project_epoch"
}
proc ::coco_syscap_generation::Q {value} {::coco_syscap_utils::json_quote $value}
proc ::coco_syscap_generation::A {items} {::coco_syscap_utils::json_array_from_values $items}
proc ::coco_syscap_generation::J {fields} {
 set pairs {};dict for {key value} $fields {lappend pairs "[Q $key]:$value"}
 return "\{[join $pairs ,]\}"
}
proc ::coco_syscap_generation::strings {items} {set out {};foreach item $items {lappend out [Q $item]};return [A $out]}
proc ::coco_syscap_generation::number {value} {
 if {![string is double -strict $value] || abs($value) > 1e10} {error "Invalid circuit coordinate"}
 return [expr {double($value)}]
}
proc ::coco_syscap_generation::point {p} {J [list x [number [dict get $p x]] y [number [dict get $p y]]]}
proc ::coco_syscap_generation::dbpoint {p} {J [list x [expr {[lindex $p 0]/254.0}] y [expr {-[lindex $p 1]/254.0}]]}
# Native CS transform is independent of the rotation property. dbGetRotationValue
# alone loses reflections (and source-file rotations embedded in the matrix).
proc ::coco_syscap_generation::readPose {item} {
 set props {};foreach pair [sch::dbGetCSPropNameVal $item] {dict set props [lindex $pair 0] [lindex $pair 1]}
 set transform 1,0,0,0,1,0,0,0,1
 if {[dict exists $props transform]} {set transform [dict get $props transform]}
 set m [split $transform ,]
 if {[llength $m]!=9} {error "Invalid native placement matrix"}
 foreach value $m {number $value}
 foreach index {2 5 6 7} {if {abs([lindex $m $index])>0.0001} {error "Unsupported native placement matrix"}}
 if {abs([lindex $m 8]-1)>0.0001} {error "Invalid native homogeneous transform"}
 set r 0;if {[dict exists $props rotation]} {set r [number [dict get $props rotation]]}
 set angle [expr {$r*acos(-1)/180.0}];set co [expr {cos($angle)}];set si [expr {sin($angle)}]
 # Qt maps x'=m11*x+m21*y. The residual matrix acts after native rotation.
 set a [expr {[lindex $m 0]*$co+[lindex $m 3]*$si}]
 set b [expr {-([lindex $m 1]*$co+[lindex $m 4]*$si)}]
 set c [expr {-(-[lindex $m 0]*$si+[lindex $m 3]*$co)}]
 set d [expr {-[lindex $m 1]*$si+[lindex $m 4]*$co}]
 if {abs($a*$a+$b*$b-1)>0.0001 || abs($c*$c+$d*$d-1)>0.0001 || abs($a*$c+$b*$d)>0.0001} {error "Unsupported native placement scale/skew"}
 set degrees [expr {fmod(atan2($b,$a)*180.0/acos(-1)+360.0,360.0)}]
 set rotation [expr {int(round($degrees/90.0))*90%360}]
 if {abs(sin(($degrees-$rotation)*acos(-1)/180.0))>0.0001} {error "Unsupported native placement angle"}
 return [dict create position [dbpoint [sch::dbGetPos $item]] rotation $rotation mirrorY [expr {$a*$d-$b*$c<0 ? "true" : "false"}]]
}
proc ::coco_syscap_generation::applyPose {item sheet pose} {
 if {[dict get $pose mirrorY]} {
  # mirror is a world-axis operation about the selected object's bounding box.
  # Choose the world axis for local Y reflection, then restore the planned origin.
  selectWindow canvas;selectObject none
  sch::dbSelectObjectById $item $::sch::DBTrue
  try {
   set axis horizontal;if {[dict get $pose rotation] in {90 270}} {set axis vertical}
   set result [mirror $axis]
   if {[string equal -nocase [string trim $result] Incomplete]} {error "Native mirror did not complete"}
   lassign [sch::dbGetPos $item] x y
   set dx [expr {[dict get $pose position x]-$x/254.0}]
   set dy [expr {-[dict get $pose position y]-$y/254.0}]
   if {abs($dx)>0.0001 || abs($dy)>0.0001} {
    set result [move -pg $sheet -offset $dx $dy]
    if {[string equal -nocase [string trim $result] Incomplete]} {error "Native mirror origin restoration did not complete"}
   }
  } finally {sch::dbUnselectObjectById $item $::sch::DBFalse}
 }
 set actual [readPose $item]
 if {[dict get $actual rotation]!=[dict get $pose rotation] || !![dict get $actual mirrorY]!=!![dict get $pose mirrorY]} {error "Native placement orientation differs from plan"}
 lassign [sch::dbGetPos $item] x y
 if {abs($x/254.0-[dict get $pose position x])>0.0001 || abs(-$y/254.0-[dict get $pose position y])>0.0001} {error "Native placement origin differs from plan"}
}
proc ::coco_syscap_generation::id {value} {
 if {![regexp -nocase {^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$} $value]} {error "Invalid operation ID"}
 return [string tolower $value]
}
proc ::coco_syscap_generation::root {} {
 if {![info exists ::coco_syscap_generation::operation_directory]} {
  set ::coco_syscap_generation::operation_directory [file join $::env(LOCALAPPDATA) CubicAI syscap-circuit-operations]
 }
 set root [file normalize $::coco_syscap_generation::operation_directory];file mkdir $root
 return $root
}
proc ::coco_syscap_generation::path {operation} {file join [root] "[id $operation].receipt"}
proc ::coco_syscap_generation::load {operation} {
 set file [path $operation]
 if {![file isfile $file] || [file size $file]>8388608} {error "Operation record unavailable"}
 set f [open $file r];fconfigure $f -encoding utf-8
 try {set record [read $f]} finally {close $f}
 dict size $record
 if {[dict get $record operationId] ne [id $operation]} {error "Operation record identity conflict"}
 return $record
}
proc ::coco_syscap_generation::persist {record} {
 set file [path [dict get $record operationId]]
 set tmp "$file.[pid].[clock microseconds].tmp"
 set f [open $tmp {WRONLY CREAT EXCL}];fconfigure $f -encoding utf-8
 try {puts -nonewline $f $record;flush $f} finally {close $f}
 file rename -force $tmp $file
}
proc ::coco_syscap_generation::project {} {
 if {![cps::isProjectOpen]} {error "No SysCap project is open"}
 return [file normalize [cps::getProjectMainCPM]]
}
proc ::coco_syscap_generation::bound {record} {
 if {![string equal -nocase [project] [dict get $record project]] || [session] ne [dict get $record sessionId]} {error "Operation session/project changed; do not recreate"}
}
proc ::coco_syscap_generation::pages {} {
 set active [sch::dbxGetActivePageSpath]
 if {![regexp {^(@([^.]+)\.([^(]+)\([^)]*\)):} $active -> prefix lib cell]} {error "Design pages unavailable"}
 if {$cell ne [sch::dbGetRootDesignName]} {error "Open a root-design sheet before generating a standard circuit"}
 set pages {}
 foreach name [sch::dbGetPageNames $lib $cell] {
  set page [sch::dbGetPage $lib $cell $name]
  if {$page eq "" || $page eq "db:ffffffff"} {error "A design page could not be read"}
  lappend pages [list "$prefix:$name" $page]
 }
 if {![llength $pages]} {error "Empty design page inventory"}
 return $pages
}
proc ::coco_syscap_generation::existingState {pages} {
 set out {}
 foreach p [lsort $pages] {
  lassign $p sp page
  set items {}
  foreach item [lsort [sch::dbGetPageItems $page]] {
   set type [sch::dbGetType $item]
   if {$type == 16} {
    set pins {};foreach pin [sch::dbGetChildren $item] {if {[sch::dbGetType $pin]==32} {lappend pins [list $pin [sch::dbGetPos $pin] [sch::dbGetPropertyValueFromSPath [sch::dbGetSPath $pin] PN]]}}
    lappend items [list $item $type [sch::dbGetPos $item] [sch::dbGetCSPropNameVal $item] [lsort [sch::dbGetPropertiesFromSPath [sch::dbGetSPath $item]]] [lsort $pins]]
   } elseif {$type==26} {
    lappend items [list $item $type [sch::dbGetItemName $item] [sch::dbGetSPath $item] [lsort [sch::dbGetSegments $item]] [lsort [sch::dbGetPropertiesFromSPath [sch::dbGetSPath $item]]]]
   } elseif {$type in {19 20 21}} {
    set anchors {};foreach pin [sch::dbGetChildren $item] {if {[sch::dbGetType $pin]==32} {lappend anchors [list $pin [sch::dbGetPos $pin] [lsort [sch::dbGetCSPropNameVal $pin]]]}}
    lappend items [list $item $type [sch::dbGetBBox $item] [readPose $item] [lsort [sch::dbGetLibCellView $item]] [lsort [sch::dbGetCSPropNameVal $item]] [lsort [sch::dbGetPropertiesFromSPath [sch::dbGetSPath $item]]] [lsort $anchors]]
   } elseif {$type==5} {
    lappend items [list $item $type [sch::dbGetBBox $item] [sch::dbGetPos $item] [lsort [sch::dbGetCSPropNameVal $item]] [sch::dbGetPropVisibility $item]]
   } elseif {$type==50} {
    # DTRoute points are local to the By-pass parent; preserve its pose below.
    lappend items [list $item $type [sch::dbGetBBox $item] [lsort [sch::dbGetSegments $item]] [lsort [sch::dbGetCSPropNameVal $item]]]
   } elseif {$type==52} {
    lappend items [list $item $type [sch::dbGetBBox $item] [sch::dbGetPos $item] [lsort [sch::dbGetCSPropNameVal $item]] [lsort [sch::dbGetChildren $item]]]
   } else {lappend items [list $item $type [sch::dbGetBBox $item]]}
  }
  lappend out [list $sp $page $items]
 }
 return $out
}
proc ::coco_syscap_generation::inventory {} {
 set names {};set members {};set netNames {};set allpages [pages]
 foreach p $allpages {
  lassign $p sp page
  foreach item [sch::dbGetPageItems $page] {
   if {[sch::dbGetType $item]!=26} continue
   set name [sch::dbGetItemName $item];set key [sch::dbGetSPath $item]
   if {$name eq "" || $key eq ""} {error "Incomplete net identity"}
   dict set names [string toupper $name] $name
   dict lappend netNames [string toupper $name] $key
   foreach other [sch::dbGetConnectedItems $item] {if {[sch::dbGetType $other]==32} {dict lappend members $key $other}}
  }
 }
 return [dict create names $names members $members netNames $netNames pages $allpages]
}
proc ::coco_syscap_generation::validateManifest {manifest {preparedCache ""}} {
 if {[dict get $manifest version] != 1 || [dict get $manifest sessionId] ne [session] || ![string equal -nocase [file normalize [dict get $manifest project]] [project]]} {error "Generation target changed"}
 if {![regexp {^sha256:[a-f0-9]{64}$} [dict get $manifest modelHash]]} {error "Invalid registered model hash"}
 set parts [dict get $manifest parts];set nets [dict get $manifest nets]
 if {![llength $parts] || [llength $parts]>500 || [llength $nets]>1000} {error "Unsupported circuit size"}
 set scoped [::coco_syscap_registered::scoped $manifest]
 set cache $preparedCache
 if {!$scoped && $cache eq ""} {set cache [::coco_syscap_native_library::exportCurrent]}
 if {$scoped} {set cache @registered}
 ::coco_syscap_electrical::validate $manifest $cache
 set partIds {};set pinIds {}
 foreach part $parts {
  set component [dict get $part id]
  if {$component in $partIds} {error "Duplicate component identity"};lappend partIds $component
  set lib [dict get $part library];set cell [dict get $part cell];set view [dict get $part view]
  set placement [::coco_syscap_native_library::placementCell $lib $cell]
  if {![dict get $placement available]} {error [dict get $placement reason]}
  if {$view ni [sch::getSymbolsListForPart $lib $cell [dict get $part partName] [dict get $part package]]} {error "Library view changed"}
  if {!$scoped} {
   set native [::coco_syscap_native_library::resolve $cache $lib $cell $view [dict get $part partName] [dict get $part package]]
   if {[dict get $native primitive] ne [dict get $part primitive]} {error "Package primitive changed"}
  } elseif {[string trim [dict get $part primitive]] eq ""} {error "Registered primitive is missing"}
  set rotation [dict get $part rotation]
  if {$rotation ni {0 90 180 270}} {error "Unsupported placement rotation"}
  set angle [expr {$rotation*acos(-1)/180.0}]
  set x [number [dict get $part position x]];set y [number [dict get $part position y]]
  if {!$scoped && [llength [dict get $part pins]] != [llength [dict get $native pinData]]} {error "Physical pin count changed"}
  foreach pin [dict get $part pins] {
   set number [dict get $pin number];set key "$component/$number"
   if {$key in $pinIds} {error "Duplicate physical pin identity"};lappend pinIds $key
   number [dict get $pin x];number [dict get $pin y]
   if {$scoped} continue
   set found 0
   foreach np [dict get $native pinData] {if {[dict get $np number] eq $number} {
    set nx [dict get $np x];set ny [dict get $np y]
    if {[dict get $part mirrorY]} {set ny [expr {-$ny}]}
    if {abs($x+$nx*cos($angle)-$ny*sin($angle)-[number [dict get $pin x]])>0.0001 || abs($y+$nx*sin($angle)+$ny*cos($angle)-[number [dict get $pin y]])>0.0001} {error "Native pin placement changed"}
    set found 1;break
   }}
   if {!$found} {error "Physical pin mapping changed"}
  }
 }
 set assigned {};set netIds {};set names {}
 foreach net $nets {
  set nid [dict get $net id];set name [dict get $net name]
  if {$nid in $netIds || [string toupper $name] in $names || [string length $name]>256 || [string trim $name] eq "" || [regexp {[\r\n\t\x00]} $name]} {error "Invalid/ambiguous net identity"}
  lappend netIds $nid;lappend names [string toupper $name]
  if {[dict get $net kind] ni {signal power ground} || [dict get $net nameKind] ni {named unnamed}} {error "Invalid internal native net kind/nameKind"}
  foreach ref [dict get $net pins] {
   set key "[dict get $ref componentId]/[dict get $ref number]"
   if {$key ni $pinIds || $key in $assigned} {error "Invalid expected pin connection"};lappend assigned $key
  }
  if {![llength [dict get $net paths]]} {error "Expected physical wire paths missing"}
  foreach path [dict get $net paths] {
   if {[llength $path]<2 || [llength $path]>1000} {error "Invalid wire path"}
   set previous ""
   foreach p $path {
    set px [number [dict get $p x]];set py [number [dict get $p y]]
    if {$previous ne "" && abs($px-[lindex $previous 0])>0.0001 && abs($py-[lindex $previous 1])>0.0001} {error "Diagonal wire paths are not supported"}
    set previous [list $px $py]
   }
  }
 }
 if {[dict get $manifest sessionId] ne [session] || ![string equal -nocase [file normalize [dict get $manifest project]] [project]]} {error "Generation target changed during library validation"}
}
proc ::coco_syscap_generation::lockPath {record} {
 set code [format %08x [zlib crc32 [string tolower [dict get $record project]]]]
 return [file join [root] "project-$code.lock"]
}
proc ::coco_syscap_generation::release {record} {
 set file [lockPath $record]
 if {[file isfile $file]} {
  set f [open $file r];try {set owner [read $f]} finally {close $f}
  if {$owner eq [dict get $record operationId]} {file delete $file}
 }
}
proc ::coco_syscap_generation::summary {record} {
 set mapping {};dict for {key value} [dict get $record partMap] {dict set mapping $key [Q $value]}
 return [J [list operationId [Q [dict get $record operationId]] state [Q [dict get $record state]] sessionId [Q [dict get $record sessionId]] project [Q [dict get $record project]] \
  sheetId [Q [dict get $record sheetId]] partMap [J $mapping] message [Q [dict get $record message]]]]
}
proc ::coco_syscap_generation::prepare {arg} {
 set manifest [dict get $arg manifest];set operation [id [dict get $manifest operationId]]
 if {[file exists [path $operation]]} {
  set old [load $operation]
  if {[dict get $old manifest] ne $manifest} {error "Operation ID was already used with a different manifest"}
  bound $old
  if {[dict get $old state] ne "prepared"} {error "Operation was already attempted; inspect instead of preparing again"}
  return [dict get $old preparedJson]
 }
 set preparedCache ""
 if {[dict exists $arg snapshotToken]} {
  set preparedCache [::coco_syscap_circuit::takePreparationSnapshot [dict get $arg snapshotToken] $manifest]
 }
 if {$preparedCache eq ""} {validateManifest $manifest} else {validateManifest $manifest $preparedCache}
 set scoped [::coco_syscap_registered::scoped $manifest]
 if {$scoped} {set inv [dict create names {} members {} netNames {} pages {}]} else {set inv [inventory]}
 set used [dict get $inv names]
 foreach net [dict get $manifest nets] {dict set used [string toupper [dict get $net name]] [dict get $net name]}
 set mapping {};set netPlans {}
 foreach net [dict get $manifest nets] {
  set original [dict get $net name];set generated $original;set existing [dict exists [dict get $inv names] [string toupper $original]]
  if {![shareNet $net]} {
   # Keep the target net unnamed on a later SysCap extraction as well.
   # Foreign CAD automatic names such as N123 are named in SysCap.
   set base $original
   if {$scoped} {set base "_N[string map {- {}} $operation]_[llength $netPlans]"}
   if {![string match {_N*} $base]} {set base _N1}
   set generated $base
   set suffix 1
   while {[dict exists $used [string toupper $generated]] && !($generated eq $original && !$existing)} {
    set generated "${base}_$suffix";incr suffix
   }
  }
  dict set used [string toupper $generated] $generated
  set nid [dict get $net id];dict set mapping $nid $generated
  lappend netPlans [J [list id [Q $nid] original [Q $original] generated [Q $generated] nameKind [Q [dict get $net nameKind]]]]
 }
 set before ""
 if {!$scoped} {set before [existingState [dict get $inv pages]]}
 set token "[pid]-[clock microseconds]"
 set result [J [list version 1 operationId [Q $operation] token [Q $token] sessionId [Q [session]] project [Q [project]] existingNames [strings [dict values [dict get $inv names]]] netNames [A $netPlans] existingState [Q $before]]]
 set record [dict create operationId $operation manifest $manifest project [project] sessionId [session] token $token state prepared \
  sourcePages [dict get $inv pages] existingState $before netNames $mapping partMap {} symbolMap {} sheetId "" page "" cancel 0 message "" preparedJson $result]
 persist $record
 return $result
}
# Only unnamed allocated names require collision checks. Named nets follow native semantics.
proc ::coco_syscap_generation::shareNet {net} {
 return [expr {[dict get $net nameKind] eq "named"}]
}
proc ::coco_syscap_generation::validateNetPlan {record inv} {
 foreach net [dict get [dict get $record manifest] nets] {
  set name [dict get [dict get $record netNames] [dict get $net id]]
  if {![shareNet $net] && [dict exists [dict get $inv names] [string toupper $name]]} {
   error "Allocated unnamed net name is now in use; prepare again"
  }
 }
}
proc ::coco_syscap_generation::checkpoint {operation} {
 set record [load $operation];bound $record
 if {[dict get $record cancel]} {error "Operation cancelled at a safe step boundary"}
 if {[dict get $record sheetId] ne "" && [sch::dbxGetActivePageSpath] ne [dict get $record sheetId]} {error "Active generation sheet changed"}
 return $record
}
# A successful command response can still be a native no-op (for example,
# routing through a symbol body). Preserve the partial sheet and report it.
proc ::coco_syscap_generation::verifyWireAppeared {page name} {
 foreach item [sch::dbGetPageItems $page] {
  if {[sch::dbGetType $item]!=26 || ![string equal -nocase [sch::dbGetItemName $item] $name]} continue
  foreach segment [sch::dbGetSegments $item] {
   if {[llength $segment]>=3 && [lindex $segment 0] ne [lindex $segment 1]} {return}
  }
 }
 error "Native wire command returned without a physical route: $name"
}
proc ::coco_syscap_generation::create {arg} {
 variable active
 set operation [id [dict get $arg operationId]];set record [load $operation];bound $record
 if {[dict get $arg token] ne [dict get $record token]} {error "Preparation token mismatch"}
 if {[dict get $record state] ne "prepared"} {return [summary $record]}
 if {[dict exists $active [dict get $record project]]} {error "A generation is already running for this project"}
 validateManifest [dict get $record manifest]
 set record [load $operation];bound $record
 if {[dict get $record state] ne "prepared" || [dict get $record cancel]} {return [summary $record]}
 set scoped [::coco_syscap_registered::scoped [dict get $record manifest]]
 if {!$scoped} {
  set inv [inventory];validateNetPlan $record $inv
  dict set record baselineNetMembers [dict get $inv members]
  dict set record sourcePages [dict get $inv pages]
  dict set record existingState [existingState [dict get $inv pages]]
 } else {dict set record baselineNetMembers {};dict set record sourcePages {};dict set record existingState ""}
 set lock [lockPath $record]
 set f [open $lock {WRONLY CREAT EXCL}];puts -nonewline $f $operation;flush $f;close $f
 dict set record state starting
 if {[catch {persist $record} failure details]} {
  release $record
  return -options $details $failure
 }
 dict set active [dict get $record project] $operation
 try {
  checkpoint $operation
  insertPageAtEnd
  set record [load $operation]
  dict set record page [sch::dbGetActivePage];dict set record sheetId [sch::dbxGetActivePageSpath]
  dict set record state creating;persist $record
  foreach part [dict get [dict get $record manifest] parts] {
   update
   set record [checkpoint $operation]
   set page [dict get $record page];set before [sch::dbGetPageItems $page]
   dict set record message "Placing [dict get $part reference]";persist $record
   set pos [list [number [dict get $part position x]] [expr {-[number [dict get $part position y]]}]]
   set injection [list "VALUE=[dict get $part value]"]
   if {[dict exists $part displayProperties]} {foreach prop [dict get $part displayProperties] {lappend injection "[dict get $prop name]=[dict get $prop value]"}}
   if {[dict exists $part jedecType] && [dict get $part jedecType] ne ""} {lappend injection "JEDEC_TYPE=[string tolower [dict get $part jedecType]]"}
   set keys [list "PACK_TYPE=[dict get $part package]"]
   if {[dict get $part partNumber] ne ""} {lappend keys "PART_NUMBER=[dict get $part partNumber]"}
   addComponent [dict get $part library] [dict get $part cell] [dict get $part view] [dict get $part primitive] -n 1 -pg [dict get $record sheetId] \
    -r [expr {-[dict get $part rotation]}] -m 0 -pos $pos -key $keys -i $injection
   set fresh {}
   foreach i [sch::dbGetPageItems $page] {if {$i ni $before && [sch::dbGetType $i]==16} {lappend fresh $i}}
   if {[llength $fresh]!=1} {error "Expected exactly one newly created component"}
   set record [load $operation]
   dict set record partMap [dict get $part id] [lindex $fresh 0];persist $record
   applyPose [lindex $fresh 0] [dict get $record sheetId] $part
   if {$scoped} {::coco_syscap_registered::checkPins [lindex $fresh 0] [dict get $part pins]}
  }
  ::coco_syscap_electrical::create $operation
  if {$scoped} {
   set record [checkpoint $operation]
   foreach symbol [dict get [dict get $record manifest] symbols] {
    set item [dict get [dict get $record symbolMap] [dict get $symbol id]]
    ::coco_syscap_registered::checkAnchor $item [dict get $symbol anchor]
   }
  }
  foreach net [dict get [dict get $record manifest] nets] {
   foreach path [dict get $net paths] {
    update
    set record [checkpoint $operation]
    dict set record message "Wiring [dict get $net name]";persist $record
    set points {}
    foreach p $path {lappend points "[format %.12g [number [dict get $p x]]],[format %.12g [expr {-[number [dict get $p y]]}]]"}
    lappend points [lindex $points end]
    # Native drawWire otherwise returns Incomplete without adding any route when
    # the Command dock (rather than the schematic canvas) owns the command context.
    openItem [dict get $record sheetId] SCH PAGE
    selectWindow canvas
    set wireResult [drawWire [dict get [dict get $record netNames] [dict get $net id]] $points -1 -1]
    if {[string equal -nocase [string trim $wireResult] Incomplete]} {error "Native wire command did not complete"}
    verifyWireAppeared [dict get $record page] [dict get [dict get $record netNames] [dict get $net id]]
   }
  }
  ::coco_syscap_generation::applyAppearance $operation
  set record [checkpoint $operation];dict set record state created;dict set record message "Creation finished; live verification is still required"
  persist $record;release $record
 } on error {message options} {
  # Never undo/delete partial CAD objects. The pre-command record remains if persistence itself fails.
  catch {set record [load $operation]}
  dict set record state partial;dict set record message $message;catch {persist $record}
 } finally {dict unset active [dict get $record project]}
 return [summary $record]
}
proc ::coco_syscap_generation::cancel {arg} {
 set record [load [dict get $arg operationId]];bound $record
 dict set record cancel 1
 if {[dict get $record state] eq "prepared"} {dict set record state cancelled}
 persist $record
 return [summary $record]
}
proc ::coco_syscap_generation::snapshot {record} {
 bound $record
 if {[dict get $record sheetId] ne ""} {openItem [dict get $record sheetId] SCH PAGE;cpbf::processEvents}
 set page [dict get $record page]
 if {$page eq "" || [dict get $record sheetId] eq ""} {error "No generated sheet is recorded"}
 set scoped [::coco_syscap_registered::scoped [dict get $record manifest]]
 set appearanceCache ""
 if {$scoped} {set appearanceCache [::coco_syscap_registered::pageSymbols $page]} else {catch {set appearanceCache [::coco_syscap_native_library::exportCurrent]}}
 try {
 dict set record appearanceCache $appearanceCache
 # Page identity is taken from the operation record, never from whichever tab is active.
 set known 0
 if {$scoped} {
  set known [expr {[sch::dbGetActivePage] eq $page && [sch::dbxGetActivePageSpath] eq [dict get $record sheetId]}]
 } else {foreach p [pages] {if {[lindex $p 0] eq [dict get $record sheetId] && [lindex $p 1] eq $page} {set known 1}}}
 if {!$known} {error "Generated page identity is no longer present"}


 set parts {};set nets {};set targetRoutes {}
 foreach item [sch::dbGetPageItems $page] {if {[sch::dbGetType $item]==26} {lappend targetRoutes $item}}
 foreach item [sch::dbGetPageItems $page] {
  if {[sch::dbGetType $item]!=16} continue
  set sp [sch::dbGetSPath $item];set lcv {}
  foreach pair [sch::dbGetLibCellView $item] {dict set lcv [lindex $pair 0] [lindex $pair 1]}
  set pins {}
  foreach pin [sch::dbGetChildren $item] {
   if {[sch::dbGetType $pin]!=32} continue
   set pn [sch::dbGetPropertyValueFromSPath [sch::dbGetSPath $pin] PN]
   if {$pn eq ""} {error "A physical pin number could not be read"}
   set routes {};set keys {}
   foreach r [sch::dbGetConnectedItems $pin] {
    if {[sch::dbGetType $r]!=26} continue
    if {![sch::dbIsPinRouteConnected $pin $r]} {error "Pin/route readback is inconsistent"}
    lappend routes $r;lappend keys [sch::dbGetSPath $r]
   }
   set keys [lsort -unique $keys]
   if {[llength $keys]>1} {error "Pin is connected to multiple logical nets"}
   set net null
   if {[llength $keys]} {set net [Q [lindex $keys 0]]}
   lappend pins [J [list id [Q $pin] number [Q $pn] position [dbpoint [sch::dbGetPos $pin]] netId $net routeIds [strings [lsort -unique $routes]]]]
  }
  set pose [readPose $item]
  lappend parts [J [list id [Q $item] reference [Q [sch::dbGetPropertyValueFromSPath $sp LOCATION]] \
   bodyGeometry [::coco_syscap_native_library::bodyGeometry $appearanceCache [dict get $lcv library] [dict get $lcv cell] [dict get $lcv view]] position [dict get $pose position] rotation [dict get $pose rotation] mirrorY [dict get $pose mirrorY] \
   library [Q [dict get $lcv library]] cell [Q [dict get $lcv cell]] view [Q [dict get $lcv view]] partName [Q [sch::dbGetPropertyValueFromSPath $sp CHIPS_PART_NAME]] \
   partNumber [Q [sch::dbGetPropertyValueFromSPath $sp PART_NUMBER]] package [Q [sch::dbGetPropertyValueFromSPath $sp PACK_TYPE]] value [Q [sch::dbGetPropertyValueFromSPath $sp VALUE]] pins [A $pins]]]
 }
 if {$scoped} {set inv [::coco_syscap_registered::inventory $page]} else {set inv [inventory]}
 foreach route $targetRoutes {
  set key [sch::dbGetSPath $route];set name [sch::dbGetItemName $route]
  if {![dict exists $nets $key]} {dict set nets $key [dict create name $name routes {}]}
  if {[dict get $nets $key name] ne $name} {error "Logical net name conflict"}
  set paths {}
  foreach segment [sch::dbGetSegments $route] {
   if {[llength $segment]<3 || [llength [lindex $segment 0]]!=2 || [llength [lindex $segment 1]]!=2} {error "Route segment unavailable"}
   if {[lindex $segment 0] eq [lindex $segment 1]} continue
   lappend paths [A [list [dbpoint [lindex $segment 0]] [dbpoint [lindex $segment 1]]]]
  }
  set row [dict get $nets $key]
  dict lappend row routes [J [list id [Q $route] paths [A $paths]]]
  dict set nets $key $row
 }
 set netJson {}
 dict for {key net} $nets {
  set members {}
  if {[dict exists [dict get $inv members] $key]} {set members [lsort -unique [dict get [dict get $inv members] $key]]}
  lappend netJson [J [list id [Q $key] name [Q [dict get $net name]] pinIds [strings $members] routes [A [dict get $net routes]]]]
 }
 set oldState "";if {!$scoped} {set oldState [existingState [dict get $record sourcePages]]}
 return [J [list readScope [Q [expr {$scoped ? "generated-sheet" : "project"}]] version 1 complete true unavailable {[]} sessionId [Q [session]] project [Q [project]] sheetId [Q [dict get $record sheetId]] \
  appearanceLabels [appearanceLabels $record] parts [A $parts] symbols [::coco_syscap_electrical::snapshot $record] nets [A $netJson] existingState [Q $oldState]]]
 } finally {if {$scoped} {file delete -force $appearanceCache}}
}
proc ::coco_syscap_generation::inspect {arg} {
 set record [load [dict get $arg operationId]]
 bound $record
 set snapshot null
 if {[dict get $record sheetId] ne ""} {
  set snapshot [snapshot $record]
  # A partial operation becomes inspectable; it is never resumed by another create.
  if {[dict get $record state] eq "partial"} {release $record}
 }
 set map {};dict for {key value} [dict get $record partMap] {dict set map $key [Q $value]}
 set baseline {};if {[dict exists $record baselineNetMembers]} {dict for {key pins} [dict get $record baselineNetMembers] {dict set baseline $key [strings [lsort -unique $pins]]}}
 set symbolMap {};if {[dict exists $record symbolMap]} {dict for {key value} [dict get $record symbolMap] {dict set symbolMap $key [Q $value]}}
 return [J [list readScope [Q [expr {[::coco_syscap_registered::scoped [dict get $record manifest]] ? "generated-sheet" : "project"}]] operationId [Q [dict get $record operationId]] state [Q [dict get $record state]] sheetId [Q [dict get $record sheetId]] \
  sessionId [Q [dict get $record sessionId]] project [Q [dict get $record project]] partMap [J $map] baselineNetMembers [J $baseline] baselineExistingState [Q [dict get $record existingState]] symbolMap [J $symbolMap] message [Q [dict get $record message]] snapshot $snapshot]]
}
proc ::coco_syscap_generation::execute {action arg} {
 switch -- $action {
  prepare {set data [prepare $arg]}
  create {set data [create $arg]}
  inspect {set data [inspect $arg]}
  cancel {set data [cancel $arg]}
  default {error "Unsupported circuit action"}
 }
 return [::coco_syscap_utils::json_success $data]
}

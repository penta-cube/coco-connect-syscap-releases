# Read-only library probe for CubicAI-12705. No component/page/wire/save commands.
namespace eval ::coco_syscap_circuit {
    # Survives re-source, changes when the interpreter is restarted.
    if {![info exists session_id]} { variable session_id "[pid]-[clock microseconds]" }
}
proc ::coco_syscap_circuit::probe {arg {sharedCacheVar ""}} {
    if {[llength $arg] != 5} { error "project/library/cell/part_name/package required" }
    foreach field $arg {
        if {[string trim $field] eq "" || [string length $field] > 4096 || [string first \x00 $field] >= 0} { error "Invalid probe input" }
    }
    lassign $arg project library cell part_name package
    if {![cps::isProjectOpen]} { error "No System Capture project is open" }
    set actual [file normalize [cps::getProjectMainCPM]]
    set requested [file normalize $project]
    if {$::tcl_platform(platform) eq "windows"} { set same [string equal -nocase $actual $requested] } else { set same [string equal $actual $requested] }
    if {!$same} { error "System Capture project changed" }
    set placement [::coco_syscap_native_library::placementCell $library $cell]
    if {![dict get $placement available]} {
        return [::coco_syscap_utils::json_success [::coco_syscap_generation::J [list version 2 coordinate_frame [::coco_syscap_generation::Q syscap-mil-y-up] session_id [::coco_syscap_generation::Q [::coco_syscap_generation::session]] project [::coco_syscap_generation::Q $actual] library [::coco_syscap_generation::Q $library] cell [::coco_syscap_generation::Q $cell] part_name [::coco_syscap_generation::Q $part_name] package [::coco_syscap_generation::Q $package] symbols {[]} physical_pins_confirmed false placement_available false placement_issue [::coco_syscap_generation::Q [dict get $placement reason]]]]]
    }
    set views [sch::getSymbolsListForPart $library $cell $part_name $package]
    set result {}
    set mapping_confirmed 1
    set cache_error ""
    # A batch shares only this caller-owned export. Standalone queries remain fresh.
    if {$sharedCacheVar ne ""} {upvar 1 $sharedCacheVar cache} else {set cache ""}
    if {[catch {
        if {$cache eq ""} {set cache [::coco_syscap_native_library::exportCurrent]}
    } cache_error]} {set mapping_confirmed 0} else {set cache_error ""}
    foreach view $views {
        set bbox [sch::dbGetLibCellViewBBox $library $cell $view]
        if {[llength $bbox] != 2 || [llength [lindex $bbox 0]] != 2 || [llength [lindex $bbox 1]] != 2} { error "Incomplete library symbol bounds" }
        set points {}
        foreach p $bbox {
            lassign $p x y
            foreach value $p { if {![string is double -strict $value] || $value != $value || abs($value) > 1e12} { error "Invalid library symbol bounds" } }
            lappend points [::coco_syscap_utils::json_array_from_values [list $x $y]]
        }
        set fields [list [::coco_syscap_utils::json_field_string view $view] \
            [::coco_syscap_utils::json_field_json bbox_db [::coco_syscap_utils::json_array_from_values $points]]]
        set mapping_error $cache_error
        if {$mapping_error eq ""} {
            if {[catch {::coco_syscap_native_library::resolve $cache $library $cell $view $part_name $package} native]} {
                set mapping_error $native
            } else {
                lappend fields [::coco_syscap_utils::json_field_string primitive [dict get $native primitive]]
                lappend fields [::coco_syscap_utils::json_field_json physical_pins [dict get $native pins]]
                if {[dict exists $native anchorSource]} {
                    lappend fields [::coco_syscap_utils::json_field_string anchor_source [dict get $native anchorSource]]
                }
            }
        }
        if {$mapping_error ne ""} {
            set mapping_confirmed 0
            lappend fields [::coco_syscap_utils::json_field_string mapping_issue $mapping_error]
        }
        if {$cache ne ""} {lappend fields [::coco_syscap_utils::json_field_json bodyGeometry [::coco_syscap_native_library::bodyGeometry $cache $library $cell $view]]}
        lappend result [::coco_syscap_utils::json_object_from_pairs $fields]
    }
    # An empty lookup is not success. Native physical pins are confirmed independently of symbol bounds.
    if {![llength $result]} { error "Requested part/package has no usable symbol view" }
    return [::coco_syscap_utils::json_success [::coco_syscap_utils::json_object_from_pairs [list \
        [::coco_syscap_utils::json_field_number version 2] \
        [::coco_syscap_utils::json_field_string coordinate_frame "syscap-mil-y-up"] \
        [::coco_syscap_utils::json_field_string session_id [::coco_syscap_generation::session]] \
        [::coco_syscap_utils::json_field_string project $actual] \
        [::coco_syscap_utils::json_field_string library $library] \
        [::coco_syscap_utils::json_field_string cell $cell] \
        [::coco_syscap_utils::json_field_string part_name $part_name] \
        [::coco_syscap_utils::json_field_string package $package] \
        [::coco_syscap_utils::json_field_json symbols [::coco_syscap_utils::json_array_from_values $result]] \
        [::coco_syscap_utils::json_field_bool physical_pins_confirmed $mapping_confirmed] \
        [::coco_syscap_utils::json_field_bool placement_available 1] \
        [::coco_syscap_utils::json_field_bool generation_ready 0]]]]
}

# Data-only, read-only batch. The cache is a local variable, never reused between
# RPCs unless explicitly handed to the matching preparation once. No updates occur here.
proc ::coco_syscap_circuit::profiles {arg} {
    # Keep at most one pending preparation snapshot; a new batch replaces it.
    variable preparation_snapshot
    set preparation_snapshot {}
    set requests [dict get $arg requests]
    if {[llength $requests]>4096} {error "Too many profile requests"}
    set project [::coco_syscap_generation::project]
    set session [::coco_syscap_generation::session]
    set cache "";set rows {}
    foreach request $requests {
        if {[catch {
            switch -- [dict get $request kind] {
                part {probe [dict get $request params] cache}
                symbol {::coco_syscap_electrical::probe [dict get $request params] cache}
                default {error "Unsupported profile request"}
            }
        } row]} {
            set row [::coco_syscap_utils::json_error profile_unavailable $row]
        }
        lappend rows $row
    }
    if {$project ne [::coco_syscap_generation::project] || $session ne [::coco_syscap_generation::session]} {error "Target changed during profile batch"}
    set fields [list profiles [::coco_syscap_generation::A $rows]]
    if {[dict exists $arg preparationId] && $cache ne ""} {
        set operation [::coco_syscap_generation::id [dict get $arg preparationId]]
        set token "[pid]-[clock microseconds]-$::coco_syscap_circuit::cache_sequence"
        set preparation_snapshot [dict create token $token operationId $operation project $project session $session \
            cache $cache created [clock clicks -milliseconds]]
        dict set fields snapshotToken [::coco_syscap_generation::Q $token]
    }
    return [::coco_syscap_utils::json_success [::coco_syscap_generation::J $fields]]
}

# Internal, one-use handoff to prepare; never used by create or inspect.
# A missing/replaced/expired snapshot falls back to the normal fresh validation.
proc ::coco_syscap_circuit::takePreparationSnapshot {token manifest} {
    variable preparation_snapshot
    if {![info exists preparation_snapshot] || $preparation_snapshot eq ""} {return ""}
    if {![string equal $token [dict get $preparation_snapshot token]]} {return ""}
    set snapshot $preparation_snapshot;set preparation_snapshot {}
    if {[dict get $snapshot operationId] ne [dict get $manifest operationId]} {error "Preparation snapshot belongs to another operation"}
    if {[dict get $snapshot session] ne [::coco_syscap_generation::session] ||
        [dict get $snapshot session] ne [dict get $manifest sessionId] ||
        [dict get $snapshot project] ne [::coco_syscap_generation::project] ||
        ![string equal -nocase [dict get $snapshot project] [file normalize [dict get $manifest project]]]} {error "Preparation snapshot target changed"}
    set age [expr {[clock clicks -milliseconds]-[dict get $snapshot created]}]
    if {$age<0 || $age>60000} {return ""}
    return [dict get $snapshot cache]
}

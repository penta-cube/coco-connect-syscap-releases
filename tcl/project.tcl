# project.tcl - project_info
# Reports the project currently open in System Capture so a caller can read
# the same design from disk (.cpm / .sdax) and check that its file view matches
# the live session.
#
# Every value is read independently. A value the running release does not
# provide is returned as null and its name is listed in "unavailable".

proc _coco_syscap_try {script} {
    if {[catch {uplevel #0 $script} result]} {
        return [list 0 ""]
    }
    return [list 1 $result]
}

proc _coco_syscap_json_string_or_null {value} {
    if {$value eq ""} {
        return [::coco_syscap_utils::json_null]
    }
    return [::coco_syscap_utils::json_quote $value]
}

proc _coco_syscap_json_bool_or_null {value} {
    if {$value eq ""} {
        return [::coco_syscap_utils::json_null]
    }
    return [::coco_syscap_utils::json_bool $value]
}

proc _coco_syscap_normalize_path {path} {
    if {$path eq ""} {
        return ""
    }
    return [file normalize $path]
}

# IServer_findDesign returns a design context (not an IDesign), so the flag is
# read with TDesignContext_isModified. cps::isDesignDirty is not used: it is
# already true right after a project is opened.
proc _coco_syscap_design_modified {cell} {
    if {$cell eq ""} {
        return ""
    }
    set server ""
    catch {set server [sdaConn::getServer]}
    if {$server eq ""} {
        return ""
    }
    set context ""
    catch {set context [IServer_findDesign $server $cell]}
    if {$context eq ""} {
        return ""
    }
    set modified ""
    if {[catch {set modified [TDesignContext_isModified $context]}]} {
        if {[catch {set modified [IDesign_isModified [TDesignContext_design $context]]}]} {
            return ""
        }
    }
    if {[string is integer -strict $modified] || [string is boolean -strict $modified]} {
        return [expr {$modified ? 1 : 0}]
    }
    return ""
}

proc ::coco_syscap_project_info_impl {} {
    set unavailable {}

    set project_open ""
    lassign [_coco_syscap_try {cps::isProjectOpen}] ok value
    if {$ok && ([string is integer -strict $value] || [string is boolean -strict $value])} {
        set project_open [expr {$value ? 1 : 0}]
    } else {
        lappend unavailable project_open
    }

    # In 25.1 getProjectDir returns the .sdax folder, not the folder holding
    # the .cpm. getProjectMainDir / getProjectMainCPM give the project itself.
    set project_dir ""
    foreach script {cps::getProjectMainDir cps::getProjectDir} {
        lassign [_coco_syscap_try $script] ok value
        if {$ok && $value ne ""} {
            set project_dir [_coco_syscap_normalize_path $value]
            break
        }
    }
    if {$project_dir eq ""} {
        lappend unavailable project_dir
    }

    set cpm_path ""
    lassign [_coco_syscap_try {cps::getProjectMainCPM}] ok value
    if {$ok && $value ne ""} {
        set cpm_path [_coco_syscap_normalize_path $value]
    }

    # getProjectCPM returns the file name only.
    lassign [_coco_syscap_try {cps::getProjectCPM}] ok value
    if {$cpm_path eq "" && $ok && $value ne ""} {
        if {[file pathtype $value] eq "absolute"} {
            set cpm_path [_coco_syscap_normalize_path $value]
        } elseif {$project_dir ne ""} {
            set cpm_path [_coco_syscap_normalize_path [file join $project_dir $value]]
        }
    }
    if {$cpm_path eq ""} {
        lappend unavailable cpm_path
    }

    set sdax_path ""
    foreach script {getSDAXPath cps::getSDAXPath sch::getSDAXPath} {
        lassign [_coco_syscap_try $script] ok value
        if {$ok && $value ne ""} {
            set sdax_path [_coco_syscap_normalize_path $value]
            break
        }
    }
    if {$sdax_path eq ""} {
        lappend unavailable sdax_path
    }

    set design_name ""
    lassign [_coco_syscap_try {sch::dbGetRootDesignName}] ok value
    if {$ok && $value ne ""} {
        set design_name $value
    } else {
        lappend unavailable design_name
    }

    set design_library ""
    lassign [_coco_syscap_try {cps::getDirectiveValue GLOBAL design_library}] ok value
    if {$ok} {
        set design_library [string trim $value "' \""]
    }
    if {$design_library eq ""} {
        lappend unavailable design_library
    }

    set modified [_coco_syscap_design_modified $design_name]
    if {$modified eq ""} {
        lappend unavailable modified
    }

    set app_version ""
    lassign [_coco_syscap_try {cps::getAppVersion}] ok value
    if {$ok && $value ne ""} {
        set app_version $value
    } else {
        lappend unavailable app_version
    }

    set unavailable_json {}
    foreach name $unavailable {
        lappend unavailable_json [::coco_syscap_utils::json_quote $name]
    }

    return [::coco_syscap_utils::json_success \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_json project_open [_coco_syscap_json_bool_or_null $project_open]] \
            [::coco_syscap_utils::json_field_json project_dir [_coco_syscap_json_string_or_null $project_dir]] \
            [::coco_syscap_utils::json_field_json cpm_path [_coco_syscap_json_string_or_null $cpm_path]] \
            [::coco_syscap_utils::json_field_json sdax_path [_coco_syscap_json_string_or_null $sdax_path]] \
            [::coco_syscap_utils::json_field_json design_name [_coco_syscap_json_string_or_null $design_name]] \
            [::coco_syscap_utils::json_field_json design_library [_coco_syscap_json_string_or_null $design_library]] \
            [::coco_syscap_utils::json_field_json modified [_coco_syscap_json_bool_or_null $modified]] \
            [::coco_syscap_utils::json_field_json app_version [_coco_syscap_json_string_or_null $app_version]] \
            [::coco_syscap_utils::json_field_json unavailable [::coco_syscap_utils::json_array_from_values $unavailable_json]]]]]
}

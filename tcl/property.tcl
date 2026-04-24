# property.tcl - list_part_properties / part_property_get / part_property_set / part_property_delete
# Uses ::sch:: Tcl API (read) and UI commands (write) available in Allegro System Capture
#
# Read:  ::sch::dbGetPropertiesFromSPath returns list of {key val} pairs
#        ::sch::dbGetPropertyValueFromSPath returns single value
# Write: addProp -name {n} -value {v} -type 0 -display nodisp  (requires object selected)
#        deleteProp -name {n}                                   (requires object selected)
# Display: modifyProp -name {n} -display nodisp|nameOnly|valOnly|both

proc _coco_syscap_find_inst_record {refdes} {
    set page [::sch::dbGetActivePage]
    set items [::sch::dbGetPageItems $page]

    foreach item $items {
        set t ""
        catch {set t [::sch::dbGetType $item]}
        if {$t != 16} continue

        set sp ""
        catch {set sp [::sch::dbGetSPath $item]}
        if {$sp eq ""} continue

        set info ""
        catch {set info [::sch::dbxGetRefDesAndOriginFromInstSpath $sp]}
        if {$info eq ""} continue

        set rd ""
        foreach pair $info {
            if {[lindex $pair 0] eq "refdes"} {
                set rd [lindex $pair 1]
                break
            }
        }
        if {[string equal -nocase $rd $refdes]} {
            return [list $item $sp]
        }
    }

    error [::coco_syscap_utils::json_error "not_found" \
        "Part '$refdes' not found on active page" \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes]]]]
}

proc _coco_syscap_find_inst_spath {refdes} {
    lindex [_coco_syscap_find_inst_record $refdes] 1
}

proc _coco_syscap_select_inst {refdes} {
    set record [_coco_syscap_find_inst_record $refdes]
    set sp [lindex $record 1]

    set page_sp [::sch::dbxGetActivePageSpath]

    set pos_json ""
    catch {set pos_json [::sch::dbGetInfoFromInstanceSpath $sp]}
    if {$pos_json eq ""} {
        error [::coco_syscap_utils::json_error "position_error" \
            "Could not get position for '$refdes'" \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes]]]]
    }

    set x ""
    set y ""
    regexp {"x"\s*:\s*([0-9\-]+)} $pos_json -> x
    regexp {"y"\s*:\s*([0-9\-]+)} $pos_json -> y

    selectObject -occPath $page_sp -type INST $x $y
    return $sp
}

proc ::coco_syscap_list_part_properties_impl {refdes} {
    set sp [_coco_syscap_find_inst_spath $refdes]

    set props {}
    catch {set props [::sch::dbGetPropertiesFromSPath $sp]}

    set pairs {}
    foreach pair $props {
        set key [lindex $pair 0]
        set val [lindex $pair 1]
        lappend pairs [::coco_syscap_utils::json_field_string $key $val]
    }

    return [::coco_syscap_utils::json_success \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes] \
            [::coco_syscap_utils::json_field_json properties \
                [::coco_syscap_utils::json_object_from_pairs $pairs]]]]]
}

proc ::coco_syscap_part_property_get_impl {refdes property_name} {
    set sp [_coco_syscap_find_inst_spath $refdes]

    set value ""
    catch {set value [::sch::dbGetPropertyValueFromSPath $sp $property_name]}

    if {$value eq ""} {
        set props {}
        catch {set props [::sch::dbGetPropertiesFromSPath $sp]}
        foreach pair $props {
            if {[string equal -nocase [lindex $pair 0] $property_name]} {
                set value [lindex $pair 1]
                break
            }
        }
    }

    if {$value eq ""} {
        error [::coco_syscap_utils::json_error "not_found" \
            "Property '$property_name' not found on '$refdes'" \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes] \
                [::coco_syscap_utils::json_field_string property $property_name]]]]
    }

    return [::coco_syscap_utils::json_success \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes] \
            [::coco_syscap_utils::json_field_string property $property_name] \
            [::coco_syscap_utils::json_field_string value $value]]]]
}

proc ::coco_syscap_part_property_set_impl {refdes property_name value} {
    set sp [_coco_syscap_select_inst $refdes]

    set ok 0
    set err ""
    catch {
        addProp -name $property_name -value $value -type 0 -display nodisp
        set ok 1
    } err

    if {!$ok} {
        error [::coco_syscap_utils::json_error "set_failed" \
            "Could not set property '$property_name' on '$refdes': $err" \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes] \
                [::coco_syscap_utils::json_field_string property $property_name]]]]
    }

    set actual ""
    catch {set actual [::sch::dbGetPropertyValueFromSPath $sp $property_name]}
    if {![string equal $actual $value]} {
        error [::coco_syscap_utils::json_error "set_verify_failed" \
            "Property '$property_name' on '$refdes' was not updated as expected" \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes] \
                [::coco_syscap_utils::json_field_string property $property_name] \
                [::coco_syscap_utils::json_field_string expected $value] \
                [::coco_syscap_utils::json_field_string actual $actual]]]]
    }

    return [::coco_syscap_utils::json_success \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes] \
            [::coco_syscap_utils::json_field_string property $property_name] \
            [::coco_syscap_utils::json_field_string value $value]]]]
}

proc ::coco_syscap_part_property_delete_impl {refdes property_name} {
    set sp [_coco_syscap_select_inst $refdes]

    set ok 0
    set err ""
    catch {
        deleteProp -name $property_name
        set ok 1
    } err

    if {!$ok} {
        error [::coco_syscap_utils::json_error "delete_failed" \
            "Could not delete property '$property_name' on '$refdes': $err" \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes] \
                [::coco_syscap_utils::json_field_string property $property_name]]]]
    }

    set props {}
    catch {set props [::sch::dbGetPropertiesFromSPath $sp]}
    foreach pair $props {
        if {[string equal -nocase [lindex $pair 0] $property_name]} {
            error [::coco_syscap_utils::json_error "delete_verify_failed" \
                "Property '$property_name' on '$refdes' still exists after delete" \
                [::coco_syscap_utils::json_object_from_pairs [list \
                    [::coco_syscap_utils::json_field_string refdes $refdes] \
                    [::coco_syscap_utils::json_field_string property $property_name] \
                    [::coco_syscap_utils::json_field_string value [lindex $pair 1]]]]]
        }
    }

    return [::coco_syscap_utils::json_success \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes] \
            [::coco_syscap_utils::json_field_string property $property_name] \
            [::coco_syscap_utils::json_field_string status "deleted"]]]]
}

proc ::coco_syscap_part_property_display_mode_impl {refdes property_name display_mode} {
    _coco_syscap_select_inst $refdes

    switch -- $display_mode {
        hidden { set ui_mode "nodisp" }
        name_only { set ui_mode "nameOnly" }
        value_only { set ui_mode "valOnly" }
        name_and_value { set ui_mode "both" }
        default {
            error [::coco_syscap_utils::json_error "invalid_arg" \
                "display mode must be one of: hidden, name_only, value_only, name_and_value" \
                [::coco_syscap_utils::json_object_from_pairs [list \
                    [::coco_syscap_utils::json_field_string refdes $refdes] \
                    [::coco_syscap_utils::json_field_string property $property_name] \
                    [::coco_syscap_utils::json_field_string display_mode $display_mode]]]]
        }
    }

    set ok 0
    set err ""
    catch {
        modifyProp -name $property_name -display $ui_mode
        set ok 1
    } err

    if {!$ok} {
        error [::coco_syscap_utils::json_error "display_mode_failed" \
            "Could not change display mode for property '$property_name' on '$refdes': $err" \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes] \
                [::coco_syscap_utils::json_field_string property $property_name] \
                [::coco_syscap_utils::json_field_string display_mode $display_mode]]]]
    }

    return [::coco_syscap_utils::json_success \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes] \
            [::coco_syscap_utils::json_field_string property $property_name] \
            [::coco_syscap_utils::json_field_string display_mode $display_mode]]]]
}

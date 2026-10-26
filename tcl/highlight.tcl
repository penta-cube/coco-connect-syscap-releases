# highlight.tcl - highlight_part / highlight_net / clear_highlight
# Uses ::sch:: Tcl API available in Allegro System Capture
#
# Coordinate conversion:
#   dbGetPos / dbGetBBox return internal DB units
#   selectObject uses schematic grid coordinates
#   Conversion: DB_unit / 254 = schematic coordinate
#   (e.g. dbGetPos 4191000 1295400 -> selectObject 16500 5100)

proc _coco_syscap_db_to_sch {db_val} {
    expr {round($db_val / 254.0)}
}

proc _coco_syscap_try_select_route_at {page page_sp x y} {
    catch {selectObject -occPath $page_sp -type ROUTE $x $y}
    after 50

    set sel {}
    catch {set sel [::sch::dbGetSelectedItems $page]}
    if {[llength $sel] > 0} {
        return $sel
    }
    return {}
}

proc _coco_syscap_try_select_note_at {page page_sp x y} {
    catch {selectObject -occPath $page_sp -type SIMPLE_NOTE $x $y}
    after 50

    set sel {}
    catch {set sel [::sch::dbGetSelectedItems $page]}
    if {[llength $sel] > 0} {
        return $sel
    }
    return {}
}

proc _coco_syscap_selection_is_empty {page} {
    set sel {}
    catch {set sel [::sch::dbGetSelectedItems $page]}
    expr {[llength $sel] == 0}
}

proc _coco_syscap_selected_items_match_net {selected_items net_name} {
    foreach item $selected_items {
        set name ""
        set text ""
        catch {set name [::sch::dbGetItemName $item]}
        catch {set text [::sch::dbGetItemText $item]}
        if {[string equal -nocase $name $net_name]} {
            return 1
        }
        if {[string equal -nocase $text $net_name]} {
            return 1
        }
    }
    return 0
}

proc _coco_syscap_route_candidate_points_from_bbox {bbox} {
    if {$bbox eq ""} {
        return {}
    }

    set b1 [lindex $bbox 0]
    set b2 [lindex $bbox 1]
    set x1 [_coco_syscap_db_to_sch [lindex $b1 0]]
    set y1 [_coco_syscap_db_to_sch [lindex $b1 1]]
    set x2 [_coco_syscap_db_to_sch [lindex $b2 0]]
    set y2 [_coco_syscap_db_to_sch [lindex $b2 1]]

    set xm [expr {round(($x1 + $x2) / 2.0)}]
    set ym [expr {round(($y1 + $y2) / 2.0)}]
    set dx [expr {max(5, round(($x2 - $x1) / 4.0))}]
    set dy [expr {max(5, round(($y2 - $y1) / 4.0))}]

    set points {}

    foreach pt [list \
        [list $xm $ym] \
        [list $x1 $y1] [list $x1 $ym] [list $x1 $y2] \
        [list $xm $y1]                 [list $xm $y2] \
        [list $x2 $y1] [list $x2 $ym] [list $x2 $y2] \
        [list [expr {$xm - $dx}] $ym] [list [expr {$xm + $dx}] $ym] \
        [list $xm [expr {$ym - $dy}]] [list $xm [expr {$ym + $dy}]] \
        [list [expr {$x1 + $dx}] [expr {$y1 + $dy}]] \
        [list [expr {$x2 - $dx}] [expr {$y1 + $dy}]] \
        [list [expr {$x1 + $dx}] [expr {$y2 - $dy}]] \
        [list [expr {$x2 - $dx}] [expr {$y2 - $dy}]] \
    ] {
        if {[lsearch -exact $points $pt] < 0} {
            lappend points $pt
        }
    }

    return $points
}

proc _coco_syscap_find_note_hitpoint {page page_sp item net_name} {
    set candidates {}

    set bbox ""
    catch {set bbox [::sch::dbGetBBox $item]}
    foreach pt [_coco_syscap_route_candidate_points_from_bbox $bbox] {
        if {[lsearch -exact $candidates $pt] < 0} {
            lappend candidates $pt
        }
    }

    set pos_raw ""
    catch {set pos_raw [::sch::dbGetPos $item]}
    if {$pos_raw ne "" && !([lindex $pos_raw 0] == 0 && [lindex $pos_raw 1] == 0)} {
        set pt [list \
            [_coco_syscap_db_to_sch [lindex $pos_raw 0]] \
            [_coco_syscap_db_to_sch [lindex $pos_raw 1]]]
        if {[lsearch -exact $candidates $pt] < 0} {
            lappend candidates $pt
        }
    }

    foreach pt $candidates {
        set x [lindex $pt 0]
        set y [lindex $pt 1]
        set sel [_coco_syscap_try_select_note_at $page $page_sp $x $y]
        if {[llength $sel] > 0 && [_coco_syscap_selected_items_match_net $sel $net_name]} {
            return [list $x $y $sel]
        }
    }

    return {}
}

proc _coco_syscap_bbox_union_init {bbox} {
    set b1 [lindex $bbox 0]
    set b2 [lindex $bbox 1]
    return [list \
        [expr {min([lindex $b1 0], [lindex $b2 0])}] \
        [expr {min([lindex $b1 1], [lindex $b2 1])}] \
        [expr {max([lindex $b1 0], [lindex $b2 0])}] \
        [expr {max([lindex $b1 1], [lindex $b2 1])}]]
}

proc _coco_syscap_bbox_union_merge {acc bbox} {
    if {$acc eq ""} {
        return [_coco_syscap_bbox_union_init $bbox]
    }
    set cur [_coco_syscap_bbox_union_init $bbox]
    return [list \
        [expr {min([lindex $acc 0], [lindex $cur 0])}] \
        [expr {min([lindex $acc 1], [lindex $cur 1])}] \
        [expr {max([lindex $acc 2], [lindex $cur 2])}] \
        [expr {max([lindex $acc 3], [lindex $cur 3])}]]
}

proc _coco_syscap_collect_net_union_bbox {items net_name note_item} {
    set union_bbox ""

    if {$note_item ne ""} {
        set bbox ""
        catch {set bbox [::sch::dbGetBBox $note_item]}
        if {$bbox ne ""} {
            set union_bbox [_coco_syscap_bbox_union_merge $union_bbox $bbox]
        }
    }

    foreach item $items {
        set t ""
        catch {set t [::sch::dbGetType $item]}
        if {$t != 21 && $t != 26} continue

        set name ""
        catch {set name [::sch::dbGetItemName $item]}
        if {![string equal -nocase $name $net_name]} continue

        set bbox ""
        catch {set bbox [::sch::dbGetBBox $item]}
        if {$bbox eq ""} continue

        set union_bbox [_coco_syscap_bbox_union_merge $union_bbox $bbox]
    }

    return $union_bbox
}

proc _coco_syscap_zoom_union_bbox {union_bbox {padding 100}} {
    if {$union_bbox eq ""} {
        return
    }

    _coco_syscap_zoom_to_bbox \
        [_coco_syscap_db_to_sch [lindex $union_bbox 0]] \
        [_coco_syscap_db_to_sch [lindex $union_bbox 1]] \
        [_coco_syscap_db_to_sch [lindex $union_bbox 2]] \
        [_coco_syscap_db_to_sch [lindex $union_bbox 3]] \
        $padding
}

proc _coco_syscap_find_route_hitpoint {page page_sp route_item} {
    set candidates {}

    # Midpoints of the real wire segments come first. Points taken from the
    # bounding box can all miss a bent (L-shaped) wire.
    # dbGetSegments returns {{x1 y1} {x2 y2} type}; type 28 is a wire segment.
    set segments {}
    catch {set segments [::sch::dbGetSegments $route_item]}
    foreach seg $segments {
        if {[lindex $seg 2] != 28} continue
        set p1 [lindex $seg 0]
        set p2 [lindex $seg 1]
        if {[lindex $p1 0] == [lindex $p2 0] && [lindex $p1 1] == [lindex $p2 1]} continue
        set pt [list \
            [_coco_syscap_db_to_sch [expr {([lindex $p1 0] + [lindex $p2 0]) / 2}]] \
            [_coco_syscap_db_to_sch [expr {([lindex $p1 1] + [lindex $p2 1]) / 2}]]]
        if {[lsearch -exact $candidates $pt] < 0} {
            lappend candidates $pt
        }
    }

    set pos_raw ""
    catch {set pos_raw [::sch::dbGetPos $route_item]}
    if {$pos_raw ne "" && !([lindex $pos_raw 0] == 0 && [lindex $pos_raw 1] == 0)} {
        lappend candidates [list \
            [_coco_syscap_db_to_sch [lindex $pos_raw 0]] \
            [_coco_syscap_db_to_sch [lindex $pos_raw 1]]]
    }

    set bbox ""
    catch {set bbox [::sch::dbGetBBox $route_item]}
    foreach pt [_coco_syscap_route_candidate_points_from_bbox $bbox] {
        if {[lsearch -exact $candidates $pt] < 0} {
            lappend candidates $pt
        }
    }

    set children {}
    catch {set children [::sch::dbGetChildren $route_item]}
    foreach child $children {
        set child_pos ""
        catch {set child_pos [::sch::dbGetPos $child]}
        if {$child_pos ne "" && !([lindex $child_pos 0] == 0 && [lindex $child_pos 1] == 0)} {
            set pt [list \
                [_coco_syscap_db_to_sch [lindex $child_pos 0]] \
                [_coco_syscap_db_to_sch [lindex $child_pos 1]]]
            if {[lsearch -exact $candidates $pt] < 0} {
                lappend candidates $pt
            }
        }

        set child_bbox ""
        catch {set child_bbox [::sch::dbGetBBox $child]}
        foreach pt [_coco_syscap_route_candidate_points_from_bbox $child_bbox] {
            if {[lsearch -exact $candidates $pt] < 0} {
                lappend candidates $pt
            }
        }
    }

    foreach pt $candidates {
        set x [lindex $pt 0]
        set y [lindex $pt 1]
        set sel [_coco_syscap_try_select_route_at $page $page_sp $x $y]
        if {[llength $sel] > 0 && [_coco_syscap_selected_items_match_net $sel [::sch::dbGetItemName $route_item]]} {
            return [list $x $y $sel]
        }
    }

    return {}
}

# Zoom to a bounding box (schematic coordinates) with padding
proc _coco_syscap_zoom_to_bbox {x1 y1 x2 y2 {padding 100}} {
    set px1 [expr {$x1 - $padding}]
    set py1 [expr {$y1 - $padding}]
    set px2 [expr {$x2 + $padding}]
    set py2 [expr {$y2 + $padding}]
    catch {zoom -rect $px1 $py1 $px2 $py2}
}

# highlight_part: find component by refdes, select with -type INST, zoom to it
proc ::coco_syscap_highlight_part_impl {refdes} {
    set page    [::sch::dbGetActivePage]
    set page_sp [::sch::dbxGetActivePageSpath]
    set items   [::sch::dbGetPageItems $page]

    foreach item $items {
        set t ""
        catch {set t [::sch::dbGetType $item]}
        if {$t != 16} continue

        set sp ""
        catch {set sp [::sch::dbGetSPath $item]}
        if {$sp eq ""} continue

        # parse {origin 32} {refdes C38}
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
        if {![string equal -nocase $rd $refdes]} continue

        # get schematic coordinates from JSON {"x": 16500, "y": 5100}
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

        if {$x eq "" || $y eq ""} {
            error [::coco_syscap_utils::json_error "position_parse_error" \
                "Could not parse x/y for '$refdes'" \
                [::coco_syscap_utils::json_object_from_pairs [list \
                    [::coco_syscap_utils::json_field_string refdes $refdes] \
                    [::coco_syscap_utils::json_field_string pos_json $pos_json]]]]
        }

        selectObject -occPath $page_sp -type INST $x $y

        # zoom to item BBox
        set bbox ""
        catch {set bbox [::sch::dbGetBBox $item]}
        if {$bbox ne ""} {
            set b1 [lindex $bbox 0]
            set b2 [lindex $bbox 1]
            _coco_syscap_zoom_to_bbox \
                [_coco_syscap_db_to_sch [lindex $b1 0]] \
                [_coco_syscap_db_to_sch [lindex $b1 1]] \
                [_coco_syscap_db_to_sch [lindex $b2 0]] \
                [_coco_syscap_db_to_sch [lindex $b2 1]]
        }

        return [::coco_syscap_utils::json_success \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string refdes $refdes] \
                [::coco_syscap_utils::json_field_number x $x] \
                [::coco_syscap_utils::json_field_number y $y]]]]
    }

    error [::coco_syscap_utils::json_error "not_found" \
        "Part '$refdes' not found on active page" \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string refdes $refdes]]]]
}

# highlight_net: prefer visible signal-name label, then fall back to route probing
# Search order:
#   1. SIMPLE_NOTE - visible signal-name label (what users usually click)
#   2. Power(21) - power nets like AGND, GND, VCC
#   3. Route(26) - signal net wire (VIN_FUNC, etc.)
#      Route dbGetPos may be 0 0, so probe multiple hit-points from bbox/children
proc ::coco_syscap_highlight_net_impl {net_name} {
    set page    [::sch::dbGetActivePage]
    set page_sp [::sch::dbxGetActivePageSpath]
    set items   [::sch::dbGetPageItems $page]

    # Pass 1: SIMPLE_NOTE - visible signal-name labels
    foreach item $items {
        set t ""
        catch {set t [::sch::dbGetType $item]}
        set type_name ""
        catch {set type_name [::sch::dbType2Name $t]}
        if {![string equal -nocase $type_name "SimpleNote"] && ![string equal -nocase $type_name "SIMPLE_NOTE"]} {
            continue
        }

        set name ""
        set text ""
        catch {set name [::sch::dbGetItemName $item]}
        catch {set text [::sch::dbGetItemText $item]}
        if {![string equal -nocase $name $net_name] && ![string equal -nocase $text $net_name]} {
            continue
        }

        set hit [_coco_syscap_find_note_hitpoint $page $page_sp $item $net_name]
        if {$hit eq ""} {
            continue
        }
        set x [lindex $hit 0]
        set y [lindex $hit 1]

        set union_bbox [_coco_syscap_collect_net_union_bbox $items $net_name $item]
        _coco_syscap_zoom_union_bbox $union_bbox 100

        return [::coco_syscap_utils::json_success \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string net $net_name] \
                [::coco_syscap_utils::json_field_string selected_type "SIMPLE_NOTE"] \
                [::coco_syscap_utils::json_field_number x $x] \
                [::coco_syscap_utils::json_field_number y $y]]]]
    }

    # Pass 2: Power(21) - power nets like AGND, GND, VCC
    foreach item $items {
        set t ""
        catch {set t [::sch::dbGetType $item]}
        if {$t != 21} continue

        set name ""
        catch {set name [::sch::dbGetItemName $item]}
        if {![string equal -nocase $name $net_name]} continue

        set pos_raw ""
        catch {set pos_raw [::sch::dbGetPos $item]}
        if {$pos_raw eq ""} continue

        set x [_coco_syscap_db_to_sch [lindex $pos_raw 0]]
        set y [_coco_syscap_db_to_sch [lindex $pos_raw 1]]

        set sel [_coco_syscap_try_select_route_at $page $page_sp $x $y]
        if {[llength $sel] == 0 || ![_coco_syscap_selected_items_match_net $sel $net_name]} {
            continue
        }

        set union_bbox [_coco_syscap_collect_net_union_bbox $items $net_name ""]
        _coco_syscap_zoom_union_bbox $union_bbox 100

        return [::coco_syscap_utils::json_success \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string net $net_name] \
                [::coco_syscap_utils::json_field_string selected_type "ROUTE"] \
                [::coco_syscap_utils::json_field_number x $x] \
                [::coco_syscap_utils::json_field_number y $y]]]]
    }

    # Pass 3: Route(26) - named signal nets like VIN_FUNC
    foreach item $items {
        set t ""
        catch {set t [::sch::dbGetType $item]}
        if {$t != 26} continue

        set name ""
        catch {set name [::sch::dbGetItemName $item]}
        if {![string equal -nocase $name $net_name]} continue

        set bbox ""
        catch {set bbox [::sch::dbGetBBox $item]}
        if {$bbox eq ""} continue

        set hit [_coco_syscap_find_route_hitpoint $page $page_sp $item]
        if {$hit eq ""} {
            continue
        }
        set x [lindex $hit 0]
        set y [lindex $hit 1]

        set union_bbox [_coco_syscap_collect_net_union_bbox $items $net_name ""]
        _coco_syscap_zoom_union_bbox $union_bbox 100

        return [::coco_syscap_utils::json_success \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string net $net_name] \
                [::coco_syscap_utils::json_field_string selected_type "ROUTE"] \
                [::coco_syscap_utils::json_field_number x $x] \
                [::coco_syscap_utils::json_field_number y $y]]]]
    }

    catch {selectObject 0 0}
    error [::coco_syscap_utils::json_error "not_found" \
        "Net '$net_name' not found on active page" \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string net $net_name]]]]
}

# clear_highlight: deselect current selection
# Prefer built-in clearSelection, then fall back to off-object clicks
proc ::coco_syscap_clear_highlight_impl {} {
    set page [::sch::dbGetActivePage]

    catch {clearSelection}
    after 50
    if {[_coco_syscap_selection_is_empty $page]} {
        return [::coco_syscap_utils::json_success \
            [::coco_syscap_utils::json_object_from_pairs [list \
                [::coco_syscap_utils::json_field_string status "cleared"] \
                [::coco_syscap_utils::json_field_string method "clearSelection"]]]]
    }

    foreach cmd {
        {selectObject -999999 -999999}
        {selectObject 0 0}
        {selectObject -500000 -500000}
        {selectObject 999999 999999}
    } {
        catch {uplevel #0 $cmd}
        after 50
        if {[_coco_syscap_selection_is_empty $page]} {
            return [::coco_syscap_utils::json_success \
                [::coco_syscap_utils::json_object_from_pairs [list \
                    [::coco_syscap_utils::json_field_string status "cleared"] \
                    [::coco_syscap_utils::json_field_string method $cmd]]]]
        }
    }

    set sel {}
    catch {set sel [::sch::dbGetSelectedItems $page]}
    error [::coco_syscap_utils::json_error "clear_failed" \
        "Could not clear current selection" \
        [::coco_syscap_utils::json_object_from_pairs [list \
            [::coco_syscap_utils::json_field_string remaining_selection $sel]]]]
}

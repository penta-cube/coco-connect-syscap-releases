# coco_syscap_bootstrap.tcl
#
# System Capture-side Tcl bridge for coco-connect-syscap.
# Line protocol (UTF-8):
#   request:  id<TAB>cmd<TAB>arg<TAB>token\n
#   response: id<TAB>json\n
#
# Architecture:
#   Runs entirely on the calling (main) interpreter.
#   ::sch::* and UI commands are only available in the main interpreter, so
#   no worker thread is used.
#
#   start  opens the TCP server socket; returns immediately.
#   run    enters a vwait-based event loop so that fileevent callbacks fire.
#          This call blocks the Tcl console until stop is called, but keeps
#          the bridge responsive.
#
#   Auto-start at the bottom calls both start and run.
#   Set env COCO_SYSCAP_BRIDGE_DISABLE_AUTO_START=1 to suppress this.

namespace eval ::coco_syscap_bridge {
    variable host        "127.0.0.1"
    variable port        49501
    variable token       ""
    variable server_sock ""
    variable running     0
    variable wait_signal 0
    variable script_dir  [file normalize [file dirname [info script]]]
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
proc ::coco_syscap_bridge::_source_utf8 {path} {
    set fd [open $path r]
    fconfigure $fd -encoding utf-8 -translation auto
    set src [read $fd]
    close $fd
    uplevel #0 $src
}

proc ::coco_syscap_bridge::_load_impl {} {
    variable script_dir
    set dir $script_dir
    foreach f {utils.tcl highlight.tcl property.tcl} {
        set fp [file join $dir $f]
        if {[file exists $fp]} {
            catch {::coco_syscap_bridge::_source_utf8 $fp}
        }
    }
}

# ---------------------------------------------------------------------------
# dispatch - runs on the main interpreter; has full access to ::sch::*
# ---------------------------------------------------------------------------
proc ::coco_syscap_bridge::_dispatch {cmd arg} {
    switch -- $cmd {
        ping {
            return [::coco_syscap_utils::json_success \
                [::coco_syscap_utils::json_object_from_pairs [list \
                    [::coco_syscap_utils::json_field_string command "ping"] \
                    [::coco_syscap_utils::json_field_string message "pong"] \
                    [::coco_syscap_utils::json_field_number pid [pid]]]]]
        }
        highlight_part {
            set part [string trim $arg]
            if {$part eq ""} {
                error [::coco_syscap_utils::json_error "invalid_arg" "refdes is required"]
            }
            if {[llength [info commands ::coco_syscap_highlight_part_impl]] == 0} {
                error [::coco_syscap_utils::json_error "missing_impl" \
                    "highlight_part not implemented"]
            }
            return [::coco_syscap_highlight_part_impl $part]
        }
        highlight_net {
            set net [string trim $arg]
            if {$net eq ""} {
                error [::coco_syscap_utils::json_error "invalid_arg" "net is required"]
            }
            if {[llength [info commands ::coco_syscap_highlight_net_impl]] == 0} {
                error [::coco_syscap_utils::json_error "missing_impl" \
                    "highlight_net not implemented"]
            }
            return [::coco_syscap_highlight_net_impl $net]
        }
        clear_highlight - clear - clear_selection - unhighlight {
            if {[llength [info commands ::coco_syscap_clear_highlight_impl]] == 0} {
                error [::coco_syscap_utils::json_error "missing_impl" \
                    "clear_highlight not implemented"]
            }
            return [::coco_syscap_clear_highlight_impl]
        }
        part_properties - list_part_properties {
            set part [string trim $arg]
            if {$part eq ""} {
                error [::coco_syscap_utils::json_error "invalid_arg" "refdes is required"]
            }
            if {[llength [info commands ::coco_syscap_list_part_properties_impl]] == 0} {
                error [::coco_syscap_utils::json_error "missing_impl" \
                    "part_properties not implemented"]
            }
            return [::coco_syscap_list_part_properties_impl $part]
        }
        part_property_get {
            set fields [split $arg "|"]
            if {[llength $fields] < 2} {
                error [::coco_syscap_utils::json_error "invalid_arg" "arg format: refdes|property"]
            }
            set part [string trim [lindex $fields 0]]
            set prop [string trim [join [lrange $fields 1 end] "|"]]
            return [::coco_syscap_part_property_get_impl $part $prop]
        }
        part_property_set {
            set fields [split $arg "|"]
            if {[llength $fields] < 3} {
                error [::coco_syscap_utils::json_error "invalid_arg" \
                    "arg format: refdes|property|value"]
            }
            set part  [string trim [lindex $fields 0]]
            set prop  [string trim [lindex $fields 1]]
            set value [join [lrange $fields 2 end] "|"]
            return [::coco_syscap_part_property_set_impl $part $prop $value]
        }
        part_property_delete {
            set fields [split $arg "|"]
            if {[llength $fields] < 2} {
                error [::coco_syscap_utils::json_error "invalid_arg" "arg format: refdes|property"]
            }
            set part [string trim [lindex $fields 0]]
            set prop [string trim [join [lrange $fields 1 end] "|"]]
            return [::coco_syscap_part_property_delete_impl $part $prop]
        }
        part_property_display_mode {
            set fields [split $arg "|"]
            if {[llength $fields] < 3} {
                error [::coco_syscap_utils::json_error "invalid_arg" \
                    "arg format: refdes|property|display_mode"]
            }
            set part [string trim [lindex $fields 0]]
            set prop [string trim [lindex $fields 1]]
            set mode [string trim [join [lrange $fields 2 end] "|"]]
            return [::coco_syscap_part_property_display_mode_impl $part $prop $mode]
        }
        default {
            error [::coco_syscap_utils::json_error "unknown_command" \
                "Unknown command '$cmd'"]
        }
    }
}

# ---------------------------------------------------------------------------
# Socket callbacks
# ---------------------------------------------------------------------------
proc ::coco_syscap_bridge::_on_readable {chan} {
    variable token

    if {[eof $chan]} {
        catch {close $chan}
        return
    }

    set n [gets $chan line]
    if {$n < 0} return

    set fields [split $line "\t"]
    if {[llength $fields] < 4} {
        catch {
            puts $chan "\t{\"ok\":false,\"error\":{\"code\":\"malformed_request\",\"message\":\"Malformed request\"}}"
            flush $chan
        }
        catch {close $chan}
        return
    }

    set id        [lindex $fields 0]
    set cmd       [lindex $fields 1]
    set arg       [lindex $fields 2]
    set req_token [lindex $fields 3]

    if {$token ne "" && $req_token ne $token} {
        catch {
            puts $chan "$id\t{\"ok\":false,\"error\":{\"code\":\"auth_failed\",\"message\":\"AUTH_FAILED\"}}"
            flush $chan
        }
        catch {close $chan}
        return
    }

    if {[catch {set resp [::coco_syscap_bridge::_dispatch $cmd $arg]} err]} {
        set resp [::coco_syscap_utils::ensure_error_json $err]
    }

    set safe_resp [string map [list "\n" " " "\r" " " "\t" " "] $resp]
    set safe_id   [string map [list "\n" " " "\r" " " "\t" " "] $id]

    catch {
        puts $chan "${safe_id}\t${safe_resp}"
        flush $chan
    }
    catch {close $chan}
}

proc ::coco_syscap_bridge::_on_accept {chan addr remote_port} {
    fconfigure $chan -encoding utf-8 -translation lf -buffering line -blocking 0
    fileevent $chan readable [list ::coco_syscap_bridge::_on_readable $chan]
}

# ---------------------------------------------------------------------------
# start - open server socket; returns immediately.
# ---------------------------------------------------------------------------
proc ::coco_syscap_bridge::start {{new_host "127.0.0.1"} {new_port 49501} {new_token ""}} {
    variable host
    variable port
    variable token
    variable server_sock

    if {$server_sock ne ""} {
        catch {close $server_sock}
        set server_sock ""
    }

    set host $new_host
    set port $new_port

    if {$new_token ne ""} {
        set token $new_token
    } elseif {[info exists ::env(COCO_SYSCAP_BRIDGE_TOKEN)]} {
        set token $::env(COCO_SYSCAP_BRIDGE_TOKEN)
    } else {
        set token ""
    }

    catch {::coco_syscap_bridge::_load_impl}

    if {$port == 0} {
        set server_sock [socket -server ::coco_syscap_bridge::_on_accept \
                             -myaddr $host 0]
        set port [lindex [fconfigure $server_sock -sockname] 2]
    } else {
        set server_sock [socket -server ::coco_syscap_bridge::_on_accept \
                             -myaddr $host $port]
    }

    return "coco_syscap_bridge ready on ${host}:${port}"
}

# ---------------------------------------------------------------------------
# run -- vwait-based event loop. Blocks the Tcl console until stop is called.
#        Uses a global tick variable so vwait works correctly in all embedded
#        Tcl environments (namespace variables are not reliable with vwait).
# ---------------------------------------------------------------------------
proc ::coco_syscap_bridge::run {} {
    variable running

    if {$running} {
        return "coco_syscap_bridge already running"
    }

    set running 1
    while {$running} {
        after 200 [list set ::_coco_syscap_bridge_tick 1]
        if {[catch {vwait ::_coco_syscap_bridge_tick}]} {
            # vwait not supported in this context; reset and return
            set running 0
            break
        }
        catch {unset ::_coco_syscap_bridge_tick}
    }
    set running 0
    return "coco_syscap_bridge stopped"
}

# ---------------------------------------------------------------------------
# stop -- exit the vwait loop and close the server socket.
# ---------------------------------------------------------------------------
proc ::coco_syscap_bridge::stop {} {
    variable running
    variable server_sock

    set running 0
    catch {set ::_coco_syscap_bridge_tick 1}
    if {$server_sock ne ""} {
        catch {close $server_sock}
        set server_sock ""
    }
    return "coco_syscap_bridge stopped"
}

# ---------------------------------------------------------------------------
# Auto-start: start opens the socket immediately.
# run is deferred via [after idle] so it enters vwait only after the host
# event loop is active.
# Set env COCO_SYSCAP_BRIDGE_DISABLE_AUTO_START=1 to suppress.
# ---------------------------------------------------------------------------
if {![info exists ::env(COCO_SYSCAP_BRIDGE_DISABLE_AUTO_START)]} {
    catch {::coco_syscap_bridge::start}
}

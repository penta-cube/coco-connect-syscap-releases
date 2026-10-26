# >>> CubicAI System Capture Bridge >>>
#
# Place this file in the System Capture startup/autoload Tcl directory.
# It locates `coco_syscap_bootstrap.tcl`, sources it, and starts the bridge.
#
# start is called immediately at autoload time (socket binding).
# run is called automatically via appEntryPost hook after System Capture
# completes its startup sequence. run blocks the Tcl console (vwait-based)
# but keeps the bridge responsive. The Qt UI is unaffected.
#
# To stop the bridge:
#   ::coco_syscap_bridge::stop

set _coco_syscap_bridge_candidates {}
set _coco_syscap_bridge_host "127.0.0.1"
set _coco_syscap_bridge_port 49501

# System Capture sources autoload files from inside a proc, so environment
# variables must be read through the global ::env array.
if {[info exists ::env(COCO_SYSCAP_BRIDGE_DIR)] && $::env(COCO_SYSCAP_BRIDGE_DIR) ne ""} {
  lappend _coco_syscap_bridge_candidates $::env(COCO_SYSCAP_BRIDGE_DIR)
}

lappend _coco_syscap_bridge_candidates {C:/Program Files/CubicAI/coco-connect-syscap/tcl}
lappend _coco_syscap_bridge_candidates {C:/Program Files/CubicAI/resources/coco-connect-syscap/tcl}

if {[info exists ::env(COCO_SYSCAP_BRIDGE_HOST)] && $::env(COCO_SYSCAP_BRIDGE_HOST) ne ""} {
  set _coco_syscap_bridge_host $::env(COCO_SYSCAP_BRIDGE_HOST)
}

if {[info exists ::env(COCO_SYSCAP_BRIDGE_PORT)] && $::env(COCO_SYSCAP_BRIDGE_PORT) ne ""} {
  set _coco_syscap_bridge_port $::env(COCO_SYSCAP_BRIDGE_PORT)
}

set _coco_syscap_bridge_loaded 0
foreach _coco_syscap_bridge_dir $_coco_syscap_bridge_candidates {
  set _coco_syscap_bootstrap [file join $_coco_syscap_bridge_dir coco_syscap_bootstrap.tcl]
  if {![file exists $_coco_syscap_bootstrap]} {
    set _coco_syscap_bootstrap [file join $_coco_syscap_bridge_dir syscap_bootstrap.tcl]
  }
  if {[file exists $_coco_syscap_bootstrap]} {
    # Suppress auto-start inside bootstrap (run would block startup).
    set ::env(COCO_SYSCAP_BRIDGE_DISABLE_AUTO_START) 1
    if {[catch {source $_coco_syscap_bootstrap} _coco_syscap_err]} {
      puts "CubicAI System Capture Bridge autoload failed: $_coco_syscap_err"
    } else {
      # Retry proc: if start fails, retries every 3 s inside the vwait loop.
      proc ::coco_syscap_bridge::_retry_start {} {
        if {$::coco_syscap_bridge::server_sock ne ""} return
        if {[catch {::coco_syscap_bridge::start \
            $::coco_syscap_bridge::host $::coco_syscap_bridge::port}]} {
          after 3000 ::coco_syscap_bridge::_retry_start
        }
      }
      catch {::coco_syscap_bridge::start $_coco_syscap_bridge_host $_coco_syscap_bridge_port}

      # Hook appEntryPost to call run automatically after System Capture startup.
      # Guard: skip if appEntryPost is absent or already hooked.
      if {[llength [info procs ::appEntryPost]] > 0
          && [llength [info procs ::__coco_syscap_orig_appEntryPost]] == 0} {
        rename ::appEntryPost ::__coco_syscap_orig_appEntryPost
        proc ::appEntryPost {} {
          set code [catch {::__coco_syscap_orig_appEntryPost} result opts]
          if {$code != 0} {
            return -options $opts $result
          }
          catch {::coco_syscap_bridge::_retry_start}
          catch {::coco_syscap_bridge::run}
          return $result
        }
      }

      set _coco_syscap_bridge_loaded 1
      break
    }
  }
}

unset -nocomplain ::env(COCO_SYSCAP_BRIDGE_DISABLE_AUTO_START)

if {!$_coco_syscap_bridge_loaded} {
  puts "CubicAI System Capture Bridge autoload skipped: coco_syscap_bootstrap.tcl not found"
}

unset _coco_syscap_bridge_loaded
unset _coco_syscap_bridge_host
unset _coco_syscap_bridge_port
catch {unset _coco_syscap_bootstrap}
catch {unset _coco_syscap_bridge_dir}
unset _coco_syscap_bridge_candidates
# <<< CubicAI System Capture Bridge <<<

# Deprecated compatibility shim.
# Prefer sourcing coco_syscap_bootstrap.tcl directly.

set _coco_syscap_bootstrap_dir [file normalize [file dirname [info script]]]
set _coco_syscap_bootstrap_file [file join $_coco_syscap_bootstrap_dir coco_syscap_bootstrap.tcl]

if {[file exists $_coco_syscap_bootstrap_file]} {
    source $_coco_syscap_bootstrap_file
} else {
    error "coco_syscap_bootstrap.tcl not found next to syscap_bootstrap.tcl"
}

unset _coco_syscap_bootstrap_dir
unset _coco_syscap_bootstrap_file

# Packaged System Capture bridge entry point.
apply {{runtime} {
    set dll [file join $runtime tbcload.dll]
    if {[catch {load $dll Tbcload} detail options]} {
        return -options $options "Cannot load System Capture runtime tbcload.dll: $detail"
    }
    if {[catch {uplevel #0 [list source -encoding utf-8 [file join $runtime bridge.tbc]]} detail options]} {
        return -options $options "Cannot load System Capture runtime bridge.tbc: $detail"
    }
}} [file normalize [file dirname [info script]]]

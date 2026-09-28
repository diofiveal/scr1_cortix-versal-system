set root [file normalize [file join [file dirname [info script]] ../..]]
set bad 0
foreach path [concat [glob -nocomplain $root/scripts/vivado/*.tcl] [glob -nocomplain $root/constraints/*.xdc]] {
    set f [open $path r]; set text [read $f]; close $f
    if {![info complete $text]} {puts "FAIL $path";set bad 1} else {puts "PASS syntax-complete $path"}
}
exit $bad

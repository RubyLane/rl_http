package require tcltest
# Test files were originally written to be sourceable on their own and
# guard with `if {"::tcltest" ni [namespace children]} { ... namespace import ... }`.
# When sourced from this driver tcltest IS already loaded, so the
# guard skips the import — leaving `test` undefined inside the .test
# scripts. Import here so all.tcl-driven runs match the standalone case.
namespace import ::tcltest::*

::tcltest::configure -singleproc 1 {*}$argv -testdir [file dirname [info script]]

set failed [::tcltest::runAllTests]

::tcltest::cleanupTests 0

if {$failed} {
    puts $::tcltest::outputChannel "[file tail [info script]]: $failed test(s) failed"
    close stderr
    error "test run failed"
}

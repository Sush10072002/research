# scc.tcl — Tarjan SCC in plain Tcl
proc tarjan_scc {graph} {
    # graph: dict src -> list of dsts
    set index 0
    array unset idx; array unset low; array unset onstack
    set S {}
    set sccs {}

    proc strongconnect {v} {
        upvar 1 graph graph idx idx low low onstack onstack S S index index sccs sccs
        set idx($v) $index
        set low($v) $index
        incr index
        lappend S $v
        set onstack($v) 1

        set nbrs [dict get $graph $v]
        foreach w $nbrs {
            if {![info exists idx($w)]} {
                strongconnect $w
                set low($v) [min $low($v) $low($w)]
            } elseif {$onstack($w)} {
                set low($v) [min $low($v) $idx($w)]
            }
        }

        if {$low($v) == $idx($v)} {
            set comp {}
            while 1 {
                set w [lindex $S end]
                set S [lreplace $S end end]
                set onstack($w) 0
                lappend comp $w
                if {$w eq $v} break
            }
            lappend sccs $comp
        }
    }

    foreach v [dict keys $graph] {
        if {![info exists idx($v)]} { strongconnect $v }
    }
    return $sccs
}

proc min {a b} { expr {$a < $b ? $a : $b} }

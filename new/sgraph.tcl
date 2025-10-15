# ========= CONFIG =========
# Top-level names (adjust to match your TB / DUT)
set TOP         "tb_top"
# Clock domain(s): list of {clock_path, period_ns}
# add more domains as needed
set CLOCKS {
    {tb_top.clk 10.0}
}
# Reset signal (active-high/low selectable)
set RESET_PATH "tb_top.rst_n"
set RESET_ACTIVE 0          ;# 1 => active-high, 0 => active-low

# How many cycles of your normal stimuli to run before sampling
set WARMUP_CYCLES 50

# How many cycles to run to “settle” after reset and after each perturbation
set SETTLE_CYCLES 2

# Output files
set EDGES_CSV       "edges.csv"
set STATE_REGS_TXT  "state_regs.txt"
set SCC_TXT         "scc.txt"
# ==========================

# Load SCC helper
source scc.tcl

# Utility: rising-edge wait
proc wait_rise {clk_path} {
    # Advance to next rising edge of clk (Verilog 0/1/X/Z)
    # We sample on 0->1 transition by stepping half period if needed.
    # For robustness, just run small steps until we detect posedge.
    set prev [examine -radix binary $clk_path]
    while 1 {
        run 0.1 ns
        set now [examine -radix binary $clk_path]
        if {$prev ne "1" && $now eq "1"} { return }
        set prev $now
    }
}

# Utility: set or release reset
proc apply_reset {path active} {
    if {$active} {
        force -deposit $path 1
    } else {
        force -deposit $path 0
    }
}
proc release_reset {path active} {
    if {$active} {
        force -deposit $path 0
    } else {
        force -deposit $path 1
    }
}

# Enumerate candidate "state regs" under TOP by heuristic:
# Any reg/variable that changes ONLY on posedge of a known clock during warmup.
# (We detect change exactly at posedge; this avoids requiring source parsing.)
proc discover_state_regs {clk_path warm_cycles} {
    global TOP
    # Snapshot names of all variables/signals in hierarchy
    # We filter later to those that toggle at clock edges.
    set all [lsort -unique [find signals -r ${TOP}/*]]
    

    # Track which signals change at posedges
    array set toggles {}

    # Prime: get stable baseline
    for {set i 0} {$i < $warm_cycles} {incr i} {
        # grab values before edge
        array unset pre
        foreach s $all { catch { set pre($s) [examine $s] } }
        # wait posedge
        wait_rise $clk_path
        # after posedge, see which changed exactly at the edge window
        foreach s $all {
            if {[catch { set post [examine $s] }]} { continue }
            if { [info exists pre($s)] && $pre($s) ne $post } {
                set toggles($s) 1
            }
        }
        # let comb settle a bit between cycles
        run 0.1 ns
    }

    # Filter to scalars/vectors that toggled at posedges (likely state regs)
    set regs {}
    foreach s [array names toggles] {
        # Skip pure wires that change between edges (heuristic already filtered)
        # Also skip clocks & reset themselves
        if {$s eq $clk_path} continue
        if {$s eq $::RESET_PATH} continue
        lappend regs $s
    }
    return [lsort -unique $regs]
}

# Capture the "state vector" of a reg list
proc snap_state {reglist} {
    set snap {}
    foreach r $reglist {
        if {[catch { set v [examine $r] }]} { continue }
        dict set snap $r $v
    }
    return $snap
}

# Compare two state snapshots; return list of regs with changed values
proc diff_state {snapA snapB} {
    set changed {}
    foreach r [lsort -unique [concat [dict keys $snapA] [dict keys $snapB]]] {
        set a [dict get $snapA $r]
        set b [dict get $snapB $r]
        if {$a ne $b} { lappend changed $r }
    }
    return $changed
}

# Reset & warmup to a stable point for a specific clock domain
proc reset_and_warm {clk_path period warm settle} {
    # Reset assert for 2 cycles
    apply_reset $::RESET_PATH $::RESET_ACTIVE
    for {set i 0} {$i < 2} {incr i} { wait_rise $clk_path }
    # Deassert and settle
    release_reset $::RESET_PATH $::RESET_ACTIVE
    for {set i 0} {$i < $settle} {incr i} { wait_rise $clk_path }
    # Run warmup cycles of user stimuli
    for {set i 0} {$i < $warm} {incr i} { wait_rise $clk_path }
}

# Forcing helper: invert current value (binary/hex/dec tolerant for 1-bit; for vectors we flip LSB)
proc invert_scalar {val} {
    # Try binary first
    if {[string is digit -strict $val]} {
        return [expr {$val?0:1}]
    }
    set low [string tolower $val]
    if {$low in {"0" "1"}} {
        return [expr {$low eq "1" ? 0 : 1}]
    }
    # vector: toggle LSB bit (quick heuristic)
    # attempt to read as integer
    if {[catch { set num [expr {$val+0}] }]} {
        return $val
    }
    return [expr {$num ^ 1}]
}

# MAIN
quietly restart -force
# Ensure time unit is ns for simplicity
radix hex

# Open outputs
set f_edges [open $::EDGES_CSV w]
puts $f_edges "src,dst,clock"

set f_regs  [open $::STATE_REGS_TXT w]

# Build a big edge dict-of-dicts per clock
array set graph_by_clk {}

# Process each clock domain independently
foreach dom $::CLOCKS {
    lassign $dom clk_path period

    # Fresh sim from time 0 for each domain (repeatable stimuli)
    quietly restart -force
    # Bring-up
    reset_and_warm $clk_path $period $::WARMUP_CYCLES $::SETTLE_CYCLES

    # Discover state regs in this domain
    set regs [discover_state_regs $clk_path 5]
    puts "Clock: $clk_path  — discovered [llength $regs] state regs"
    puts $f_regs "clock $clk_path"
    foreach r $regs { puts $f_regs $r }
    puts $f_regs ""

    # Baseline next-state snapshot:
    # Take snapshot just BEFORE an edge, then step to AFTER edge and capture
    # (we snapshot the post-edge values as the “state at t+1”)
    # Recreate the same point from clean reset/warmup for consistency
    quietly restart -force
    reset_and_warm $clk_path $period $::WARMUP_CYCLES $::SETTLE_CYCLES
    wait_rise $clk_path
    set baseline [snap_state $regs]

    # For each reg: perturb its value just before the clock edge, then re-run to same edge and compare
    array unset edge_map
    array set edge_map {}
    foreach s $regs { set edge_map($s) {} }
    set n [llength $regs]
    set k 0
    foreach src $regs {
        incr k
        # Fresh run to same baseline point
        quietly restart -force
        reset_and_warm $clk_path $period $::WARMUP_CYCLES $::SETTLE_CYCLES

        # Make a tiny step before edge to allow a force on the pre-edge combinational values
        # (We will force the reg variable itself; at RTL this models changing its “previous Q” feeding the next D)
        # In RTL, the reg updates on posedge; forcing it pre-edge perturbs the RHS usage feeding others.
        # Wait almost up to posedge, then force.
        # Simple approach: advance small delta, force, then wait for posedge.
        run 0.1 ns
        set cur [examine $src]
        set inv [invert_scalar $cur]
        catch { force -deposit $src $inv }

        # Cross the posedge
        wait_rise $clk_path
        # Snapshot new post-edge state
        set newsnap [snap_state $regs]
        # Compare to baseline; any changed reg is a dst
        set changed [diff_state $baseline $newsnap]
        foreach dst $changed {
            # Ignore self change — self-dependence is implicit; we still record it (optional)
            # if {$dst eq $src} continue
            lappend edge_map($src) $dst
            puts $f_edges "$src,$dst,$clk_path"
        }
        # Release the force for cleanliness
        catch { noforce $src }
        # Small settle between iterations
        run 0.1 ns

        if {($k % 50) == 0} { puts "  [$clk_path] processed $k / $n regs..." }
    }

    # Save graph for SCCs
    set graph {}
    foreach s $regs {
        set dsts [lsort -unique [expr {[info exists edge_map($s)] ? $edge_map($s) : {}}]]
        dict set graph $s $dsts
    }
    set graph_by_clk($clk_path) $graph
}

close $f_edges
close $f_regs

# Compute SCCs per clock domain and write out
set f_scc [open $::SCC_TXT w]
foreach dom $::CLOCKS {
    lassign $dom clk_path period
    set graph $graph_by_clk($clk_path)
    set sccs [tarjan_scc $graph]
    puts $f_scc "clock $clk_path"
    foreach comp $sccs {
        # Only keep SCCs of size >= 1 (all are), highlight feedbacks (size > 1)
        set mark [expr {[llength $comp] > 1 ? "*" : " "} ]
        puts $f_scc "$mark [join [lsort $comp] {, }]"
    }
    puts $f_scc ""
}
close $f_scc

puts "Done. Wrote: $::EDGES_CSV, $::STATE_REGS_TXT, $::SCC_TXT"

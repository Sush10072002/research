transcript on
vlib work
vmap work work

# Adjust file list and include dirs as needed
# Add any folder that has your .vh/.inc (e.g., ./rtl/include)
vlog +acc +define+SIM \
    +incdir+./rtl +incdir+./rtl/include ./rtl/*.v \
    ./tb/*.v

vsim -c -voptargs="+acc" work.tb_top -do "do sgraph.tcl; quit -f"

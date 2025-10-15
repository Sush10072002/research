
`timescale 1ns/1ps

module tb_top;
    reg clk=0, rst_n=0;
    wire [15:0] pc, alu_y;
    wire        reg_we;
    wire [2:0]  reg_wa;
    wire [15:0] reg_wd;

    simple16_cpu DUT(
        .clk(clk), .rst_n(rst_n),
        .obs_pc(pc), .obs_alu_y(alu_y),
        .obs_reg_we(reg_we), .obs_reg_waddr(reg_wa), .obs_reg_wdata(reg_wd)
    );

    // 100 MHz clk (10 ns period)
    always #5 clk = ~clk;

    integer t;
    initial begin
        $display("Starting Simple16...");
        $dumpfile("simple16.vcd");
        $dumpvars(0, tb_simple16);

        rst_n = 0; repeat (3) @(posedge clk);
        rst_n = 1;

        // Run enough cycles to reach 'done'
        for (t=0; t<200; t=t+1) begin
            @(posedge clk);
            if (t%10==0)
                $display("t=%0d  PC=%0d  ALU=0x%04h  reg_we=%0d w[%0d]=0x%04h",
                         t, pc, alu_y, reg_we, reg_wa, reg_wd);
        end

        $display("Done.");
        $finish;
    end
endmodule

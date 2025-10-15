// ============================================================================
// Simple16 — a tiny single-cycle 16-bit RISC-like CPU (pure Verilog-2001)
// ----------------------------------------------------------------------------
// ISA (16-bit):
//   R-type (add,sub,and,or,xor):  [15:12]=op, [11:9]=rd, [8:6]=rs, [5:3]=rt, [2:0]=000
//   I-type (addi,lw,sw,lui):      [15:12]=op, [11:9]=rd/rt, [8:6]=rs(base), [5:0]=imm6 (signed)
//   B-type (beq,bne):             [15:12]=op, [11:9]=rs, [8:6]=rt, [5:0]=off6 (signed, rel PC+1)
//   J-type (j):                   [15:12]=0x9, [11:0]=abs12
// Opcodes:
//   0: ADD   1: SUB   2: AND   3: OR    4: XOR
//   5: ADDI  6: LW    7: SW    8: BEQ   9: J
//   A: BNE   B: LUI   (others: NOP)
//
// Notes:
//   - 8 registers (r0..r7), r0=0 (writes ignored).
//   - Word-addressed memories (16-bit). PC counts words.
//   - Separate IMEM (ROM) and DMEM (RAM).
//   - “Research hooks”: obs_* signals for your RTL testability work.
// ============================================================================

`timescale 1ns/1ps

// ------------------------------ ALU -----------------------------------------
module simple16_alu(
    input  [3:0]  op,
    input  [15:0] a, b,
    output reg [15:0] y,
    output        z
);
    always @* begin
        case (op)
            4'h0: y = a + b;    // ADD
            4'h1: y = a - b;    // SUB
            4'h2: y = a & b;    // AND
            4'h3: y = a | b;    // OR
            4'h4: y = a ^ b;    // XOR
            default: y = 16'h0000;
        endcase
    end
    assign z = (y == 16'h0000);
endmodule

// --------------------------- Register File ----------------------------------
module simple16_regfile(
    input         clk,
    input         we,
    input  [2:0]  raddr1, raddr2,
    input  [2:0]  waddr,
    input  [15:0] wdata,
    output [15:0] rdata1, rdata2
);
    reg [15:0] regs[7:0];
    integer i;
    initial begin
        for (i=0;i<8;i=i+1) regs[i]=16'h0000;
    end

    assign rdata1 = (raddr1==3'd0) ? 16'h0000 : regs[raddr1];
    assign rdata2 = (raddr2==3'd0) ? 16'h0000 : regs[raddr2];

    always @(posedge clk) begin
        if (we && waddr!=3'd0)
            regs[waddr] <= wdata;
    end
endmodule

// ---------------------------- Instruction ROM -------------------------------
module simple16_imem(
    input  [15:0] addr,     // word address (PC)
    output [15:0] instr
);
    reg [15:0] rom [0:255];
    integer k;
    initial begin
        for (k=0;k<256;k=k+1) rom[k]=16'h0000;

        // Demo program:
        // r1 = 0x0010
        rom[16'd0] = {4'hB, 3'd1, 3'd0, 6'd0};    // LUI  r1,0
        rom[16'd1] = {4'h5, 3'd1, 3'd1, 6'd16};   // ADDI r1,r1,16
        // r2 = 5
        rom[16'd2] = {4'h5, 3'd2, 3'd0, 6'd5};    // ADDI r2,r0,5
        // loop: tmp=r3=MEM[r1]; r3+=r2; MEM[r1]=r3; if r3!=50 goto loop; j done
        rom[16'd3] = {4'h6, 3'd3, 3'd1, 6'sd0};   // LW   r3,[r1+0]
        rom[16'd4] = {4'h0, 3'd3, 3'd3, 3'd2, 3'b000}; // ADD r3=r3+r2
        rom[16'd5] = {4'h7, 3'd3, 3'd1, 6'sd0};   // SW   r3,[r1+0]  (store rt=r3)
        rom[16'd6] = {4'h5, 3'd4, 3'd0, 6'd50};   // ADDI r4,r0,50
        rom[16'd7] = {4'h1, 3'd5, 3'd3, 3'd4, 3'b000}; // SUB r5=r3-r4
        rom[16'd8] = {4'hA, 3'd5, 3'd0, 6'sd6};     // BNE r5,r0,back to 3
        rom[16'd9] = {4'h9, 12'd12};               // J   done
        rom[16'd10]= 16'h0000;
        rom[16'd11]= 16'h0000;
        rom[16'd12]= 16'h0000; // done: NOP
    end

    assign instr = rom[addr[7:0]]; // 256 words
endmodule

// ----------------------------- Data RAM -------------------------------------
module simple16_dmem(
    input         clk,
    input         we,
    input  [15:0] addr,     // word address
    input  [15:0] wdata,
    output [15:0] rdata
);
    reg [15:0] ram [0:255];
    integer i;
    initial begin
        for (i=0;i<256;i=i+1) ram[i]=16'h0000;
        ram[16'h0010] = 16'h0000; // demo target address
    end

    assign rdata = ram[addr[7:0]]; // async read (simple)
    always @(posedge clk) if (we) ram[addr[7:0]] <= wdata;
endmodule

// ------------------------------- CPU ----------------------------------------
module simple16_cpu(
    input         clk,
    input         rst_n,
    // observation hooks (for RTL testability)
    output [15:0] obs_pc,
    output [15:0] obs_alu_y,
    output        obs_reg_we,
    output [2:0]  obs_reg_waddr,
    output [15:0] obs_reg_wdata
);
    reg  [15:0] pc;
    wire [15:0] instr;
    wire [3:0]  op  = instr[15:12];
    wire [2:0]  rd  = instr[11:9];
    wire [2:0]  rs  = instr[8:6];
    wire [2:0]  rt  = instr[5:3];
    wire [5:0]  imm6 = instr[5:0];
    wire signed [15:0] simm6 = {{10{imm6[5]}}, imm6};

    // Register file
    wire [15:0] rs_val, rt_val;
    reg         reg_we;
    reg  [2:0]  reg_waddr;
    reg  [15:0] reg_wdata;

    simple16_regfile RF(
        .clk(clk),
        .we(reg_we),
        .raddr1(rs),
        .raddr2(rt),
        .waddr(reg_waddr),
        .wdata(reg_wdata),
        .rdata1(rs_val),
        .rdata2(rt_val)
    );

    // ALU
    wire [15:0] alu_b_mux = (op==4'h5) ? simm6 : rt_val; // ADDI uses imm
    wire [15:0] alu_y;
    wire        alu_z;

    simple16_alu ALU(.op(op), .a(rs_val), .b(alu_b_mux), .y(alu_y), .z(alu_z));

    // Memories
    wire [15:0] dmem_rdata;
    reg         dmem_we;
    reg  [15:0] dmem_addr;
    reg  [15:0] dmem_wdata;

    simple16_imem IMEM(.addr(pc), .instr(instr));
    simple16_dmem DMEM(.clk(clk), .we(dmem_we), .addr(dmem_addr), .wdata(dmem_wdata), .rdata(dmem_rdata));

    // Next PC default
    reg [15:0] pc_next;

    // Control / Writeback
    always @* begin
        reg_we     = 1'b0;
        reg_waddr  = 3'd0;
        reg_wdata  = 16'h0000;
        dmem_we    = 1'b0;
        dmem_addr  = 16'h0000;
        dmem_wdata = 16'h0000;
        pc_next    = pc + 16'd1;

        case (op)
            // R-type: rd = rs OP rt
            4'h0,4'h1,4'h2,4'h3,4'h4: begin
                reg_we    = 1'b1;
                reg_waddr = rd;
                reg_wdata = alu_y;
            end
            // ADDI rd = rs + simm6
            4'h5: begin
                reg_we    = 1'b1;
                reg_waddr = rd;
                reg_wdata = alu_y;
            end
            // LW rd = MEM[rs + simm6]
            4'h6: begin
                reg_we    = 1'b1;
                reg_waddr = rd;
                dmem_addr = rs_val + simm6;
                reg_wdata = dmem_rdata;
            end
            // SW MEM[rs + simm6] = rt
            4'h7: begin
                dmem_we    = 1'b1;
                dmem_addr  = rs_val + simm6;
                dmem_wdata = rt_val; // store data = rt
            end
            // BEQ if (rs==rt) pc += off6
            4'h8: begin
                if (rs_val == rt_val) pc_next = pc + simm6;
            end
            // J abs12
            4'h9: begin
                pc_next = {4'b0000, instr[11:0]};
            end
            // BNE if (rs!=rt) pc += off6
            4'hA: begin
                if (rs_val != rt_val) pc_next = pc + simm6;
            end
            // LUI rd = (imm6 << 10)
            4'hB: begin
                reg_we    = 1'b1;
                reg_waddr = rd;
                reg_wdata = {imm6, 10'b0};
            end
            default: begin
                // NOP
            end
        endcase
    end

    // State update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc <= 16'h0000;
        else        pc <= pc_next;
    end

    // Observation hooks
    assign obs_pc        = pc;
    assign obs_alu_y     = alu_y;
    assign obs_reg_we    = reg_we;
    assign obs_reg_waddr = reg_waddr;
    assign obs_reg_wdata = reg_wdata;

endmodule

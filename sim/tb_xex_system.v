`timescale 1ns / 1ps
`default_nettype none
module tb_xex_system;
reg clk_host=0, clk=0, reset=1;
always #20   clk_host = ~clk_host;   // 25 MHz
always #17.5 clk      = ~clk;        // 28.57 MHz

reg [63:0] img_size = 64'd1164;
reg [7:0]  img_mounted = 8'd0;
wire [7:0] sdc_rd;
wire [31:0] sdc_sector;
reg        sdc_busy=0, sdc_done=0, sdc_error=0;
reg  [2:0] sdc_slot=3'd0;
reg        sdc_byte_strobe=0;
reg  [8:0] sdc_byte_addr=0;
reg  [7:0] sdc_byte_in_data=0;
wire       atr_ld_req;
wire [24:0] atr_ld_addr;
wire [7:0] atr_ld_data;
wire       ld_loading, atr_ready, xex_mode;
wire [15:0] atr_ssize;
wire [31:0] atr_scount;

wire       xex_busy, xex_done, xex_rd_req, xex_ld_req;
wire [24:0] xex_rd_addr, xex_ld_addr;
wire [7:0] xex_ld_data;
wire [15:0] xex_boot_ssize;
wire [31:0] xex_boot_scount;
wire [4:0] xex_state;
wire xex_start, xex_reset;

reg  [7:0] mem [0:4194303];
reg  [7:0] file [0:4095];
reg  [7:0] dsk_data = 0;
reg        dsk_ack = 0;
wire       dsk_req = xex_busy ? xex_rd_req : 1'b0;
wire [24:0] dsk_addr = xex_busy ? xex_rd_addr : 25'd0;
wire       ld_req = xex_busy ? xex_ld_req : atr_ld_req;
wire [24:0] ld_addr = xex_busy ? xex_ld_addr : atr_ld_addr;
wire [7:0]  ld_data = xex_busy ? xex_ld_data : atr_ld_data;

always @(posedge clk) begin
 dsk_ack <= 1'b0;
 if (dsk_req) begin dsk_data <= mem[dsk_addr]; dsk_ack <= 1'b1; end
end
always @(posedge clk) if (ld_req) mem[ld_addr] <= ld_data;

atari_atr_loader atr_loader(
 .clk_host(clk_host), .clk(clk), .reset_host(reset),
 .img_mounted(img_mounted), .img_size(img_size),
 .sdc_rd(sdc_rd), .sdc_sector(sdc_sector), .sdc_busy(sdc_busy),
 .sdc_done(sdc_done), .sdc_error(sdc_error), .sdc_slot(sdc_slot),
 .sdc_byte_strobe(sdc_byte_strobe), .sdc_byte_addr(sdc_byte_addr),
 .sdc_byte_in_data(sdc_byte_in_data),
 .ld_req(atr_ld_req), .ld_addr(atr_ld_addr), .ld_data(atr_ld_data),
 .atr_ssize(atr_ssize), .atr_scount(atr_scount), .atr_ready(atr_ready),
 .loading(ld_loading), .xex_mode(xex_mode),
 .dbg_nsec(), .dbg_waddr()
);

assign xex_reset = reset | (img_size[31:0]==32'd0) | (!atr_ready && !xex_busy);
assign xex_start = atr_ready && xex_mode && !xex_done && !xex_busy;
xex_dma_loader xex(
 .clk(clk), .reset(xex_reset), .start(xex_start), .size(img_size[31:0]),
 .busy(xex_busy), .done(xex_done),
 .rd_req(xex_rd_req), .rd_addr(xex_rd_addr), .rd_data(dsk_data), .rd_ack(dsk_ack),
 .ld_req(xex_ld_req), .ld_addr(xex_ld_addr), .ld_data(xex_ld_data),
 .boot_ssize(xex_boot_ssize), .boot_scount(xex_boot_scount),
 .state_dbg(xex_state)
);

// image-service model: 512-byte sectors of the raw XEX at the start of a file
reg [1:0] ms=0; integer mi=0; reg [31:0] msec=0; reg rd_d=0;
reg [5:0] div=0; // simulate slow SIO: one byte per 20 host clocks
always @(posedge clk_host) begin
 sdc_byte_strobe <= 0;
 sdc_done <= 0;
 rd_d <= sdc_rd[0];
 case(ms)
  0: if (sdc_rd[0] && !rd_d) begin
       msec <= sdc_sector; mi <= 0; sdc_busy <= 1; div <= 5'd19; ms <= 1;
     end
  1: begin
       sdc_busy <= 1;
       if (div == 0) begin
         sdc_byte_strobe <= 1;
         sdc_byte_addr <= mi[8:0];
         sdc_byte_in_data <= file[msec*512 + mi];
         div <= 6'd19;
         if (mi == 511) ms <= 2;
         else mi <= mi + 1;
       end
       else
         div <= div - 1;
     end
  2: begin
       sdc_busy <= 0; sdc_done <= 1; ms <= 0;
     end
 endcase
end

integer i, errors=0; integer cyc=0;
always @(posedge clk_host) begin cyc=cyc+1; if (cyc%5000==0) $display("t=%0t ready=%b load=%b mode=%b rd=%b busy=%b done=%b ms=%0d mi=%0d sec=%0d", $time, atr_ready, ld_loading, xex_mode, sdc_rd[0], sdc_busy, sdc_done, ms, mi, sdc_sector); end
initial begin
 for (i=0;i<4194304;i=i+1) mem[i]=0;
 for (i=0;i<4096;i=i+1) file[i]=0;
 $readmemh("pong.hex", file, 0, 1163);
 #100 reset=0; #100 img_mounted=1; #200 img_mounted=0;
 wait(atr_ready); $display("atr_ready reached at %0t",$time); wait(xex_done);
 #200;
 $display("atr_ready=%b xex_mode=%b busy=%b done=%b state=%0d ssize=%0d scount=%0d",
          atr_ready, xex_mode, xex_busy, xex_done, xex_state, xex_boot_ssize, xex_boot_scount);
 if (!atr_ready || !xex_mode || !xex_done || xex_busy) begin $display("ERROR handshake"); errors=errors+1; end
 if (xex_boot_ssize !== 16'd128 || xex_boot_scount !== 32'd3) begin $display("ERROR boot geometry"); errors=errors+1; end
 if (mem[25'h300000] !== 8'h96 || mem[25'h300001] !== 8'h02 || mem[25'h300002] !== 8'h18) begin
  $display("ERROR stub header %h %h %h", mem[25'h300000],mem[25'h300001],mem[25'h300002]); errors=errors+1; end
 if (mem[25'h300010] !== 8'h00 || mem[25'h300011] !== 8'h03 || mem[25'h300015] !== 8'h07) begin
  $display("ERROR boot header"); errors=errors+1; end
 if (mem[16'h4000] !== 8'hA9 || mem[16'h4001] !== 8'h01 || mem[16'h4002] !== 8'h85) begin
  $display("ERROR 4000 %h %h %h", mem[16'h4000],mem[16'h4001],mem[16'h4002]); errors=errors+1; end
 if (mem[16'h02E0] !== 8'h00 || mem[16'h02E1] !== 8'h40) begin
  $display("ERROR RUNAD %h %h", mem[16'h02E0],mem[16'h02E1]); errors=errors+1; end
 if (errors==0) $display("tb_xex_system: PASS"); else $display("tb_xex_system: %0d errors",errors);
 $finish;
end
initial begin #5000000; $display("TIMEOUT ready=%b mode=%b busy=%b done=%b state=%0d",atr_ready,xex_mode,xex_busy,xex_done,xex_state); $finish; end
endmodule
`default_nettype wire

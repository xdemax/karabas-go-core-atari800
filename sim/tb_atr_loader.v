`timescale 1ns / 1ps
/*-------------------------------------------------------------------------------------------------------------------
--
-- tb_atr_loader.v - ATR image loader (atari_atr_loader + kg_async_fifo).
--
-- Models the kg_l2_img sector interface: on sdc_rd[1] it streams 512 bytes of a
-- fake 90K ATR (181 sectors), then pulses sdc_done.  The SRAM loader port is a
-- byte array.  Checks the copied header, ssize/scount and the write count.
--
-------------------------------------------------------------------------------------------------------------------*/
module tb_atr_loader;

reg clk_host = 1'b0, clk = 1'b0;
always #20   clk_host = ~clk_host;       // 25 MHz
always #17.5 clk      = ~clk;            // 28.571 MHz

reg reset_host = 1'b1;
reg [7:0]  img_mounted = 8'h02;          // slot 1 (the disk)
reg [63:0] img_size = 64'd92176;         // 90K ATR: 16 + 720*128

wire [7:0]  sdc_rd;
wire [31:0] sdc_sector;
reg         sdc_busy = 1'b0, sdc_done = 1'b0, sdc_error = 1'b0;
reg  [2:0]  sdc_slot = 3'd1;
reg         sdc_byte_strobe = 1'b0;
reg  [8:0]  sdc_byte_addr = 9'd0;
reg  [7:0]  sdc_byte_in_data = 8'd0;

wire        ld_req;
wire [24:0] ld_addr;
wire [7:0]  ld_data;

wire [15:0] atr_ssize;
wire [31:0] atr_scount;
wire        atr_ready;
wire        loading;

reg [7:0] mem [0:1048575];
integer wr_count = 0;

always @(posedge clk)
	if (ld_req) begin
		mem[ld_addr - 25'h300000] = ld_data;
		wr_count = wr_count + 1;
	end

reg rd_d = 1'b0;
always @(posedge clk_host)
	rd_d <= sdc_rd[1];

// fake ATR bytes: the header of a 128-byte, 720-sector disk, then a pattern
function [7:0] fdata(input [31:0] sec, input [9:0] idx);
	reg [31:0] v;
	begin
		if (sec == 32'd0 && idx < 10'd16) begin
			case (idx)
				10'd0: fdata = 8'h96;
				10'd1: fdata = 8'h02;
				10'd2: fdata = 8'h80;   // paragraphs 0x1680 = 5760
				10'd3: fdata = 8'h16;
				10'd4: fdata = 8'h80;   // sector size 128
				10'd5: fdata = 8'h00;
				default: fdata = 8'h00;
			endcase
		end
		else begin
			v = (sec << 9) + idx;
			fdata = v[7:0];
		end
	end
endfunction

localparam M_IDLE = 0, M_STREAM = 1, M_DONE = 2;
reg [1:0]  ms = M_IDLE;
reg [9:0]  mi = 10'd0;
reg [31:0] msec = 32'd0;

always @(posedge clk_host) begin
	sdc_byte_strobe <= 1'b0;
	sdc_done <= 1'b0;
	case (ms)
		M_IDLE: if (sdc_rd[1] && !rd_d) begin
			msec <= sdc_sector;
			mi <= 10'd0;
			sdc_busy <= 1'b1;
			ms <= M_STREAM;
		end
		M_STREAM: begin
			sdc_byte_strobe <= 1'b1;
			sdc_byte_addr <= mi;
			sdc_byte_in_data <= fdata(msec, mi);
			if (mi == 10'd511) ms <= M_DONE;
			else mi <= mi + 10'd1;
		end
		M_DONE: begin
			sdc_done <= 1'b1;
			sdc_busy <= 1'b0;
			ms <= M_IDLE;
		end
	endcase
end

atari_atr_loader dut (
	.clk_host       (clk_host),
	.clk            (clk),
	.reset_host     (reset_host),
	.img_mounted    (img_mounted),
	.img_size       (img_size),
	.sdc_rd         (sdc_rd),
	.sdc_sector     (sdc_sector),
	.sdc_busy       (sdc_busy),
	.sdc_done       (sdc_done),
	.sdc_error      (sdc_error),
	.sdc_slot       (sdc_slot),
	.sdc_byte_strobe(sdc_byte_strobe),
	.sdc_byte_addr  (sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data),
	.ld_req         (ld_req),
	.ld_addr        (ld_addr),
	.ld_data        (ld_data),
	.atr_ssize      (atr_ssize),
	.atr_scount     (atr_scount),
	.atr_ready      (atr_ready),
	.loading        (loading)
);

integer errors = 0;

initial begin
	#(20_000_000);                       // watchdog
	$display("TIMEOUT ready=%b loading=%b count=%0d", atr_ready, loading, wr_count);
	$finish;
end

initial begin
	#200 reset_host = 1'b0;
	wait (atr_ready === 1'b1);
	#1000;
	if (atr_ssize != 16'd128) begin
		$display("ERROR ssize=%0d", atr_ssize); errors = errors + 1;
	end
	if (atr_scount != 32'd720) begin
		$display("ERROR scount=%0d", atr_scount); errors = errors + 1;
	end
	if (mem[0] != 8'h96 || mem[1] != 8'h02) begin
		$display("ERROR header %h %h", mem[0], mem[1]); errors = errors + 1;
	end
	if (mem[16] != 8'd16) begin
		$display("ERROR mem16=%h", mem[16]); errors = errors + 1;
	end
	if (mem[512+16] != ((512+16) & 255)) begin
		$display("ERROR mem528=%h", mem[512+16]); errors = errors + 1;
	end
	if (wr_count != 181*512) begin
		$display("ERROR wr_count=%0d want %0d", wr_count, 181*512); errors = errors + 1;
	end
	if (errors == 0)
		$display("tb_loader: 0 errors, %0d bytes written", wr_count);
	else
		$display("tb_loader: %0d errors", errors);
	$finish;
end

endmodule

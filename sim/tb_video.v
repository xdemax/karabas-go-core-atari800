`timescale 1ns / 1ps
/*-------------------------------------------------------------------------------------------------------------------
--
-- tb_video.v - atari_video: a synthetic PAL Atari frame in, 720 x 576 out.
--
-- Source: 456 high-res pixels x 312 lines, one pixel per 4 core clocks
-- (pixce), hsync at the start of a line, vsync at the start of a frame.
-- The playfield is x = 112..431, y = 36..275, a known RGB pattern; the rest is
-- blank.  The TB measures where that pattern lands in the 720 x 576 output.
--
-------------------------------------------------------------------------------------------------------------------*/
module tb_video;

reg clk = 1'b0;
always #17.5 clk = ~clk;                 // 28.571 MHz

reg rst = 1'b1;
reg pixce = 1'b0;
reg [7:0] r_i = 8'd0, g_i = 8'd0, b_i = 8'd0;
reg hblank = 1'b1, vblank = 1'b1;
reg hsync_i = 1'b0, vsync_i = 1'b0;
reg pal = 1'b1;

wire [7:0] r_o, g_o, b_o;
wire hs_o, vs_o, de_o;

atari_video dut (
	.clk(clk), .rst(rst), .pixce(pixce),
	.r_i(r_i), .g_i(g_i), .b_i(b_i),
	.hblank(hblank), .vblank(vblank),
	.hsync_i(hsync_i), .vsync_i(vsync_i),
	.pal(pal),
	.r_o(r_o), .g_o(g_o), .b_o(b_o),
	.hs_o(hs_o), .vs_o(vs_o), .de_o(de_o)
);

// ---------------------------------------------------------------- source frame
reg [10:0] shc = 11'd0;                  // 0 .. 1823 clocks in a line
reg [8:0]  svc = 9'd0;                   // 0 .. 311 lines
reg [1:0]  spc = 2'd0;
wire [8:0] sx = shc[10:2];               // 0 .. 455 source pixels
wire       s_active = (svc >= 9'd36) && (svc < 9'd276) && (sx >= 9'd112) && (sx < 9'd432);

always @(posedge clk) begin
	if (rst) begin
		shc <= 11'd0; svc <= 9'd0; spc <= 2'd0;
		pixce <= 1'b0;
		hsync_i <= 1'b0; vsync_i <= 1'b0;
		hblank <= 1'b1; vblank <= 1'b1;
		r_i <= 8'd0; g_i <= 8'd0; b_i <= 8'd0;
	end
	else begin
		pixce <= (spc == 2'd0);
		spc <= spc + 2'd1;
		if (shc == 11'd1823) begin
			shc <= 11'd0;
			if (svc == 9'd311) svc <= 9'd0;
			else svc <= svc + 9'd1;
		end
		else
			shc <= shc + 11'd1;

		hsync_i <= (shc < 11'd16);
		vsync_i <= (svc < 9'd3);
		hblank <= !(sx >= 9'd112 && sx < 9'd432);
		vblank <= !(svc >= 9'd36 && svc < 9'd276);
		r_i <= s_active ? {1'b0, sx[6:0]} : 8'd0;
		g_i <= s_active ? {1'b0, svc[6:0]} : 8'd0;
		b_i <= s_active ? 8'h80 : 8'd0;
	end
end

// ---------------------------------------------------------------- output measurement
integer frame = 0;
integer oline = 0;
integer ocol = 0;
integer first_line = -1, last_line = -1;
integer first_col = -1, last_col = -1;
integer nonblack = 0;
integer de_lines = 0;
integer errors = 0;

reg hs_d = 1'b0, vs_d = 1'b0, de_d = 1'b0;
always @(posedge clk) begin
	hs_d <= hs_o;
	vs_d <= vs_o;
	de_d <= de_o;

	if (!rst) begin
		if (vs_o && !vs_d) begin           // output frame start
			frame = frame + 1;
			oline = 0;
			ocol = 0;
		end
		else if (hs_o && !hs_d) begin      // next output line
			oline = oline + 1;
			ocol = 0;
		end
		else if (de_o) begin
			if (de_o && !de_d) de_lines = de_lines + 1;
			if (r_o != 0 || g_o != 0 || b_o != 0) begin
				nonblack = nonblack + 1;
				if (first_line < 0 || oline < first_line) first_line = oline;
				if (oline > last_line) last_line = oline;
				if (first_col < 0 || ocol < first_col) first_col = ocol;
				if (ocol > last_col) last_col = ocol;
			end
			ocol = ocol + 1;
		end
	end
end

initial begin
	#200_000_000;                        // 200 ms watchdog
	$display("TIMEOUT");
	$finish;
end

initial begin
	#200 rst = 1'b0;
	#45_000_000;                         // > 2 PAL frames (40 ms)
	$display("tb_video: frames=%0d de_lines=%0d nonblack=%0d", frame, de_lines, nonblack);
	if (nonblack == 0) begin
		$display("ERROR: no picture in the output");
		errors = errors + 1;
	end
	$display("picture lines %0d..%0d, columns %0d..%0d",
		first_line, last_line, first_col, last_col);
	if (errors == 0) $display("tb_video: 0 errors");
	else             $display("tb_video: %0d errors", errors);
	$finish;
end

endmodule

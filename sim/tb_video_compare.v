`timescale 1ns / 1ps
/*-------------------------------------------------------------------------------------------------------------------
--
-- tb_video_compare.v - render two candidate windows of atari_video.
--
--   A: SRC_X0=88, SRC_W=356, PIC_LEFT=4  (full wide playfield, wide-centred)
--   B: SRC_X0=78, SRC_W=356, PIC_LEFT=4  (active area centred -> normal field centred)
--
-- Source geometry and markers are the same as tb_video_frame.v:
--   visible x=68..443, wide x=88..443, normal x=96..415, narrow x=128..383,
--   red = wide edges, green = normal edges, blue = active-area centre (x=255).
-- Writes frame_a.ppm and frame_b.ppm (720 x 576, P6).
--
-------------------------------------------------------------------------------------------------------------------*/
module tb_video_compare;

reg clk = 1'b0;
always #17.5 clk = ~clk;                 // 28.571 MHz

reg rst = 1'b1;
reg pixce = 1'b0;
reg [7:0] r_i = 8'd0, g_i = 8'd0, b_i = 8'd0;
reg hblank = 1'b1, vblank = 1'b1;
reg hsync_i = 1'b0, vsync_i = 1'b0;
reg pal = 1'b1;

wire [7:0] ra, ga, ba, rb, gb, bb;
wire hsa, vsa, dea, hsb, vsb, deb;

atari_video #(.SRC_X0(9'd88), .SRC_W(10'd356), .PIC_LEFT(10'd4)) dut_a (
	.clk(clk), .rst(rst), .pixce(pixce),
	.r_i(r_i), .g_i(g_i), .b_i(b_i),
	.hblank(hblank), .vblank(vblank),
	.hsync_i(hsync_i), .vsync_i(vsync_i), .pal(pal),
	.r_o(ra), .g_o(ga), .b_o(ba), .hs_o(hsa), .vs_o(vsa), .de_o(dea)
);

atari_video #(.SRC_X0(9'd78), .SRC_W(10'd356), .PIC_LEFT(10'd4)) dut_b (
	.clk(clk), .rst(rst), .pixce(pixce),
	.r_i(r_i), .g_i(g_i), .b_i(b_i),
	.hblank(hblank), .vblank(vblank),
	.hsync_i(hsync_i), .vsync_i(vsync_i), .pal(pal),
	.r_o(rb), .g_o(gb), .b_o(bb), .hs_o(hsb), .vs_o(vsb), .de_o(deb)
);

// ---------------------------------------------------------------- source frame
reg [10:0] shc = 11'd0;
reg [8:0]  svc = 9'd0;
reg [1:0]  spc = 2'd0;
wire [8:0] sx = shc[10:2];

wire s_visible = (svc >= 9'd44) && (svc < 9'd284) && (sx >= 9'd68) && (sx < 9'd444);
wire s_wide    = (sx >= 9'd88) && (sx < 9'd444);
wire s_normal  = (sx >= 9'd96) && (sx < 9'd416);
wire s_narrow  = (sx >= 9'd128) && (sx < 9'd384);

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
		hblank <= !(sx >= 9'd68 && sx < 9'd444);
		vblank <= !((svc >= 9'd44) && (svc < 9'd284));

		if (!s_visible) begin
			r_i <= 8'd0; g_i <= 8'd0; b_i <= 8'd0;
		end
		else if (sx == 9'd88 || sx == 9'd443) begin
			r_i <= 8'd255; g_i <= 8'd0; b_i <= 8'd0;
		end
		else if (sx == 9'd96 || sx == 9'd415) begin
			r_i <= 8'd0; g_i <= 8'd255; b_i <= 8'd0;
		end
		else if (sx == 9'd255) begin
			r_i <= 8'd0; g_i <= 8'd0; b_i <= 8'd255;
		end
		else if (svc >= 9'd40 && svc < 9'd80) begin
			r_i <= s_wide ? 8'd96 : 8'd48; g_i <= 8'd16; b_i <= 8'd16;
		end
		else if (svc >= 9'd80 && svc < 9'd120) begin
			r_i <= 8'd16; g_i <= s_normal ? 8'd96 : 8'd32; b_i <= 8'd16;
		end
		else if (svc >= 9'd120 && svc < 9'd160) begin
			r_i <= 8'd16; g_i <= 8'd16; b_i <= s_narrow ? 8'd96 : 8'd32;
		end
		else if (svc >= 9'd160 && svc < 9'd200) begin
			if (((sx[2:0]) ^ svc[2:0]) & 1) begin r_i <= 8'd160; g_i <= 8'd160; b_i <= 8'd160; end
			else begin r_i <= 8'd24; g_i <= 8'd24; b_i <= 8'd24; end
		end
		else begin
			r_i <= 8'd48; g_i <= 8'd48; b_i <= 8'd48;
		end
	end
end

// ---------------------------------------------------------------- two framebuffers
localparam integer W = 720;
localparam integer H = 576;
reg [23:0] fa [0:W*H-1];
reg [23:0] fb [0:W*H-1];
integer x, y;
initial begin
	for (y = 0; y < H; y = y + 1) for (x = 0; x < W; x = x + 1) begin
		fa[y*W+x] = 24'd0;
		fb[y*W+x] = 24'd0;
	end
end

integer row = 0, col = 0;
reg cap = 1'b0, vs_seen = 1'b0;
reg ha_d=0, va_d=0, da_d=0;
integer frames = 0;

// Capture exactly the 720 x 576 active output frame: start at the first DE
// pixel after the output vsync (vc = 0), one row per output line.  Do not
// count the blank lines between vsync and the active area (the old version
// did, which shifted the rendered picture down by ~43 lines).
always @(posedge clk) begin
	ha_d <= hsa; va_d <= vsa; da_d <= dea;

	if (!rst) begin
		if (vsa && !va_d) begin
			frames = frames + 1;
			vs_seen = 1'b1;
		end

		if (vs_seen) begin
			if (!cap) begin
				if (dea) begin
					cap = 1'b1;
					row = 0;
					col = 1;
					fa[0] = {ra, ga, ba};
					fb[0] = {rb, gb, bb};
				end
			end
			else begin
				if (dea && col < W) begin
					fa[row*W + col] = {ra, ga, ba};
					fb[row*W + col] = {rb, gb, bb};
					col = col + 1;
				end
				if (hsa && !ha_d) begin
					row = row + 1;
					col = 0;
					if (row >= H) cap = 1'b0;
				end
			end
		end
	end
end

// ---------------------------------------------------------------- measurements + PPM
integer fd, i;
integer wa0, wa1, na0, na1, ca0, ca1;
integer wb0, wb1, nb0, nb1, cb0, cb1;

task scan_a(input [7:0] rr, input [7:0] gg, input [7:0] bb, output integer f, output integer l);
	integer yy, xx;
	begin
		f = -1; l = -1;
		for (yy = 0; yy < H; yy = yy + 1)
			for (xx = 0; xx < W; xx = xx + 1)
				if (fa[yy*W+xx] == {rr,gg,bb}) begin
					if (f < 0) f = xx;
					if (xx > l) l = xx;
				end
	end
endtask

task scan_b(input [7:0] rr, input [7:0] gg, input [7:0] bb, output integer f, output integer l);
	integer yy, xx;
	begin
		f = -1; l = -1;
		for (yy = 0; yy < H; yy = yy + 1)
			for (xx = 0; xx < W; xx = xx + 1)
				if (fb[yy*W+xx] == {rr,gg,bb}) begin
					if (f < 0) f = xx;
					if (xx > l) l = xx;
				end
	end
endtask

task write_ppm(input [8*16-1:0] name, input integer which);
	integer yy, xx;
	begin
		fd = $fopen(name, "wb");
		$fwrite(fd, "P6\n%0d %0d\n255\n", W, H);
		for (yy = 0; yy < H; yy = yy + 1)
			for (xx = 0; xx < W; xx = xx + 1) begin
				if (which == 0)
					$fwrite(fd, "%c%c%c", fa[yy*W+xx][23:16], fa[yy*W+xx][15:8], fa[yy*W+xx][7:0]);
				else
					$fwrite(fd, "%c%c%c", fb[yy*W+xx][23:16], fb[yy*W+xx][15:8], fb[yy*W+xx][7:0]);
			end
		$fclose(fd);
	end
endtask

initial begin
	#200 rst = 1'b0;
	wait (frames == 2);
	#40_000_000;

	scan_a(8'd255, 8'd0,   8'd0,   wa0, wa1);
	scan_a(8'd0,   8'd255, 8'd0,   na0, na1);
	scan_a(8'd0,   8'd0,   8'd255, ca0, ca1);
	scan_b(8'd255, 8'd0,   8'd0,   wb0, wb1);
	scan_b(8'd0,   8'd255, 8'd0,   nb0, nb1);
	scan_b(8'd0,   8'd0,   8'd255, cb0, cb1);

	$display("A wide red   %0d..%0d  centre %0d", wa0, wa1, (wa0+wa1)/2);
	$display("A normal grn %0d..%0d  centre %0d", na0, na1, (na0+na1)/2);
	$display("A blue mark  %0d..%0d  centre %0d", ca0, ca1, (ca0+ca1)/2);
	$display("B wide red   %0d..%0d  centre %0d", wb0, wb1, (wb0+wb1)/2);
	$display("B normal grn %0d..%0d  centre %0d", nb0, nb1, (nb0+nb1)/2);
	$display("B blue mark  %0d..%0d  centre %0d", cb0, cb1, (cb0+cb1)/2);
	$display("frame centre %0d", W/2);

	write_ppm("frame_a.ppm", 0);
	write_ppm("frame_b.ppm", 1);
	$display("tb_video_compare: wrote frame_a.ppm, frame_b.ppm");
	$finish;
end

initial begin
	#300_000_000;
	$display("TIMEOUT frames=%0d", frames);
	$finish;
end

endmodule

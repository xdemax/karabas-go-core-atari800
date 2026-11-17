`timescale 1ns / 1ps
/*-------------------------------------------------------------------------------------------------------------------
--
-- tb_video_frame.v - render one PAL 720 x 576 output frame of atari_video.
--
-- The source is the real Atari line geometry:
--   456 hi-res pixels, 312 lines, hsync at x = 0 (GTIA hpos 0),
--   hblank-free (visible) x = 68..443  (colour clocks 34..221),
--   wide playfield  x = 88..443  (cc 44..221),
--   normal playfield x = 96..415 (cc 48..207),
--   narrow playfield x = 128..383 (cc 64..191),
--   visible lines y = 36..275.
--
-- Markers (all 1 source pixel wide, so 2 output pixels):
--   red   x = 88  and x = 443 : wide playfield edges
--   green x = 96  and x = 415 : normal playfield edges
--   blue  x = 255             : centre of the active area / normal field
--   grey  visible area        : x = 68..443, y = 36..275
-- The frame is written as frame.ppm (P6, 720 x 576).
--
-------------------------------------------------------------------------------------------------------------------*/
module tb_video_frame;

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

		// markers first, then the bands
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
			// wide field band, dark red
			r_i <= s_wide ? 8'd96 : 8'd48; g_i <= 8'd16; b_i <= 8'd16;
		end
		else if (svc >= 9'd80 && svc < 9'd120) begin
			// normal field band, dark green
			r_i <= 8'd16; g_i <= s_normal ? 8'd96 : 8'd32; b_i <= 8'd16;
		end
		else if (svc >= 9'd120 && svc < 9'd160) begin
			// narrow field band, dark blue
			r_i <= 8'd16; g_i <= 8'd16; b_i <= s_narrow ? 8'd96 : 8'd32;
		end
		else if (svc >= 9'd160 && svc < 9'd200) begin
			// 4-pixel checkerboard over the normal field
			if (((sx[2:0]) ^ svc[2:0]) & 1) begin r_i <= 8'd160; g_i <= 8'd160; b_i <= 8'd160; end
			else begin r_i <= 8'd24; g_i <= 8'd24; b_i <= 8'd24; end
		end
		else begin
			// visible area, grey
			r_i <= 8'd48; g_i <= 8'd48; b_i <= 8'd48;
		end
	end
end

// ---------------------------------------------------------------- output frame buffer
localparam integer W = 720;
localparam integer H = 576;
reg [23:0] frame [0:W*H-1];
integer x, y;
initial for (y = 0; y < H; y = y + 1) for (x = 0; x < W; x = x + 1) frame[y*W+x] = 24'd0;

integer oline = 0, ocol = 0;
reg hs_d = 1'b0, vs_d = 1'b0, de_d = 1'b0;
integer frames = 0;
integer vy;

always @(posedge clk) begin
	hs_d <= hs_o;
	vs_d <= vs_o;
	de_d <= de_o;

	if (!rst) begin
		if (vs_o && !vs_d) begin
			frames = frames + 1;
			oline = 0;
			ocol = 0;
		end
		else if (hs_o && !hs_d) begin
			oline = oline + 1;
			ocol = 0;
		end
		else if (de_o) begin
			if (ocol < W && oline < H)
				frame[oline*W + ocol] = {r_o, g_o, b_o};
			ocol = ocol + 1;
		end
	end
end

// ---------------------------------------------------------------- measurements and PPM
integer fd, i;
integer first_w, last_w, first_n, last_n, first_c, last_c;
integer first_pic_line, last_pic_line;

task scan_colour(input [7:0] rr, input [7:0] gg, input [7:0] bb, output integer fcol, output integer lcol);
	integer yy, xx;
	begin
		fcol = -1; lcol = -1;
		for (yy = 0; yy < H; yy = yy + 1)
			for (xx = 0; xx < W; xx = xx + 1)
				if (frame[yy*W+xx] == {rr,gg,bb}) begin
					if (fcol < 0) fcol = xx;
					if (xx > lcol) lcol = xx;
				end
	end
endtask

initial begin
	#200 rst = 1'b0;
	// let the first (partial) frame go by, then render one full frame
	wait (frames == 2);
	#40_000_000;

	scan_colour(8'd255, 8'd0,   8'd0,   first_w, last_w);
	scan_colour(8'd0,   8'd255, 8'd0,   first_n, last_n);
	scan_colour(8'd0,   8'd0,   8'd255, first_c, last_c);

	// first/last output line with a non-black pixel
	first_pic_line = -1; last_pic_line = -1;
	for (y = 0; y < H; y = y + 1)
		for (x = 0; x < W; x = x + 1)
			if (frame[y*W+x] != 24'd0) begin
				if (first_pic_line < 0) first_pic_line = y;
				if (y > last_pic_line) last_pic_line = y;
			end

	$display("tb_video_frame: frames=%0d", frames);
	$display("wide   edges (red)   columns %0d..%0d", first_w, last_w);
	$display("normal edges (green) columns %0d..%0d", first_n, last_n);
	$display("centre marker (blue) columns %0d..%0d", first_c, last_c);
	$display("non-black lines %0d..%0d", first_pic_line, last_pic_line);
	$display("output centre = %0d, normal field centre = %0d", W/2, (first_n + last_n) / 2);

	fd = $fopen("frame.ppm", "wb");
	$fwrite(fd, "P6\n%0d %0d\n255\n", W, H);
	for (y = 0; y < H; y = y + 1)
		for (x = 0; x < W; x = x + 1) begin
			$fwrite(fd, "%c%c%c", frame[y*W+x][23:16], frame[y*W+x][15:8], frame[y*W+x][7:0]);
		end
	$fclose(fd);
	$display("tb_video_frame: wrote frame.ppm");
	$finish;
end

initial begin
	#300_000_000;
	$display("TIMEOUT frames=%0d", frames);
	$finish;
end

endmodule

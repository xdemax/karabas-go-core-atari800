`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Atari 800 video for Karabas Go.
--
-- The Atari core produces 8-bit RGB at the high-resolution colour clock (VIDEO_PIXCE, one per 4 core clocks,
-- 456 pixels per PAL line).  The output is a 720 x 576 @ 50 Hz picture in a 912 x 624 frame at the same
-- 28.571 MHz clock as the core:
--
--   * one source line is 456 high-resolution pixels and 1824 core clocks;
--   * one output line is 912 pixels and 912 core clocks, so a source line is exactly two output lines;
--   * every source pixel is written twice horizontally; every source line is read for two output lines;
--   * two complete line buffers are ping-ponged at hsync, like the UnoXT scandoubler: while one buffer is
--     being captured, the other (already complete) is displayed.  This avoids reading a line that is still
--     being written.
--
-- The counters are locked to the source hsync/vsync, so there is no clock-domain crossing: the line buffers
-- are written and read on the same clock.  The source window is the full wide playfield: 356 source pixels
-- (x = 88 .. 443, ANTIC colour clocks 0x2C .. 0xDE) and 240 source lines.  It is doubled to 712 x 480
-- inside the 720 x 576 window with 4-pixel side borders, so neither the wide nor the normal playfield is
-- cropped; the Atari vertical border remains inside the 480-line picture.
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_video #(
	// Source window inside the 456-pixel line.  The defaults centre the
	// active area / normal 320-pixel playfield (colour clocks 48..207):
	// SRC_X0=78, SRC_W=356 -> 712 output pixels, 4-pixel side borders.
	// The wide playfield (cc 44..221) extends ~5 cc further right and its
	// far right edge falls into the overscan a TV would cut anyway.
	parameter [9:0]  SRC_X0   = 10'd78,
	parameter [9:0]  SRC_W    = 10'd356,
	parameter [9:0]  PIC_LEFT = 10'd4,
	// HDMI boards need a front porch before hsync for the data island trigger
	// (see the comment at HS_START below); VGA keeps the original position.
	parameter [9:0]  HS_START = 10'd816,
	parameter [9:0]  HS_END   = 10'd888
) (
	input wire        clk,
	input wire        rst,

	// from atari800core_simple_sdram (clk)
	input wire        pixce,
	input wire [7:0]  r_i,
	input wire [7:0]  g_i,
	input wire [7:0]  b_i,
	input wire        hblank,
	input wire        vblank,
	input wire        hsync_i,
	input wire        vsync_i,
	input wire        pal,          // 1: PAL (312 lines), 0: NTSC (262 lines)

	// to HDMI / VGA / OSD (clk)
	output reg [7:0]  r_o,
	output reg [7:0]  g_o,
	output reg [7:0]  b_o,
	output reg        hs_o,
	output reg        vs_o,
	output reg        de_o
);

localparam H_TOTAL   = 912;
localparam H_ACTIVE  = 720;
localparam H_START   = 96;                 // first visible output pixel
// 72-pixel hsync at the end of the line and a 24-pixel front porch (816..839).
// The front porch is required by the HDMI data island trigger in zhdmi_signaling:
// it starts an island 4 cycles after DE falls and resets its blank counter on the
// hsync rising edge.  With the sync at 816 (no front porch) that counter reset
// cancelled the trigger, so no audio islands were sent at all (video was fine).
// Mini/MiniG (HDMI) override HS_START/HS_END to 840/912; Go (VGA) keeps 816/888.
localparam SRC_PIX   = 456;                // high-resolution pixels per source line
localparam PIC_START = H_START + PIC_LEFT; // first picture output pixel
localparam PIC_END   = PIC_START + 2*SRC_W;

// ------------------------------------------------------------------ line buffers
// Two 456 x 24-bit buffers, ping-ponged at source hsync (the UnoXT scandoubler approach).
(* ram_style = "block" *) reg [23:0] line_a [0:SRC_PIX-1];
(* ram_style = "block" *) reg [23:0] line_b [0:SRC_PIX-1];
reg        wr_buf = 1'b0;
reg        rd_buf = 1'b0;

// ------------------------------------------------------------------ source side
reg        hs_d = 1'b0, vs_d = 1'b0;
reg        line_start = 1'b0;
reg [8:0]  sx = 9'd0;

wire hs_rise = hsync_i & ~hs_d;
wire vs_rise = vsync_i & ~vs_d;
wire [8:0] wr_x = line_start ? 9'd0 : sx;
wire [23:0] wr_data = (hblank | vblank) ? 24'd0 : {r_i, g_i, b_i};

always @(posedge clk) begin
	hs_d <= hsync_i;
	vs_d <= vsync_i;
	if (rst) begin
		sx <= 9'd0;
		line_start <= 1'b0;
		wr_buf <= 1'b0;
		rd_buf <= 1'b0;
	end
	else begin
		if (hs_rise) begin
			// the line just captured becomes the display buffer; start capturing into the other one
			rd_buf <= wr_buf;
			wr_buf <= ~wr_buf;
			sx <= 9'd0;
			line_start <= 1'b1;
		end
		else if (pixce) begin
			// the first pixel after hsync goes to x = 0 of the new line
			if (line_start) begin
				sx <= 9'd1;
				line_start <= 1'b0;
			end
			else
				sx <= (sx == SRC_PIX-1) ? 9'd0 : (sx + 9'd1);
		end
	end
end

always @(posedge clk) begin
	if (pixce) begin
		if (wr_buf)
			line_b[wr_x] <= wr_data;
		else
			line_a[wr_x] <= wr_data;
	end
end

// ------------------------------------------------------------------ output side
reg [9:0]  hc = 10'd0;
reg        phase = 1'b0;
reg [8:0]  oline = 9'd0;
reg        frame_pend = 1'b0;

// Vertical window: the 240-line Atari picture is doubled to 480 lines.  Its
// position relative to the source vsync is fixed by ANTIC/GTIA:
//   PAL : vsync at vcount 275, vblank ends at vcount 8 -> picture starts at
//         source line 44 after vsync (lines 44..283).
//   NTSC: vsync at vcount 255, vcount wraps at 262, vblank ends at 8 ->
//         picture starts at line 15 (lines 15..254).
// vc = (2*line + K) mod 624.  K=584 puts the PAL picture at vc 48..527
// (48-line bars); K=594 (= -30) puts the NTSC picture at vc 0..479.
localparam [10:0] V_FRAME = 11'd624;
wire [10:0] vc_raw = {oline, 1'b0} + {9'd0, phase} + (pal ? 11'd584 : 11'd594);
wire [9:0]  vc = (vc_raw >= V_FRAME) ? (vc_raw - V_FRAME) : vc_raw[9:0];
wire [9:0]  v_active = pal ? 10'd576 : 10'd480;
wire [9:0]  vs_start = pal ? 10'd581 : 10'd490;
wire [9:0]  vs_end   = vs_start + 10'd5;
wire        in_window = (hc >= H_START) && (hc < H_START + H_ACTIVE);
wire        pic_window = (hc >= PIC_START) && (hc < PIC_END);
wire        line_vis  = (vc < v_active);
wire [9:0]  src_x_out = pic_window ? (SRC_X0 + ((hc - PIC_START) >> 1)) : SRC_X0[9:0];
wire [23:0] rd_data   = rd_buf ? line_b[src_x_out[8:0]] : line_a[src_x_out[8:0]];
wire        hs_now    = (hc >= HS_START) && (hc < HS_END);
wire        vs_now    = (vc >= vs_start) && (vc < vs_end);
wire        de_now    = in_window && line_vis;

always @(posedge clk) begin
	if (rst) begin
		hc <= 10'd0;
		phase <= 1'b0;
		oline <= 9'd0;
		frame_pend <= 1'b0;
	end
	else begin
		if (vs_rise) begin
			oline <= 9'd0;
			phase <= 1'b0;
			hc <= 10'd0;
			frame_pend <= 1'b1;
		end
		else if (hs_rise) begin
			hc <= 10'd0;
			phase <= 1'b0;
			if (!frame_pend)
				oline <= oline + 9'd1;
			frame_pend <= 1'b0;
		end
		else begin
			if (hc == H_TOTAL-1) begin
				hc <= 10'd0;
				phase <= ~phase;
			end
			else
				hc <= hc + 10'd1;
		end
	end
end

// ------------------------------------------------------------------ read + pipeline
reg [23:0] rd = 24'd0;
reg        de_d1 = 1'b0, hs_d1 = 1'b0, vs_d1 = 1'b0;
reg        pic_d1 = 1'b0;

// rd is the pixel for the address of the previous clock, so the one-stage control
// pipeline (de_d1/hs_d1/vs_d1) is the one that matches it.
always @(posedge clk) begin
	rd <= rd_data;
	de_d1 <= de_now; hs_d1 <= hs_now; vs_d1 <= vs_now;
	pic_d1 <= pic_window;

	r_o <= (de_d1 && pic_d1) ? rd[23:16] : 8'd0;
	g_o <= (de_d1 && pic_d1) ? rd[15:8]  : 8'd0;
	b_o <= (de_d1 && pic_d1) ? rd[7:0]   : 8'd0;
	de_o <= de_d1;
	hs_o <= hs_d1;
	vs_o <= vs_d1;
end

endmodule
`default_nettype wire

`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- atari_video_27.v — dual-clock 720x576@50 output for MiniG.
--
-- Write side: Atari core clock 28.571 MHz, 456 hi-res pixels per source line.
-- Read side:  27.027 MHz (VCO 1000 / 37), standard 720x576 timing:
--   DE 0..719, HS 744..808 (24 px front porch for HDMI data islands),
--   VS 581..586, 625 lines, H_TOTAL=862 (matches the 50 Hz source frame).
--
-- The line ring is 4 rows of 456 x 24, written on clk and read on clk_vid.
-- The source frame event is at source line SRC_LINE0+LAG; the read side
-- aligns once per frame, and free-runs otherwise.  If the source stops,
-- sync/DE keep running and the picture goes black.
--
-------------------------------------------------------------------------------------------------------------------*/
module atari_video_27 #(
	parameter [9:0]  H_ACTIVE   = 10'd720,
	parameter [9:0]  H_TOTAL    = 10'd862,
	parameter [9:0]  V_ACTIVE   = 10'd576,
	parameter [9:0]  V_TOTAL    = 10'd625,
	parameter [9:0]  H_SYNC_START = 10'd744,
	parameter [9:0]  H_SYNC_END   = 10'd808,
	parameter [9:0]  V_SYNC_START = 10'd581,
	parameter [9:0]  V_SYNC_END   = 10'd586,
	parameter [8:0]  SRC_PIX    = 9'd456,
	parameter [8:0]  SRC_LINE0  = 9'd44,
	parameter [9:0]  V_OFFSET   = 10'd48,
	parameter [9:0]  V_CONTENT  = 10'd480,
	parameter [8:0]  SRC_X0     = 9'd78,
	parameter [9:0]  X_DELAY    = 10'd4,
	parameter [9:0]  H_VIEW     = 10'd712,
	parameter [8:0]  LAG        = 9'd2
) (
	input wire        clk,          // core clock, 28.571 MHz
	input wire        clk_vid,      // output pixel clock, 27.027 MHz
	input wire        rst,          // power-on reset, clk_vid domain-ish

	// source, clk
	input wire        pixce,
	input wire [7:0]  r_i,
	input wire [7:0]  g_i,
	input wire [7:0]  b_i,
	input wire        hblank,
	input wire        vblank,
	input wire        hsync_i,
	input wire        vsync_i,
	input wire        pal,

	// output, clk_vid
	output reg [7:0]  r_o,
	output reg [7:0]  g_o,
	output reg [7:0]  b_o,
	output reg        hs_o,
	output reg        vs_o,
	output reg        de_o
);

// ------------------------------------------------------------------ line ring
// 4 rows x 456 x 24: true dual-port BRAM (write clk, read clk_vid).
(* ram_style = "block" *) reg [23:0] mem [0:4*SRC_PIX-1];

// ------------------------------------------------------------------ write side
reg        hs_d = 1'b0, vs_d = 1'b0;
reg [8:0]  wr_line = 9'd0;
reg [8:0]  wr_x = 9'd0;
reg        sync_tgl = 1'b0;

wire hs_rise = hsync_i & ~hs_d;
wire vs_rise = vsync_i & ~vs_d;

always @(posedge clk) begin
	hs_d <= hsync_i;
	vs_d <= vsync_i;
	if (pixce) begin
		mem[{wr_line[1:0], wr_x}] <= (hblank | vblank) ? 24'd0 : {r_i, g_i, b_i};
		if (wr_x != SRC_PIX - 9'd1)
			wr_x <= wr_x + 9'd1;
	end
	if (vs_rise) begin
		wr_line <= 9'd0;
		wr_x <= 9'd0;
	end
	else if (hs_rise) begin
		wr_line <= wr_line + 9'd1;
		wr_x <= 9'd0;
		if (wr_line == (SRC_LINE0 + LAG - 9'd1))
			sync_tgl <= ~sync_tgl;
	end
end

// ------------------------------------------------------------------ CDC of frame event
reg t1 = 1'b0, t2 = 1'b0, t3 = 1'b0;
always @(posedge clk_vid) begin
	t1 <= sync_tgl;
	t2 <= t1;
	t3 <= t2;
end
wire sync_pulse = t2 ^ t3;

// ------------------------------------------------------------------ output raster (clk_vid)
reg [9:0] hc = 10'd0, vc = 10'd0;
reg       locked = 1'b0;

wire de0 = (hc < H_ACTIVE) && (vc < V_ACTIVE);
wire hs0 = (hc >= H_SYNC_START) && (hc < H_SYNC_END);
wire vs0 = (vc >= V_SYNC_START) && (vc < V_SYNC_END);

always @(posedge clk_vid) begin
	if (rst) begin
		hc <= 10'd0; vc <= 10'd0; locked <= 1'b0;
	end
	else begin
		if (hc == H_TOTAL - 10'd1) begin
			hc <= 10'd0;
			vc <= (vc == V_TOTAL - 10'd1) ? 10'd0 : vc + 10'd1;
		end
		else
			hc <= hc + 10'd1;

		if (sync_pulse) begin
			if (!locked || vc > 10'd10) begin
				hc <= 10'd0;
				vc <= 10'd0;
			end
			locked <= 1'b1;
		end
	end
end

// ------------------------------------------------------------------ read address / scaling
wire vcontent = (vc >= V_OFFSET) && (vc < V_OFFSET + V_CONTENT);
wire [9:0] vc_rel = vc - V_OFFSET;
wire [8:0] nom_line = SRC_LINE0 + vc_rel[9:1];
reg [1:0]  rd_row = 2'd0;
reg [8:0]  sx = 9'd0;
reg [8:0]  acc = 9'd0; // unused (integer 2x)

wire xwin = (hc >= X_DELAY) && (hc < X_DELAY + H_VIEW);
always @(posedge clk_vid) begin
	if (hc == 10'd0 && !vc[0])
		rd_row <= nom_line[1:0];
	if (hc == X_DELAY)
		sx <= SRC_X0;
	else if ((hc > X_DELAY) && (hc < X_DELAY + H_VIEW))
		sx <= SRC_X0 + ((hc - X_DELAY) >> 1);
end

reg [23:0] rd = 24'd0;
always @(posedge clk_vid)
	rd <= mem[{rd_row, sx}];

// ------------------------------------------------------------------ pipeline + output
reg de_d1 = 1'b0, hs_d1 = 1'b0, vs_d1 = 1'b0;
reg vcontent_d1 = 1'b0, xwin_d1 = 1'b0;
reg de_d2 = 1'b0, hs_d2 = 1'b0, vs_d2 = 1'b0;
reg vcontent_d2 = 1'b0, xwin_d2 = 1'b0;

always @(posedge clk_vid) begin
	de_d1 <= de0; hs_d1 <= hs0; vs_d1 <= vs0;
	vcontent_d1 <= vcontent; xwin_d1 <= xwin;
	de_d2 <= de_d1; hs_d2 <= hs_d1; vs_d2 <= vs_d1;
	vcontent_d2 <= vcontent_d1; xwin_d2 <= xwin_d1;

	de_o <= de_d2;
	hs_o <= hs_d2;
	vs_o <= vs_d2;
	r_o <= (de_d2 && locked && vcontent_d2 && xwin_d2) ? rd[23:16] : 8'd0;
	g_o <= (de_d2 && locked && vcontent_d2 && xwin_d2) ? rd[15:8]  : 8'd0;
	b_o <= (de_d2 && locked && vcontent_d2 && xwin_d2) ? rd[7:0]   : 8'd0;
end

endmodule
`default_nettype wire

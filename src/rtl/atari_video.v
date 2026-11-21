`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Atari 800 video for Karabas Go / Mini / MiniG  (free-running output raster, soft lock to the source, bounded slew)
--
-- Same ports, same output format as before: 720 x 576 @ 50 Hz in a 912 x 624 frame (NTSC: 524 lines), clk = 28.571 MHz.
-- One source line = 456 hi-res pixels = 1824 clk = exactly two output lines.  Source pixel x is shown at output
-- hc = PIC_START + 2*(x - SRC_X0), the source line that was completed by an hsync is shown on the two output lines that
-- follow it.  The picture geometry is therefore identical to the old module.
--
-- What changed (see the review notes):
--   * hc / vc are FREE-RUNNING.  hs_o / vs_o / de_o never depend on hsync_i / vsync_i, so a lost, extra, short or
--     long source line cannot stretch, truncate or remove an output sync pulse.  There is no frame_pend and no
--     unbounded line counter.
--   * Source hsync: edge accepted only if >= HS_MIN clk after the previous one (rejects glitches).  If none arrives
--     within HS_WD clk a synthetic line end is generated (the line buffers keep ping-ponging).
--   * Horizontal lock: the phase of an accepted hsync in the 1824-clk line-pair is compared to H_LAG.  Small errors
--     (<= H_WIN) are slewed by 1 clk per source line (one output line becomes 911/913 clk long).  Larger errors have
--     to repeat 3 times in a row before the raster is re-phased.
--   * Vertical lock: vsync must stay high >= VS_MIN clk.  Its position in the output frame is compared to the
--     expected one.  A single wrong VS (extra, early, late) is ignored; two consecutive VS with the same error
--     re-phase the raster by that error.  No valid VS never stops anything.
--   * Line buffers: write index saturates at 456 (no wrap onto the start of the line), the length of every written
--     line is stored and the reader shows black beyond it, so stale pixels of an older line are never displayed.
--     The reader picks the last COMPLETED buffer at the start of each line-pair; because the pair starts H_LAG clk
--     after the source line end, the writer is never in the buffer being read (see the timing note at rd_buf).
--
-- Interface is unchanged on purpose.  Interlace is not wired (interlace_enable is 0 in atari800_machine): the raster
-- is field-independent, so odd/even fields just show as 240 doubled lines at a stable 50 Hz.
--
-- Diagnostics: the cnt_* registers can be read hierarchically in simulation; define ATARI_VIDEO_DEBUG to print a
-- line per output frame.  They have no loads, so synthesis removes them.
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_video #(
	parameter [9:0]  SRC_X0   = 10'd78,
	parameter [9:0]  SRC_W    = 10'd356,
	parameter [9:0]  PIC_LEFT = 10'd4,
	parameter [9:0]  HS_START = 10'd732,
	parameter [9:0]  HS_END   = 10'd796,
	// output line (even) on which the pair showing source line 0 (the line that contains vsync) starts
	parameter [9:0]  PAL_VK   = 10'd584,   // PAL : picture src lines 44..283 -> output lines 48..527
	parameter [9:0]  NTSC_VK  = 10'd494,   // NTSC: picture src lines 15..254 -> output lines 0..479 (524-line frame)
	parameter [10:0] H_LAG    = 11'd256,   // output line-pair starts this many clk after the source hsync
	parameter [10:0] H_WIN    = 11'd96,    // |phase error| up to this is slewed, more is a "bad" line
	parameter [11:0] HS_MIN   = 12'd1200,  // minimum clk between accepted hsyncs
	parameter [11:0] HS_WD    = 12'd1900,  // no hsync for this long -> synthetic line end
	parameter [11:0] VS_MIN   = 12'd256,   // vsync must be high at least this long
	parameter [5:0]  STEP_MAX = 6'd12,     // max clk added/removed per line while following a large phase change
	parameter        DBG_OVERLAY = 1'b0    // 1: draw status bits in the black border rows 8..15 and 24..31 (PAL)
) (
	input wire        clk,
	input wire        rst,

	input wire        pixce,
	input wire [7:0]  r_i,
	input wire [7:0]  g_i,
	input wire [7:0]  b_i,
	input wire        hblank,
	input wire        vblank,
	input wire        hsync_i,
	input wire        vsync_i,
	input wire        pal,          // 1: PAL (312 lines), 0: NTSC (262 lines)

	output reg [7:0]  r_o,
	output reg [7:0]  g_o,
	output reg [7:0]  b_o,
	output reg        hs_o,
	output reg        vs_o,
	output reg        de_o
);

localparam H_TOTAL   = 912;
localparam H_ACTIVE  = 720;
localparam H_START   = 0;                  // DE = 0..719 (standard 720x576 position)
localparam SRC_PIX   = 456;
localparam PIC_START = H_START + PIC_LEFT;
localparam PIC_END   = PIC_START + 2*SRC_W;

// ------------------------------------------------------------------ line buffers
(* ram_style = "block" *) reg [23:0] line_a [0:SRC_PIX-1];
(* ram_style = "block" *) reg [23:0] line_b [0:SRC_PIX-1];

// ------------------------------------------------------------------ source side
reg        hs_d = 1'b0, vs_d = 1'b0;
reg [11:0] since_hs = HS_MIN;
reg [8:0]  sx = 9'd0;
reg        wr_buf = 1'b0;
reg [8:0]  len_a = 9'd0, len_b = 9'd0;

wire hs_rise = hsync_i & ~hs_d;
wire vs_rise = vsync_i & ~vs_d;
wire vs_fall = ~vsync_i & vs_d;
wire hs_ok   = hs_rise && (since_hs >= HS_MIN);     // real, accepted line start
wire hs_wd   = (since_hs == HS_WD);                 // synthetic line end
wire line_evt = hs_ok | hs_wd;

wire        sx_full = (sx >= SRC_PIX);
wire        wr_en   = pixce & ~sx_full;
wire [23:0] wr_data = (hblank | vblank) ? 24'd0 : {r_i, g_i, b_i};

// diagnostics
reg [15:0] cnt_src_hs = 16'd0, cnt_src_vs = 16'd0, cnt_hs_extra = 16'd0, cnt_hs_wd = 16'd0, cnt_ovf = 16'd0;

always @(posedge clk) begin
	if (wr_en & ~wr_buf) line_a[sx] <= wr_data;
	if (wr_en &  wr_buf) line_b[sx] <= wr_data;
end

always @(posedge clk) begin
	hs_d <= hsync_i;
	vs_d <= vsync_i;
	if (rst) begin
		since_hs <= HS_MIN;
		sx <= 9'd0;
		wr_buf <= 1'b0;
		len_a <= 9'd0;
		len_b <= 9'd0;
	end
	else begin
		if (line_evt) since_hs <= 12'd0;
		else if (since_hs != 12'hFFF) since_hs <= since_hs + 12'd1;

		if (hs_rise && !hs_ok) cnt_hs_extra <= cnt_hs_extra + 16'd1;
		if (hs_wd && !hs_ok)   cnt_hs_wd    <= cnt_hs_wd + 16'd1;
		if (hs_ok)             cnt_src_hs   <= cnt_src_hs + 16'd1;
		if (pixce && sx_full && !line_evt) cnt_ovf <= cnt_ovf + 16'd1;

		if (line_evt) begin
			// a pixce on the very clock of the event still belongs to the old line (as in the old module)
			if (wr_buf) len_b <= wr_en ? (sx + 9'd1) : sx;
			else        len_a <= wr_en ? (sx + 9'd1) : sx;
			wr_buf <= ~wr_buf;
			sx <= 9'd0;
		end
		else if (wr_en)
			sx <= sx + 9'd1;
	end
end

// ------------------------------------------------------------------ output raster (free running)
reg [9:0]  hc = 10'd0;
reg [9:0]  vc = 10'd0;
reg        adj_stall = 1'b0, adj_skip = 1'b0;
reg [5:0]  adj_n = 6'd0;                // clk to hold (stall) / to cut from the line (skip)
reg        h_locked = 1'b0, v_locked = 1'b0;
reg [1:0]  h_bad = 2'd0;
reg        v_bad = 1'b0;
reg [10:0] verr_prev = 11'd0;
reg        pal_d = 1'b1;

reg        rd_buf = 1'b0;
reg [8:0]  rd_len = 9'd0;

reg        vs_arm = 1'b0, vs_cap = 1'b0, vs_ok = 1'b0;
reg [9:0]  vc_cap = 10'd0;
reg [11:0] vs_cnt = 12'd0;
reg [3:0]  frames_no_vs = 4'd0;
reg        vs_now_d = 1'b0;

reg [15:0] cnt_out_vs = 16'd0, cnt_hresync = 16'd0, cnt_vresync = 16'd0, cnt_vs_rej = 16'd0;

wire [9:0] v_total = pal ? 10'd624 : 10'd524;
wire [9:0] vc_last = v_total - 10'd1;
wire [9:0] vk      = pal ? PAL_VK : NTSC_VK;
// pair that follows the vsync-containing source line shows source line -1
wire [9:0] v_expect = (vk >= 10'd2) ? (vk - 10'd2) : (vk + v_total - 10'd2);

wire       hold    = (hc == H_TOTAL-1) && adj_stall && (adj_n != 6'd0);
wire       skip_at = adj_skip && (adj_n != 6'd0) && (hc == (10'd911 - {4'b0, adj_n}));
wire       hc_wr   = !hold && ((hc == H_TOTAL-1) || skip_at);
wire [9:0] vc_inc  = (vc >= vc_last) ? 10'd0 : (vc + 10'd1);
wire [9:0] vc_next = hc_wr ? vc_inc : vc;
wire [9:0] vc_next_inc = (vc_next >= vc_last) ? 10'd0 : (vc_next + 10'd1);
wire [10:0] pc     = vc[0] ? ({1'b0, hc} + 11'd912) : {1'b0, hc};   // position inside the 1824-clk line pair

integer perr, verr, vn, vtot;
always @* begin
	// hsync must arrive at pc = 1824 - H_LAG, i.e. the pair starts H_LAG clk AFTER the source line end
	perr = $signed({1'b0, pc}) + $signed({1'b0, H_LAG}) - 1824;
	if (perr < -912) perr = perr + 1824;
	vtot = v_total;
	verr = $signed({1'b0, vc_cap}) - $signed({1'b0, v_expect});
	if (verr > vtot/2)         verr = verr - vtot;
	else if (verr < -(vtot/2)) verr = verr + vtot;
	vn = $signed({1'b0, vc_next}) - verr;
	if (vn < 0)      vn = vn + vtot;
	if (vn >= vtot)  vn = vn - vtot;
end

wire perr_big = ((perr < 0) ? -perr : perr) > H_WIN;
integer hstep;
always @* begin
	hstep = (perr < 0) ? -perr : perr;
	if (perr_big) begin if (hstep > STEP_MAX) hstep = STEP_MAX; end
	else if (hstep > 1) hstep = 1;
end
wire src_lost = (frames_no_vs >= 4'd3);

wire [9:0]  v_active = pal ? 10'd576 : 10'd480;
wire [9:0]  vs_start = pal ? 10'd581 : 10'd490;
wire [9:0]  vs_end   = vs_start + 10'd5;
wire        in_window  = (hc >= H_START) && (hc < H_START + H_ACTIVE);
wire        pic_window = (hc >= PIC_START) && (hc < PIC_END);
wire        line_vis   = (vc < v_active);
wire        pic_row    = pal ? ((vc >= 10'd48) && (vc < 10'd528)) : 1'b1;   // RGB black outside the picture, DE untouched
wire [9:0]  src_x_out  = pic_window ? (SRC_X0 + ((hc - PIC_START) >> 1)) : SRC_X0;
wire        hs_now     = (hc >= HS_START) && (hc < HS_END);
wire        vs_now     = (vc >= vs_start) && (vc < vs_end);
wire        de_now     = in_window && line_vis;

always @(posedge clk) begin
	pal_d <= pal;
	vs_now_d <= vs_now;
	if (rst) begin
		hc <= 10'd0; vc <= 10'd0;
		adj_stall <= 1'b0; adj_skip <= 1'b0; adj_n <= 6'd0;
		h_locked <= 1'b0; v_locked <= 1'b0; h_bad <= 2'd0; v_bad <= 1'b0;
		vs_arm <= 1'b0; vs_cap <= 1'b0; vs_ok <= 1'b0; vs_cnt <= 12'd0;
		frames_no_vs <= 4'd0;
		rd_buf <= 1'b0; rd_len <= 9'd0;
	end
	else begin
		// ---- 1. free-running raster; +-1 clk slew is applied at the next line boundary
		if (hold) begin
			adj_n <= adj_n - 6'd1;
			if (adj_n == 6'd1) adj_stall <= 1'b0;
		end
		else if (hc_wr) begin
			hc <= 10'd0;
			vc <= vc_inc;
			if (skip_at) begin adj_skip <= 1'b0; adj_n <= 6'd0; end
		end
		else
			hc <= hc + 10'd1;

		if (hc_wr && vc == vc_last && frames_no_vs != 4'hF)
			frames_no_vs <= frames_no_vs + 4'd1;
		if (vs_now && !vs_now_d) cnt_out_vs <= cnt_out_vs + 16'd1;

		// ---- 2. start of a line pair: pick the last completed buffer
		// The pair starts H_LAG (+-H_WIN) clk after the source hsync that completed the line, so the buffer chosen here
		// is the newest complete one.  The next hsync (1824 clk later) makes the writer start at x=0 of THIS buffer,
		// but by then the reader is past hc = PIC_END (x of the last displayed pixel is 433, written at >= 4*433 clk).
		if (hc == 10'd0 && !vc[0]) begin
			rd_buf <= ~wr_buf;
			rd_len <= wr_buf ? len_a : len_b;
			if (vs_arm) begin
				vc_cap <= vc;
				vs_cap <= 1'b1;
				vs_arm <= 1'b0;
			end
		end

		// ---- 3. vsync qualification
		if (!vsync_i) vs_cnt <= 12'd0;
		else if (vs_cnt != 12'hFFF) vs_cnt <= vs_cnt + 12'd1;

		if (vs_rise) begin
			vs_arm <= 1'b1; vs_cap <= 1'b0; vs_ok <= 1'b0;
		end
		else if (vsync_i && vs_cnt == VS_MIN)
			vs_ok <= 1'b1;
		else if (vs_fall && !vs_ok) begin
			vs_arm <= 1'b0; vs_cap <= 1'b0;
			cnt_vs_rej <= cnt_vs_rej + 16'd1;
		end

		// ---- 4. vertical lock: valid VS and its position captured
		if (vs_cap && vs_ok) begin
			vs_cap <= 1'b0; vs_ok <= 1'b0;
			cnt_src_vs <= cnt_src_vs + 16'd1;
			frames_no_vs <= 4'd0;
			if (verr == 0) begin
				v_bad <= 1'b0; v_locked <= 1'b1;
			end
			else if (!v_locked || (v_bad && verr_prev == verr[10:0])) begin
				vc <= vn[9:0];
				v_locked <= 1'b1; v_bad <= 1'b0;
				cnt_vresync <= cnt_vresync + 16'd1;
			end
			else begin
				v_bad <= 1'b1;
				verr_prev <= verr[10:0];
			end
		end
		if (pal != pal_d) begin
			v_locked <= 1'b0; v_bad <= 1'b0;
		end

		// ---- 5. horizontal lock on accepted hsync (only the very first one jumps; afterwards the raster is only slewed)
		if (hs_ok) begin
			if (!h_locked) begin
				hc <= 10'd913 - H_LAG[9:0];             // pc = 1824-H_LAG+1 (second line of a pair)
				vc <= vc_next[0] ? vc_next : vc_next_inc; // so vc must be odd here
				adj_stall <= 1'b0; adj_skip <= 1'b0; adj_n <= 6'd0;
				h_locked <= 1'b1; h_bad <= 2'd0;
				cnt_hresync <= cnt_hresync + 16'd1;
			end
			else begin
				if (!perr_big) h_bad <= 2'd0;
				else if (h_bad != 2'd2) h_bad <= h_bad + 2'd1;
				// small error: +-1 clk; large error: only after 3 consecutive bad events, then +-STEP_MAX per line
				if (perr != 0 && (!perr_big || h_bad == 2'd2)) begin
					adj_n <= hstep[5:0];
					adj_stall <= (perr > 0);
					adj_skip  <= (perr < 0);
					if (perr_big) cnt_hresync <= cnt_hresync + 16'd1;
				end
			end
		end
	end
end


// ------------------------------------------------------------------ optional on-screen status (DBG_OVERLAY)
// Two rows of 16-px cells in the black border.  Cell k = hc[9:4]; white = 1, dark grey = 0, MSB first.
//  row A (lines 8..15): cells 0-7 cnt_hresync | 9-16 cnt_vresync | 18-25 cnt_vs_rej | 27-34 cnt_hs_wd |
//                       36 h_locked, 37 v_locked, 38 src_lost, 39 any overflow
//  row B (lines 24..31): cells 0-7 cnt_src_vs | 9-16 cnt_src_hs | 18-25 cnt_out_vs | 27-34 cnt_hs_extra
// (low 8 bits of free-running counters; take two photos to see which ones move)
wire       dbg_rowA = (vc >= 10'd8)  && (vc < 10'd16);
wire       dbg_rowB = (vc >= 10'd24) && (vc < 10'd32);
wire [5:0] dcell = hc[9:4];
reg        dbg_cellv, dbg_bit;
always @* begin
	dbg_cellv = 1'b0; dbg_bit = 1'b0;
	if (dbg_rowA) begin
		if (dcell < 6'd8)                          begin dbg_cellv = 1'b1; dbg_bit = cnt_hresync[3'd7 - dcell[2:0]]; end
		else if (dcell >= 6'd9  && dcell < 6'd17) begin dbg_cellv = 1'b1; dbg_bit = cnt_vresync[3'd7 - (dcell[2:0] - 3'd1)]; end
		else if (dcell >= 6'd18 && dcell < 6'd26) begin dbg_cellv = 1'b1; dbg_bit = cnt_vs_rej [3'd7 - (dcell[2:0] - 3'd2)]; end
		else if (dcell >= 6'd27 && dcell < 6'd35) begin dbg_cellv = 1'b1; dbg_bit = cnt_hs_wd  [3'd7 - (dcell[2:0] - 3'd3)]; end
		else if (dcell == 6'd36) begin dbg_cellv = 1'b1; dbg_bit = h_locked; end
		else if (dcell == 6'd37) begin dbg_cellv = 1'b1; dbg_bit = v_locked; end
		else if (dcell == 6'd38) begin dbg_cellv = 1'b1; dbg_bit = src_lost; end
		else if (dcell == 6'd39) begin dbg_cellv = 1'b1; dbg_bit = (cnt_ovf != 16'd0); end
	end
	else if (dbg_rowB) begin
		if (dcell < 6'd8)                          begin dbg_cellv = 1'b1; dbg_bit = cnt_src_vs  [3'd7 - dcell[2:0]]; end
		else if (dcell >= 6'd9  && dcell < 6'd17) begin dbg_cellv = 1'b1; dbg_bit = cnt_src_hs  [3'd7 - (dcell[2:0] - 3'd1)]; end
		else if (dcell >= 6'd18 && dcell < 6'd26) begin dbg_cellv = 1'b1; dbg_bit = cnt_out_vs  [3'd7 - (dcell[2:0] - 3'd2)]; end
		else if (dcell >= 6'd27 && dcell < 6'd35) begin dbg_cellv = 1'b1; dbg_bit = cnt_hs_extra[3'd7 - (dcell[2:0] - 3'd3)]; end
	end
end
reg dbg_d1 = 1'b0, dbg_bit_d1 = 1'b0;
always @(posedge clk) begin
	dbg_d1 <= DBG_OVERLAY && in_window && dbg_cellv;
	dbg_bit_d1 <= dbg_bit;
end

// ------------------------------------------------------------------ read + pipeline (same latency as before)
wire [8:0] ra = src_x_out[8:0];
reg [23:0] rd_a_q = 24'd0, rd_b_q = 24'd0;
reg        de_d1 = 1'b0, hs_d1 = 1'b0, vs_d1 = 1'b0, ok_d1 = 1'b0;

always @(posedge clk) begin
	rd_a_q <= line_a[ra];
	rd_b_q <= line_b[ra];
end
wire [23:0] rd_q = rd_buf ? rd_b_q : rd_a_q;

always @(posedge clk) begin
	de_d1 <= de_now; hs_d1 <= hs_now; vs_d1 <= vs_now;
	// black beyond the length of the line that was actually written
	ok_d1 <= pic_window && pic_row && ({1'b0, src_x_out[8:0]} < {1'b0, rd_len});

	r_o <= dbg_d1 ? (dbg_bit_d1 ? 8'hFF : 8'h30) : (de_d1 && ok_d1) ? rd_q[23:16] : 8'd0;
	g_o <= dbg_d1 ? (dbg_bit_d1 ? 8'hFF : 8'h30) : (de_d1 && ok_d1) ? rd_q[15:8]  : 8'd0;
	b_o <= dbg_d1 ? (dbg_bit_d1 ? 8'hFF : 8'h30) : (de_d1 && ok_d1) ? rd_q[7:0]   : 8'd0;
	de_o <= de_d1;
	hs_o <= hs_d1;
	vs_o <= vs_d1;
end

`ifdef ATARI_VIDEO_DEBUG
always @(posedge clk)
	if (!rst && hc_wr && vc == vc_last)
		$display("[atari_video %0t] src_hs=%0d src_vs=%0d hs_extra=%0d hs_wd=%0d ovf=%0d vs_rej=%0d hresync=%0d vresync=%0d lock=%b%b lost=%b",
			$time, cnt_src_hs, cnt_src_vs, cnt_hs_extra, cnt_hs_wd, cnt_ovf, cnt_vs_rej, cnt_hresync, cnt_vresync, h_locked, v_locked, src_lost);
`endif

endmodule
`default_nettype wire

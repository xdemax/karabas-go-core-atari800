`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Minimal HDMI output for the Atari core (Mini G), without the FT812 second video source.
--
-- The pixel clock is the core clock (28.571 MHz).  A DCM_SP makes the 5x TMDS serializer clock; the video and
-- the 48 kHz audio sample are registered on the falling core clock and taken into the pixel-clock domain, the
-- same hand-off that kg_hdmi_ft uses.  This replaces kg_hdmi_ft on a board where the FT812 is not needed:
-- no DCM_CLKGEN, no BUFGMUX, no frequency counter and no FT video FIFO.
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_hdmi #(
	parameter integer SAMPLERATE = 48000,
	parameter integer CLKRATE = 28571400,
	parameter integer INPUT_REG = 1
) (
	input wire        clk,       // core / pixel clock (28.571 MHz)
	input wire        reset,
	input wire [23:0] rgb,
	input wire        hs,
	input wire        vs,
	input wire        de,
	input wire        audio_en,
	input wire [15:0] audio_l,
	input wire [15:0] audio_r,
	output wire [3:0] tmds_p,
	output wire [3:0] tmds_n
);

// ------------------------------------------------------------------ 5x pixel clock
wire pll_rst;
pll_reset pll_reset_i (
	.clk     (clk),
	.i_reset (reset),
	.o_reset (pll_rst)
);

wire clk0, clkfx, clkfx180, clkfbout, lockedx5;
wire clk_hdmi, clk_hdmi_n;
DCM_SP #(
	.CLKDV_DIVIDE        (2.000),
	.CLKFX_DIVIDE        (1),
	.CLKFX_MULTIPLY      (5),
	.CLKIN_DIVIDE_BY_2   ("FALSE"),
	.CLKIN_PERIOD        (35.000),
	.CLKOUT_PHASE_SHIFT  ("NONE"),
	.CLK_FEEDBACK        ("1X"),
	.DESKEW_ADJUST       ("SYSTEM_SYNCHRONOUS"),
	.PHASE_SHIFT         (0),
	.STARTUP_WAIT        ("FALSE")
) dcm (
	.CLKIN   (clk),
	.CLKFB   (clkfbout),
	.CLK0    (clk0),
	.CLK90   (),
	.CLK180  (),
	.CLK270  (),
	.CLK2X   (),
	.CLK2X180(),
	.CLKFX   (clkfx),
	.CLKFX180(clkfx180),
	.CLKDV   (),
	.PSCLK   (1'b0),
	.PSEN    (1'b0),
	.PSINCDEC(1'b0),
	.PSDONE  (),
	.LOCKED  (lockedx5),
	.STATUS  (),
	.RST     (pll_rst),
	.DSSEN   (1'b0)
);

BUFG clkf_buf    (.O(clkfbout),  .I(clk0));
BUFG clkout1_buf (.O(clk_hdmi),  .I(clkfx));
BUFG clkout2_buf (.O(clk_hdmi_n),.I(clkfx180));
wire clk_pix;
BUFG clkout3_buf (.O(clk_pix),   .I(clk0));

// ------------------------------------------------------------------ video hand-off
// The video registers on the falling core clock; the pixel clock is the core clock through the DCM.  This is
// the same half-period hand-off as in kg_hdmi_ft.
reg [26:0] vga_n = 27'd0;
always @(negedge clk)
	vga_n <= {de, hs, vs, rgb};

reg [26:0] vga_p = 27'd0;
always @(posedge clk_pix)
	vga_p <= vga_n;

reg [1:0] tx_reset_s = 2'b11;
wire tx_reset = pll_rst || ~lockedx5;
always @(posedge clk_pix or posedge tx_reset)
	if (tx_reset)
		tx_reset_s <= 2'b11;
	else
		tx_reset_s <= {tx_reset_s[0], 1'b0};

// ------------------------------------------------------------------ audio
// One sample every CLKRATE / SAMPLERATE clocks; the value is stable for the whole period, and a toggle moves
// it into the pixel clock.
localparam integer SAMPLE_LAST_I = CLKRATE / SAMPLERATE - 1;
localparam [15:0] SAMPLE_LAST = SAMPLE_LAST_I[15:0];
reg [15:0] sample_cnt = 16'd0;
reg [31:0] sample_ref = 32'd0;
reg sample_tgl = 1'b0;
always @(negedge clk) begin
	if (sample_cnt == SAMPLE_LAST) begin
		sample_cnt <= 16'd0;
		sample_ref <= {audio_l, audio_r};
		sample_tgl <= ~sample_tgl;
	end
	else
		sample_cnt <= sample_cnt + 16'd1;
end

reg [2:0] sample_sync = 3'b000;
reg audio_clk = 1'b0;
reg signed [23:0] hdmi_audio_l = 24'd0, hdmi_audio_r = 24'd0;
always @(posedge clk_pix) begin
	sample_sync <= {sample_sync[1:0], sample_tgl};
	audio_clk <= sample_sync[2] ^ sample_sync[1];
	if (sample_sync[2] ^ sample_sync[1]) begin
		hdmi_audio_l <= {sample_ref[31:16], 8'd0};
		hdmi_audio_r <= {sample_ref[15:0], 8'd0};
	end
end

// audio_en comes from the MCU link (clk_host); it is static, synchronise it into the pixel clock.
reg audio_en_s0 = 1'b0, audio_en_s1 = 1'b0;
always @(posedge clk_pix) begin
	audio_en_s0 <= audio_en;
	audio_en_s1 <= audio_en_s0;
end

// ------------------------------------------------------------------ transmitter
hdmi_tx #(.SAMPLE_FREQ(SAMPLERATE), .INPUT_REG(INPUT_REG)) tx (
	.clk       (clk_pix),
	.sclk      (clk_hdmi),
	.sclk_n    (clk_hdmi_n),
	.reset     (tx_reset_s[1]),
	.rgb       (vga_p[23:0]),
	.vsync     (vga_p[24]),
	.hsync     (vga_p[25]),
	.de        (vga_p[26]),
	.audio_en  (audio_en_s1),
	.audio_l   (hdmi_audio_l),
	.audio_r   (hdmi_audio_r),
	.audio_clk (audio_clk),
	.tx_clk_n  (tmds_n[3]),
	.tx_clk_p  (tmds_p[3]),
	.tx_d_n    (tmds_n[2:0]),
	.tx_d_p    (tmds_p[2:0])
);

endmodule
`default_nettype wire

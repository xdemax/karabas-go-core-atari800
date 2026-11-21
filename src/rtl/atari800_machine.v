`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Atari 800XL machine for Karabas Go.
--
-- The machine is the MiSTer a8core (atari800core_simple_sdram, cycle_length = 16, internal OS/BASIC ROM in
-- BRAM) with the Karabas peripherals: the 4 MB asynchronous SRAM instead of SDRAM, a 720 x 576 @ 50 Hz video
-- converter, the USB keyboard scancodes of the MCU, two Karabas joysticks and the 48 kHz audio path.
--
-- The core is built with low_memory = 4 (see address_decoder.vhdl):
--   0x000000-0x1FFFFF  RAM (the core uses at most 1088K with RAM_SELECT = 6)
--   0x200000-0x2FFFFF  cartridge image (1 MB)
--
-------------------------------------------------------------------------------------------------------------------*/

module atari800_machine #(
	// HDMI boards need a front porch for the data island (audio) trigger.
	parameter [9:0] HS_START = 10'd816,
	parameter [9:0] HS_END   = 10'd888,
	// MiniG: dual-clock 720x576 standard output (27.027 MHz video clock).
	parameter       VIDEO27  = 0
) (
	input wire        clk,
	input wire        clk_vid,          // video pixel clock (VGA/HDMI)
	input wire        reset,          // active high: any reset (warm or cold)
	input wire        power_reset,    // active high: cold reset (POWER_RESET), with reset
	input wire        force_cold,     // no disk mounted: force an OS cold start on reset
	input wire        reset_host,     // power-on only: the keyboard state survives F12
	input wire        pause,

	// MCU keyboard (PS/2 set 2 bytes)
	input wire [7:0]  kb_scancode,
	input wire        kb_scancode_upd,

	// MCU joysticks: {C,B,A,right,left,down,up,...}
	input wire [12:0] joy_l,
	input wire [12:0] joy_r,
	input wire        sw_joy_swap,

	// OSD settings (static)
	input wire [2:0]  ram_sel,        // 0=64K .. 6=1088K
	input wire [7:0]  cart_sel,       // CartLogic mode
	input wire        pal,
	input wire        clip_sides,
	input wire        gtia_xcolor,

	// file loader byte stream (clk_host) -> SRAM (clk)
	input wire        ld_req,
	input wire [24:0] ld_addr,
	input wire [7:0]  ld_data,

	// video (clk_vid)
	output wire [23:0] rgb,
	output wire        hs,
	output wire        vs,
	output wire        de,

	// audio (clk, signed 18 bit)
	output wire signed [17:0] audio_l,
	output wire signed [17:0] audio_r,

	// SIO device pins (internal POKEY SIO)
	output wire        sio_command,
	input wire         sio_rxd,
	output wire        sio_txd,
	output wire        sio_clock,
	output wire        sio_motor,

	// SIO disk one-byte SRAM read port
	input wire         dsk_req,
	input wire [24:0]  dsk_addr,
	output wire [7:0]  dsk_data,
	output wire        dsk_ack,
	output wire [7:0]  dbg_defer,

	// SRAM pins
	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N
);

// ------------------------------------------------------------------ POKEYMAX initial configuration
// The same defaults as the MiSTer menu with PokeyMax off / mono: one POKEY, GTIA sound mixed in,
// stereo not used.  INIT_CONFIG(0) = 0 keeps the fancy (SID/PSG/sample) blocks out of the audio path.
localparam [38:0] POKEY_CFG = {
	3'b001,   // 38:36 mix_sel2
	3'b000,   // 35:33 mix_sel1
	2'b01,    // 32:31 psg_stereo
	1'b0,     // 30    psg_envelope
	2'b00,    // 29:28 psg_volume
	2'b00,    // 27:26 psg_freq
	3'b010,   // 25:23 sid2_filter
	3'b010,   // 22:20 sid1_filter
	1'b1,     // 19    covox_restrict
	1'b1,     // 18    psg_restrict
	1'b1,     // 17    sid_restrict
	2'b11,    // 16:15 pokey_restrict
	1'b0,     // 14    irqs
	1'b1,     // 13    volume
	1'b0,     // 12    channel_mode
	2'b10,    // 11:10 adc_vol
	2'b11,    // 9:8   gtia_mix
	4'b0100,  // 7:4   post_divide
	2'b11,    // 3:2   channel_en
	1'b1,     // 1     mono_detect
	1'b0      // 0     fancy enable (PokeyMax off)
};

// ------------------------------------------------------------------ keyboard
// kg_mcu sends the raw PS/2 bytes (E0 / F0 prefixes + code).  ps2_to_atari800 in direct mode wants a
// 32-bit event: bit 7:0 code, bit 12 extended, bit 16 pressed.  It keeps the 512-bit key map itself.
reg [31:0] key_input = 32'd0;
reg        kb_upd_d = 1'b0;
reg        kb_ext = 1'b0, kb_rel = 1'b0;

always @(posedge clk) begin
	kb_upd_d <= kb_scancode_upd;
	if (reset_host) begin
		key_input <= 32'd0;
		kb_ext <= 1'b0;
		kb_rel <= 1'b0;
	end
	else if (kb_scancode_upd != kb_upd_d) begin
		if (kb_scancode == 8'hE0)
			kb_ext <= 1'b1;
		else if (kb_scancode == 8'hF0)
			kb_rel <= 1'b1;
		else begin
			key_input <= {12'd0, 3'd0, ~kb_rel, 3'd0, kb_ext, 4'd0, kb_scancode};
			kb_ext <= 1'b0;
			kb_rel <= 1'b0;
		end
	end
end

wire [5:0]  keyboard_scan;
wire [1:0]  keyboard_response;
wire        consol_start, consol_select, consol_option;
wire        cold_clear = power_reset | force_cold | (reset & consol_option);   // cold reset, Option+F12, or no disk
wire [11:0] fkeys;
wire        freezer_activate;
wire [511:0] ps2_keys;

ps2_to_atari800 #(.ps2_enable(0), .direct_enable(1)) keyboard (
	.CLK               (clk),
	.RESET_N           (~reset_host),
	.PS2_CLK           (1'b1),
	.PS2_DAT           (1'b1),
	.INPUT             (key_input),
	.INPUT2            (5'b00000),
	.SPACE_FORCE       (1'b0),
	.KEYBOARD_SCAN     (keyboard_scan),
	.KEYBOARD_RESPONSE (keyboard_response),
	.CONSOL_START      (consol_start),
	.CONSOL_SELECT     (consol_select),
	.CONSOL_OPTION     (consol_option),
	.FKEYS             (fkeys),
	.FREEZER_ACTIVATE  (freezer_activate),
	.PS2_KEYS          (ps2_keys),
	.PS2_KEYS_NEXT_OUT ()
);

// ------------------------------------------------------------------ joysticks
// MiSTer JOY bits: 0=right 1=left 2=down 3=up 4=fire 5=B 6=C.
// Karabas joy bits: 1=up 2=down 3=left 4=right 6=A 7=B 8=C.
// Karabas joystick bits (firmware/kg_l2_hid): 0 connected, 1 up, 2 down,
// 3 left, 4 right, 5 start, 6 A (fire), 7 B, 8 C, ...
// The Atari core wants JOY1_n/JOY2_n in FRLDU order, 0 = pressed:
// bit 4 fire, 3 right, 2 left, 1 down, 0 up.
wire [12:0] k1 = sw_joy_swap ? joy_r : joy_l;
wire [12:0] k2 = sw_joy_swap ? joy_l : joy_r;
wire [4:0] joy1_n = ~{k1[6], k1[4], k1[3], k1[2], k1[1]};
wire [4:0] joy2_n = ~{k2[6], k2[4], k2[3], k2[2], k2[1]};

// ------------------------------------------------------------------ atari800core
wire [7:0]  video_r, video_g, video_b;
wire        video_hs, video_vs, video_cs, video_blank, video_pixce;
wire        video_burst, video_sof, video_odd;
wire        core_hblank, core_vblank;
wire [15:0] core_audio_l, core_audio_r;

wire        sdram_req, sdram_complete, sdram_rd, sdram_wr, sdram_refresh;
wire [24:0] sdram_addr;
wire [31:0] sdram_di, sdram_do;
wire        sdram_8, sdram_16, sdram_32;

atari800core_simple_sdram #(
	.cycle_length  (16),
	.video_bits    (8),
	.palette       (1),
	.internal_rom  (1),
	.internal_ram  (0),
	.low_memory    (4)
) core (
	.CLK                    (clk),
	.RESET_N                (~reset),
	.POWER_RESET            (power_reset),

	.VIDEO_VS               (video_vs),
	.VIDEO_HS               (video_hs),
	.VIDEO_CS               (video_cs),
	.VIDEO_B                (video_b),
	.VIDEO_G                (video_g),
	.VIDEO_R                (video_r),
	.VIDEO_BLANK            (video_blank),
	.VIDEO_PIXCE            (video_pixce),
	.VIDEO_BURST            (video_burst),
	.VIDEO_START_OF_FIELD   (video_sof),
	.VIDEO_ODD_LINE         (video_odd),
	.interlace_field        (),
	.interlace              (),
	.interlace_enable       (1'b0),

	.HBLANK                 (core_hblank),
	.VBLANK                 (core_vblank),

	.POKEYMAX_CONFIG        (POKEY_CFG),
	.AUDIO_L                (core_audio_l),
	.AUDIO_R                (core_audio_r),

	.JOY1_n                 (joy1_n),
	.JOY2_n                 (joy2_n),
	.JOY3_n                 (5'b11111),
	.JOY4_n                 (5'b11111),
	.PADDLE0                (8'sh80),
	.PADDLE1                (8'sh80),
	.PADDLE2                (8'sh80),
	.PADDLE3                (8'sh80),
	.PADDLE4                (8'sh80),
	.PADDLE5                (8'sh80),
	.PADDLE6                (8'sh80),
	.PADDLE7                (8'sh80),

	.KEYBOARD_RESPONSE      (keyboard_response),
	.KEYBOARD_SCAN          (keyboard_scan),

	.SIO_COMMAND            (sio_command),
	.SIO_RXD                (sio_rxd),
	.SIO_TXD                (sio_txd),
	.SIO_CLOCK              (sio_clock),
	.SIO_CLOCK_IN           (1'b1),
	.SIO_PROC               (1'b1),
	.SIO_IRQ                (1'b1),
	.SIO_MOTOR              (sio_motor),
	.TAPE_AUDIO             (8'h00),
	.ENABLE_179_EARLY       (),
	.PORTA_OUT_EXP          (),

	.CONSOL_OPTION          (consol_option),
	.CONSOL_SELECT          (consol_select),
	.CONSOL_START           (consol_start),

	.SDRAM_REQUEST          (sdram_req),
	.SDRAM_REQUEST_COMPLETE (sdram_complete),
	.SDRAM_READ_ENABLE      (sdram_rd),
	.SDRAM_WRITE_ENABLE     (sdram_wr),
	.SDRAM_ADDR             (sdram_addr),
	.SDRAM_DO               (sdram_do),
	.SDRAM_DI               (sdram_di),
	.SDRAM_32BIT_WRITE_ENABLE (sdram_32),
	.SDRAM_16BIT_WRITE_ENABLE (sdram_16),
	.SDRAM_8BIT_WRITE_ENABLE  (sdram_8),
	.SDRAM_REFRESH          (sdram_refresh),

	.DMA_FETCH              (1'b0),
	.DMA_READ_ENABLE        (1'b0),
	.DMA_32BIT_WRITE_ENABLE (1'b0),
	.DMA_16BIT_WRITE_ENABLE (1'b0),
	.DMA_8BIT_WRITE_ENABLE  (1'b0),
	.DMA_ADDR               (26'd0),
	.DMA_WRITE_DATA         (32'd0),
	.MEMORY_READY_DMA       (),
	.DMA_MEMORY_DATA        (),

	.RAM_SELECT             (ram_sel),
	.PAL                    (pal),
	.CLIP_SIDES             (clip_sides),
	.GTIA_XCOLOR            (gtia_xcolor),
	.RESET_RNMI             (1'b0),
	.ATARI800MODE           (1'b0),
	.ATARI800MODE_16K       (1'b0),
	.PBI_ROM_MODE           (1'b0),
	.XEX_LOADER_MODE        (1'b0),
	.RTC                    (65'd0),
	.CLK_CONF               (3'd0),
	.VBXE_SWITCH            (1'b0),
	.VBXE_REG_BASE          (1'b0),
	.VBXE_VER_127           (1'b0),
	.VBXE_TURBO             (1'b0),
	.VBXE_PALETTE_RGB       (3'd0),
	.VBXE_PALETTE_INDEX     (8'd0),
	.VBXE_PALETTE_COLOR     (7'd0),

	.HALT                   (pause),
	// MiSTer CPU_SPEEDS = {1, 2, 4, 8, 16, ...} for 1x/2x/4x/8x/16x.
	// This is a multiplier bitmask, not cycle_length-1.  6'd15 selects 8x
	// turbo and breaks the raster/page-flip timing used by Numen's Duke engine.
	.THROTTLE_COUNT_6502    (6'd1),
	.emulated_cartridge_select  (cart_sel),
	.emulated_cartridge2_select (8'd0),
	.EMU_FLASH_REQUEST      (),
	.EMU_FLASH_SLAVE        (),
	.freezer_enable         (1'b0),
	.freezer_activate       (1'b0)
);

// ------------------------------------------------------------------ SRAM
atari_sram sram (
	.clk      (clk),
	.reset    (reset_host),
	.req      (sdram_req),
	.addr     (sdram_addr),
	.wdata    (sdram_di),
	.we       (sdram_wr),
	.b8       (sdram_8),
	.b16      (sdram_16),
	.b32      (sdram_32),
	.rdata    (sdram_do),
	.complete (sdram_complete),
	.ld_req   (ld_req),
	.ld_addr  (ld_addr),
	.ld_data  (ld_data),
	.cold_clear (cold_clear),
	.dsk_req  (dsk_req),
	.dsk_addr (dsk_addr),
	.dsk_data (dsk_data),
	.dsk_ack  (dsk_ack),
	.dbg_defer(dbg_defer),
	.MA       (MA),
	.MD       (MD),
	.MWR_N    (MWR_N),
	.MRD_N    (MRD_N)
);

// ------------------------------------------------------------------ video
generate
if (VIDEO27) begin : video27
	atari_video_27 #(
		.H_SYNC_START (HS_START),
		.H_SYNC_END   (HS_END)
	) video (
		.clk      (clk),
		.clk_vid  (clk_vid),
		.rst      (reset_host),
		.pixce    (video_pixce),
		.r_i      (video_r),
		.g_i      (video_g),
		.b_i      (video_b),
		.hblank   (core_hblank),
		.vblank   (core_vblank),
		.hsync_i  (video_hs),
		.vsync_i  (video_vs),
		.pal      (pal),
		.r_o      (rgb[23:16]),
		.g_o      (rgb[15:8]),
		.b_o      (rgb[7:0]),
		.hs_o     (hs),
		.vs_o     (vs),
		.de_o     (de)
	);
end else begin : video28
	atari_video #(
		.HS_START (HS_START),
		.HS_END   (HS_END)
	) video (
		.clk      (clk),
		.rst      (reset),
		.pixce    (video_pixce),
		.r_i      (video_r),
		.g_i      (video_g),
		.b_i      (video_b),
		.hblank   (core_hblank),
		.vblank   (core_vblank),
		.hsync_i  (video_hs),
		.vsync_i  (video_vs),
		.pal      (pal),
		.r_o      (rgb[23:16]),
		.g_o      (rgb[15:8]),
		.b_o      (rgb[7:0]),
		.hs_o     (hs),
		.vs_o     (vs),
		.de_o     (de)
	);
end
endgenerate

// ------------------------------------------------------------------ audio
// The POKEY/GTIA output is two's complement 16 bit.  Remove the DC component in the unsigned domain
// (as in the Karabas C64 core) and output 18 bit signed for the 48 kHz sampler of the board wrapper.
wire signed [17:0] aud_raw_l = {{2{core_audio_l[15]}}, core_audio_l};
wire signed [17:0] aud_raw_r = {{2{core_audio_r[15]}}, core_audio_r};
reg  signed [19:0] aud_dc_l = 20'sd0;
reg  signed [19:0] aud_dc_r = 20'sd0;
reg  signed [19:0] aud_ac_l = 20'sd0;
reg  signed [19:0] aud_ac_r = 20'sd0;
wire signed [19:0] aud_ext_l = {{2{aud_raw_l[17]}}, aud_raw_l};
wire signed [19:0] aud_ext_r = {{2{aud_raw_r[17]}}, aud_raw_r};

always @(posedge clk) begin
	if (reset) begin
		aud_dc_l <= 20'sd0;
		aud_dc_r <= 20'sd0;
		aud_ac_l <= 20'sd0;
		aud_ac_r <= 20'sd0;
	end
	else begin
		aud_dc_l <= aud_dc_l + ((aud_ext_l - aud_dc_l) >>> 18);
		aud_dc_r <= aud_dc_r + ((aud_ext_r - aud_dc_r) >>> 18);
		aud_ac_l <= aud_ext_l - aud_dc_l;
		aud_ac_r <= aud_ext_r - aud_dc_r;
	end
end

assign audio_l = aud_ac_l[17:0];
assign audio_r = aud_ac_r[17:0];

endmodule
`default_nettype wire

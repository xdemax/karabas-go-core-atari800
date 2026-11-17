module karabas_mini_top (
	//------------------ global clock --------
	input wire 				CLK_50MHZ,

	//------------------ esp8266 uart --------
	inout wire 				ESP_RESET_N,
	inout wire 				ESP_BOOT_N,
	inout wire 				UART_RX,
	inout wire 				UART_TX,
	inout wire 				UART_CTS,

	//------------------ sram ----------------
	output wire [20:0] 	MA,
	inout wire [15:0] 	MD,
	output wire [1:0] 	MWR_N,
	output wire [1:0] 	MRD_N,

	//------------------ sdram ---------------
	output wire [1:0] 	SDR_BA,
	output wire [12:0] 	SDR_A,
	output wire 			SDR_CLK,
	output wire [1:0] 	SDR_DQM,
	output wire 			SDR_WE_N,
	output wire 			SDR_CAS_N,
	output wire 			SDR_RAS_N,
	inout wire [15:0] 	SDR_DQ,

	//------------------ sd2 -----------------
	output wire 			SD_CS_N,
	output wire 			SD_CLK,
	inout wire 				SD_DI,
	inout wire 				SD_DO,
	input wire 				SD_DET_N,

	//------------------ ft812 rgb + sync ----
	input wire [7:0] 		VGA_R,
	input wire [7:0] 		VGA_G,
	input wire [7:0] 		VGA_B,
	input wire 				VGA_HS,
	input wire 				VGA_VS,

	//------------------ dvi / hdmi ----------
	output wire [3:0] 	TMDS_P,
	output wire [3:0] 	TMDS_N,

	//------------------ ft812 spi and ctl ---
	inout wire 				FT_SPI_CS_N,
	inout wire 				FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	inout wire 				FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	input wire 				FT_AUDIO,
	input wire 				FT_DE,
	input wire 				FT_DISP,
	output wire 			FT_RESET,
	output wire 			FT_CLK_OUT,

	//------------------ cf card -------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//------------------ analog in/out -------
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,

	//------------------ sigma-delta audio ---
	output wire          AUDIO_L,
	output wire          AUDIO_R,

	//------------------ adc -----------------
	output wire 			ADC_CLK,
	inout wire 				ADC_BCK,
	inout wire 				ADC_LRCK,
	input wire 				ADC_DOUT,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	input wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	inout wire [3:0] 		MCU_IO,  // [0] burst cs_n (input), [1] MCU_INT, [2] sd2 cs_n, [3] ft cs_n

	//------------------ midi ----------------
	output wire 			MIDI_TX,
	output wire 			MIDI_CLK,
	output wire 			MIDI_RESET_N,

	//------------------ optional flash ------
	output wire 			FLASH_CS_N,
	input wire  			FLASH_DO,
	output wire 			FLASH_DI,
	output wire 			FLASH_SCK,
	output wire 			FLASH_WP_N,
	output wire 			FLASH_HOLD_N
);

// unused
assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;
assign SD_DI = 1'bz;
assign SD_DO = 1'bz;
assign WA = 3'd0;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b0;
assign WD = 16'hzzzz;
assign TAPE_OUT = 1'b0;
assign UART_CTS = 1'bz;
assign MIDI_TX = 1'b1;
assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FT_RESET = 1'b1;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;
assign SDR_A = 13'd0;
assign SDR_CLK = 1'b0;
assign SDR_BA = 2'd0;
assign SDR_DQM = 2'b11;
assign SDR_WE_N = 1'b1;
assign SDR_CAS_N = 1'b1;
assign SDR_RAS_N = 1'b1;
assign SDR_DQ = 16'hzzzz;

// ------------------------------------------------------------------ clocks
// VCO 800 MHz (50 * 16).  CLKOUT1 = 28.571 MHz is left raw for the DCM of the HDMI transmitter; the machine
// and the video use it through clk_vid.  CLKOUT3 = 25 MHz MCU.  The FT812 is not used by this core.
wire [5:0] pll_clk;
wire locked;
kg_pll #(
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(16),
	.CLKOUT0_DIVIDE(28),
	.CLKOUT1_DIVIDE(28),
	.CLKOUT2_DIVIDE(100),
	.CLKOUT3_DIVIDE(32),
	.CLKOUT4_DIVIDE(28),
	.BUFG_MASK(6'b001100)
) pll (
	.clk_in		(CLK_50MHZ),
	.rst			(1'b0),
	.clk_out		(pll_clk),
	.locked		(locked)
);
wire clk_vid_pll = pll_clk[1];
wire clk_vid;
BUFG bufg_clk_vid(.I(clk_vid_pll), .O(clk_vid));
wire clk_sys = clk_vid;          // one clock domain: machine, video and OSD
wire clk_host = pll_clk[3];
wire clk_8mhz = pll_clk[2];
wire areset = ~locked;

// The FT812 is not used, but its clock pin must always carry ~8 MHz.
ODDR2 u_ft_clk(.Q(FT_CLK_OUT), .C0(clk_8mhz), .C1(~clk_8mhz), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));
// Keep the FT SPI idle.
assign FT_SPI_CS_N = 1'b1;
assign FT_SPI_SCK = 1'b0;
assign FT_SPI_MOSI = 1'b1;

// ------------------------------------------------------------------ MCU link v2
wire [39:0] sw;                    // SYS switches, switch n = sw[n*8 +: 8]
wire [5:0] btns;
wire mcu_busy;
wire dvi_only;
wire mcu_int;
wire matrix_cmd_wr;
wire [23:0] matrix_cmd;

// HID: PS/2 set 2 bytes and the joysticks
wire [7:0] ps2_code;
wire ps2_kind, ps2_wr;
reg  ps2_upd_tgl = 1'b0;
always @(posedge clk_host)
	if (ps2_wr && !ps2_kind) ps2_upd_tgl <= ~ps2_upd_tgl;
wire [7:0] kb_scancode = ps2_code;
wire kb_scancode_upd = ps2_upd_tgl;
wire [15:0] joy_l16, joy_r16;
wire [12:0] joy_l = joy_l16[12:0];
wire [12:0] joy_r = joy_r16[12:0];

// LOAD: the file loader is not connected yet; keep the bus idle
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_size, ld_addr;
wire ld_start, ld_active, ld_end, ld_wr;

// OSD: the bitmap of kg_l2_osd, drawn by kg_l2_osd_overlay in clk_vid
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

// MCU_SCK on a global buffer on the Mini G
// Mini rev A-F: MCU_SCK is not on a clock pin; kg_mcu2 takes it directly.
wire mcu_sck = MCU_SCK;

assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[3:2] = 2'bzz;

kg_mcu2 #(
	.CAPS(16'h0000),
	.SW_N(5),
	.SW_INIT(40'h0000000000),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_FT(0),
	.ENABLE_SD2(0),
	.ENABLE_AUX(1)
) mcu(
	.CLK				(clk_host),
	.N_RESET			(locked),

	.MCU_SCK			(mcu_sck),
	.MCU_MOSI		(MCU_MOSI),
	.MCU_MISO		(MCU_MISO),
	.MCU_SS			(MCU_CS_N),
	.MCU_INT			(mcu_int),
	.MCU_SPI_FT_SS	(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),

	.SW				(sw),
	.SW_WR			(),
	.SW_INDEX		(),
	.SW_VALUE		(),
	.HW_ID			(),
	.DVI_ONLY		(dvi_only),
	.CORE_BUILD		(),
	.FW_BUILD		(),
	.BUSY				(mcu_busy),
	.BTNS				(btns),
	.RELOAD_REQ		(1'b0),
	.RELOAD_CORE	(8'd0),

	.KBD				(),
	.KBD_WR			(),
	.PS2_CODE		(ps2_code),
	.PS2_KIND		(ps2_kind),
	.PS2_WR			(ps2_wr),
	.MS_X				(),
	.MS_Y				(),
	.MS_Z				(),
	.MS_B				(),
	.MS_WR			(),
	.JOY_L			(joy_l16),
	.JOY_R			(joy_r16),
	.JOY_WR			(),
	.PS2_CMD			(16'd0),
	.PS2_CMD_WR		(1'b0),

	.LD_KIND			(ld_kind),
	.LD_SLOT			(ld_slot),
	.LD_SIZE			(ld_size),
	.LD_START		(ld_start),
	.LD_ACTIVE		(ld_active),
	.LD_END			(ld_end),
	.LD_ADDR			(ld_addr),
	.LD_DATA			(ld_data),
	.LD_WR			(ld_wr),
	.LD_READY		(1'b1),

	.OSD_WR			(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG			(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW			(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(), .SDC_IMG_SIZE(),
	.SDC_RD			(8'd0), .SDC_WR(8'd0), .SDC_SECTOR(32'd0),
	.SDC_BUSY		(), .SDC_DONE(), .SDC_ERROR(), .SDC_SLOT(),
	.SDC_BYTE_IN_STROBE(), .SDC_BYTE_ADDR(), .SDC_BYTE_IN_DATA(), .SDC_BYTE_OUT_DATA(8'd0),
	.IMG_WP			(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(),
	.FDD_CHNG_WR	(), .FDD_CHNG(), .FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
	.IMG_ACTIVE		(),
	.BK_MOUNT		(1'b0), .BK_FLUSHED(1'b0), .BK_SLOT(3'd0), .BK_SIZE(32'd0),
	.BK_KIND			(8'd0), .BK_RESULT(8'd0),

	.PORT_OUT_DATA	(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0),
	.PORT_IN_DATA	(32'd0), .PORT_IN_WR(4'd0), .PORT_CFG(128'd0), .PORT_IN_FULL(),
	.PORT_STAT		(), .PORT_STAT_WR(),

	.RTC_A			(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .RTC_DO(),
	.MATRIX_CMD		(matrix_cmd), .MATRIX_CMD_WR(matrix_cmd_wr),
	.DEBUG_ADDR		(16'd0), .DEBUG_DATA(16'd0),

	.FT_SPI_ON		(), .FT_VGA_ON(), .FT_RESET(),
	.FT_SCK			(), .FT_MOSI(), .FT_CS_N(), .FT_MISO(1'b1),
	.SD2_SCK			(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// ------------------------------------------------------------------ OSD switches
reg [39:0] sw_s1 = 40'd0, sw_s2 = 40'd0, sw_v = 40'd0;
always @(posedge clk_sys) begin
	sw_s1 <= sw;
	sw_s2 <= sw_s1;
	if (sw_s1 == sw_s2) sw_v <= sw_s2;
end

wire [2:0] ram_sel  = sw_v[10:8];
wire       pal      = ~sw_v[16];
wire       joy_swap = sw_v[24];
wire [3:0] cart_opt = sw_v[35:32];

reg [7:0] cart_sel;
always @(*) begin
	case (cart_opt)
		4'd0: cart_sel = 8'h00;
		4'd1: cart_sel = 8'h01;
		4'd2: cart_sel = 8'h21;
		4'd3: cart_sel = 8'h29;
		4'd4: cart_sel = 8'h0D;
		4'd5: cart_sel = 8'h0C;
		4'd6: cart_sel = 8'h30;
		4'd7: cart_sel = 8'h31;
		4'd8: cart_sel = 8'h32;
		4'd9: cart_sel = 8'h2C;
		default: cart_sel = 8'h01;
	endcase
end

reg sw0_d = 1'b0;
reg [20:0] sw_reset_cnt = 21'd0;
always @(posedge clk_sys) begin
	sw0_d <= sw_v[0];
	if (sw_v[0] && !sw0_d)
		sw_reset_cnt <= 21'h1FFFFF;
	else if (sw_reset_cnt != 21'd0)
		sw_reset_cnt <= sw_reset_cnt - 21'd1;
end
wire sw_reset = |sw_reset_cnt;

wire        ld_req = 1'b0;
wire [24:0] ld_addr_sram = 25'd0;
wire [7:0]  ld_data_sram = 8'd0;
wire        ld_loading = 1'b0;
wire machine_reset = areset | sw_reset | ld_loading;

// ------------------------------------------------------------------ machine
wire [23:0] vid_rgb, osd_rgb;
wire        vid_hs, vid_vs, vid_de;
wire        osd_hs, osd_vs, osd_de;
wire signed [17:0] aud_l, aud_r;

atari800_machine machine (
	.clk            (clk_sys),
	.clk_vid        (clk_sys),
	.reset          (machine_reset),
	.reset_host     (areset),
	.pause          (1'b0),
	.kb_scancode    (kb_scancode),
	.kb_scancode_upd(kb_scancode_upd),
	.joy_l          (joy_l),
	.joy_r          (joy_r),
	.sw_joy_swap    (joy_swap),
	.ram_sel        (ram_sel),
	.cart_sel       (cart_sel),
	.pal            (pal),
	.clip_sides     (1'b0),
	.gtia_xcolor    (1'b0),
	.ld_req         (ld_req),
	.ld_addr        (ld_addr_sram),
	.ld_data        (ld_data_sram),
	.rgb            (vid_rgb),
	.hs             (vid_hs),
	.vs             (vid_vs),
	.de             (vid_de),
	.audio_l        (aud_l),
	.audio_r        (aud_r),
	.MA             (MA),
	.MD             (MD),
	.MWR_N          (MWR_N),
	.MRD_N          (MRD_N)
);

// The bitmap OSD of link v2 (kg_l2_osd_overlay): the settings cross from clk_host
// internally; the picture is centred in the active area (scale 2 at 720 x 576).
kg_l2_osd_overlay overlay(
	.wclk			(clk_host),
	.osd_wr		(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg		(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw		(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on		(8'd0), .icon_act(8'd0),
	.clk			(clk_vid),
	.rgb_i		(vid_rgb), .hs_i(vid_hs), .vs_i(vid_vs), .de_i(vid_de),
	.rgb_o		(osd_rgb), .hs_o(osd_hs), .vs_o(osd_vs), .de_o(osd_de)
);

// ------------------------------------------------------------------ audio sampler
// Audio sample: 48 kHz strobe, held for the sigma-delta DACs and HDMI sampler.
reg [8:0] aud_acc = 9'd0;
reg [31:0] aud_hold = 32'd0;
always @(posedge clk_sys) begin
	if (aud_acc == 9'd511) begin
		aud_acc <= 9'd0;
		aud_hold <= {aud_l[17], aud_l[17:3], aud_r[17], aud_r[17:3]};
	end
	else
		aud_acc <= aud_acc + 9'd1;
end

audio_peaks #(.PERIOD_BITS(19)) matrix_peaks(
	.clk      (clk_host),
	.audio_l  (aud_hold[31:16]),
	.audio_r  (aud_hold[15:0]),
	.cmd_wr   (matrix_cmd_wr),
	.cmd      (matrix_cmd)
);

// ------------------------------------------------------------------ HDMI (no FT812, stable DCM path)
atari_hdmi #(.SAMPLERATE(48000), .CLKRATE(28571400), .INPUT_REG(1)) hdmi (
	.clk      (clk_vid),
	.reset    (areset),
	.rgb      (osd_rgb),
	.hs       (osd_hs),
	.vs       (osd_vs),
	.de       (osd_de),
	.audio_en (1'b1),        // force HDMI audio for bring-up; dvi_only was muting it
	.audio_l  (aud_hold[31:16]),
	.audio_r  (aud_hold[15:0]),
	.tmds_p   (TMDS_P),
	.tmds_n   (TMDS_N)
);

// ------------------------------------------------------------------ sigma-delta audio (Mini rev A-F)
// The 48 kHz sample is already held on clk_sys; offset binary for the first-order DAC.
kg_sigma_delta_dac dac_l (
	.clk		(clk_sys),
	.reset	(areset),
	.din		({~aud_hold[31], aud_hold[30:16]}),
	.dout		(AUDIO_L)
);
kg_sigma_delta_dac dac_r (
	.clk		(clk_sys),
	.reset	(areset),
	.din		({~aud_hold[15], aud_hold[14:0]}),
	.dout		(AUDIO_R)
);

endmodule
`default_nettype wire

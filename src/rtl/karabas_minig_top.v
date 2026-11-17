`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Atari 800XL for Karabas Mini G (XC6SLX25, HDMI through zhdmi, PCM5102 I2S DAC).
--
-- The machine and the video run on one 28.571 MHz clock (PLL output 1, buffered).  The raw PLL output goes to
-- kg_hdmi_ft, whose pixel clock is that same clock through its BUFGMUX; this is the clocking of the C64 Mini G
-- wrapper.  VCO 800 MHz: 28.571 MHz core/pixel, 25 MHz MCU, 8 MHz FT812.
--
-------------------------------------------------------------------------------------------------------------------*/

module karabas_minig_top (
	//------------------ global clock --------
	input wire 				CLK_50MHZ,

	//------------------ esp8266 uart --------
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
	input wire 				FT_DE,
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

	//------------------ i2s dac -------------
	output wire          DAC_BCK,
	output wire          DAC_WS,
	output wire          DAC_DAT,

	//------------------ adc -----------------
	output wire 			ADC_CLK,
	inout wire 				ADC_BCK,
	inout wire 				ADC_LRCK,
	input wire 				ADC_DOUT,

	//------------------ esp32 i2s and cs ----
	inout wire           ESP32_SPI_CS_N,
	input wire           ESP32_PCM_BCK,
	input wire           ESP32_PCM_RLCK,
	input wire           ESP32_PCM_DAT,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	input wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	inout wire [5:0] 		MCU_IO,

	//------------------ midi ----------------
	output wire 			MIDI_TX,

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
assign ESP32_SPI_CS_N = 1'b1;
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
wire [47:0] sw;                    // SYS switches, switch n = sw[n*8 +: 8]
wire [5:0] btns;
wire mcu_busy;
wire dvi_only;
wire mcu_int;
wire matrix_cmd_wr;
wire [23:0] matrix_cmd;

// HID: PS/2 set 2 bytes and the joysticks
wire [7:0] ps2_code;
wire ps2_kind, ps2_wr;

// The firmware sends every byte of a key (E0 / F0 prefixes, typematic) as a
// burst, one 25 MHz strobe per byte.  A bare toggle in clk_host is a CDC race:
// the machine can sample the toggle after ps2_code has already advanced to
// the next byte, and consecutive 40 ns strobes can alias.  Queue the set-2
// bytes and pop them in clk_sys, so the code and the strobe change together.
wire [7:0] ps2_dout;
wire       ps2_empty, ps2_full;
reg        ps2_rd = 1'b0;
reg  [1:0] ps2_state = 2'd0;          // 0 idle, 1 pop, 2 capture
reg  [7:0] kb_scancode_r = 8'd0;
reg        kb_upd_tgl = 1'b0;

kg_async_fifo #(.DW(8), .AW(4)) ps2_fifo (
	.wclk   (clk_host),
	.wreset (areset),
	.wr     (ps2_wr && !ps2_kind),
	.din    (ps2_code),
	.full   (ps2_full),
	.rclk   (clk_sys),
	.rreset (areset),
	.rd     (ps2_rd),
	.dout   (ps2_dout),
	.empty  (ps2_empty),
	.rcount ()
);

always @(posedge clk_sys) begin
	ps2_rd <= 1'b0;
	if (areset) begin
		ps2_state <= 2'd0;
		kb_scancode_r <= 8'd0;
		kb_upd_tgl <= 1'b0;
	end
	else begin
		case (ps2_state)
			2'd0: if (!ps2_empty) begin
				ps2_rd <= 1'b1;      // dout becomes valid next cycle
				ps2_state <= 2'd1;
			end
			2'd1: ps2_state <= 2'd2; // dout valid now
			2'd2: begin
				kb_scancode_r <= ps2_dout;
				kb_upd_tgl <= ~kb_upd_tgl;
				ps2_state <= 2'd0;
			end
		endcase
	end
end

wire [7:0] kb_scancode = kb_scancode_r;
wire kb_scancode_upd = kb_upd_tgl;
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
wire mcu_sck_ibufg, mcu_sck;
IBUFG ibufg_mcu_sck(.I(MCU_SCK), .O(mcu_sck_ibufg));
BUFG bufg_mcu_sck(.I(mcu_sck_ibufg), .O(mcu_sck));

assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[5:2] = 4'bzzzz;

wire [7:0]  sdc_img_mounted;
wire [63:0] sdc_img_size;
wire [7:0]  sdc_rd;
wire [31:0] sdc_sector;
wire        sdc_busy, sdc_done, sdc_error;
wire [2:0]  sdc_slot;
wire        sdc_byte_strobe;
wire [8:0]  sdc_byte_addr;
wire [7:0]  sdc_byte_in_data;

wire        ld_req;
wire [24:0] ld_addr_sram;
wire [7:0]  ld_data_sram;
wire        atr_ld_req;
wire [24:0] atr_ld_addr;
wire [7:0]  atr_ld_data;
wire        xex_ld_req;
wire [24:0] xex_ld_addr;
wire [7:0]  xex_ld_data;
wire        ld_loading;
wire [15:0] atr_ssize;
wire [31:0] atr_scount;
wire        atr_ready;
wire        xex_mode, xex_busy, xex_done, xex_start, xex_reset;
wire [4:0]  xex_state;
wire [15:0] xex_boot_ssize;
wire [31:0] xex_boot_scount;
wire        xex_rd_req;
wire [24:0] xex_rd_addr;

wire        sio_command, sio_rxd, sio_txd, sio_clock, sio_motor;
wire        dsk_req;
wire [24:0] dsk_addr;
wire [7:0]  dsk_data;
wire        dsk_ack;
wire        sio_dsk_req;
wire [24:0] sio_dsk_addr;
wire [15:0] sio_ssize;
wire [31:0] sio_scount;
wire        sio_ready;
wire [7:0]  dbg_defer;
wire [7:0]  dbg_cmd_cnt, dbg_last_code, dbg_ack_cnt, dbg_tx_cnt, dbg_rx_byte;
wire [7:0]  dbg_cmd_edges, dbg_bad_frames, dbg_flags;
wire [39:0] dbg_last_frame;
wire [63:0] dbg_data8;
wire [7:0]  dbg_sum, dbg_code;
wire [15:0] dbg_sector;
wire [24:0] dbg_base;
wire [31:0] dbg_nsec;
wire [24:0] dbg_waddr;
reg  [7:0]  dbg_mcu_byte = 8'd0;
reg  [7:0]  dbg_ld_byte = 8'd0;
reg  [7:0]  dbg_cap_cnt = 8'd0;
always @(posedge clk_host)
	if (sdc_byte_strobe && sdc_sector == 32'd181 && sdc_byte_addr == 9'd144)
		dbg_mcu_byte <= sdc_byte_in_data;
always @(posedge clk_sys)
	if (ld_req && ld_addr_sram == 25'h316A90) begin
		dbg_ld_byte <= ld_data_sram;
		dbg_cap_cnt <= dbg_cap_cnt + 8'd1;
	end
reg [7:0] dbg_mcu_byte_sys = 8'd0;
reg [7:0] dbg_sdc_cnt = 8'd0;
always @(posedge clk_sys)
	if (sdc_byte_strobe && sdc_sector == 32'd181 && sdc_byte_addr == 9'd144) begin
		dbg_mcu_byte_sys <= sdc_byte_in_data;
		dbg_sdc_cnt <= dbg_sdc_cnt + 8'd1;
	end
wire [15:0] dbg_addr, dbg_data;

kg_mcu2 #(
	.CAPS(16'h0000),
	.SW_N(6),
	.SW_INIT(48'h000000000000),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),
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
	.MCU_SPI_SD2_SS(1'b1),

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

	.SDC_IMG_MOUNTED(sdc_img_mounted), .SDC_IMG_SIZE(sdc_img_size),
	.SDC_RD			(sdc_rd), .SDC_WR(8'd0), .SDC_SECTOR(sdc_sector),
	.SDC_BUSY		(sdc_busy), .SDC_DONE(sdc_done), .SDC_ERROR(sdc_error), .SDC_SLOT(sdc_slot),
	.SDC_BYTE_IN_STROBE(sdc_byte_strobe), .SDC_BYTE_ADDR(sdc_byte_addr), .SDC_BYTE_IN_DATA(sdc_byte_in_data), .SDC_BYTE_OUT_DATA(8'd0),
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
	.DEBUG_ADDR		(dbg_addr), .DEBUG_DATA(dbg_data),

	.FT_SPI_ON		(), .FT_VGA_ON(), .FT_RESET(),
	.FT_SCK			(), .FT_MOSI(), .FT_CS_N(), .FT_MISO(1'b1),
	.SD2_SCK			(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

// ------------------------------------------------------------------ OSD switches
reg [47:0] sw_s1 = 48'd0, sw_s2 = 48'd0, sw_v = 48'd0;
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

reg sw5_d = 1'b0;
reg [20:0] cold_reset_cnt = 21'd0;
always @(posedge clk_sys) begin
	sw5_d <= sw_v[5];
	if (sw_v[5] && !sw5_d)
		cold_reset_cnt <= 21'h1FFFFF;
	else if (cold_reset_cnt != 21'd0)
		cold_reset_cnt <= cold_reset_cnt - 21'd1;
end
wire cold_reset = |cold_reset_cnt;

wire any_reset   = areset | sw_reset | cold_reset | ld_loading; // RESET_N
wire power_reset = areset | cold_reset | ld_loading;            // POWER_RESET (cold)

// ------------------------------------------------------------------ ATR image loader
// Slot 1 is the .atr.  The image is copied into the free SRAM at 0x300000;
// the machine is held in reset while it is loading.
atari_atr_loader atr_loader (
	.clk_host       (clk_host),
	.clk            (clk_sys),
	.reset_host     (areset),
	.img_mounted    (sdc_img_mounted),
	.img_size       (sdc_img_size),
	.sdc_rd         (sdc_rd),
	.sdc_sector     (sdc_sector),
	.sdc_busy       (sdc_busy),
	.sdc_done       (sdc_done),
	.sdc_error      (sdc_error),
	.sdc_slot       (sdc_slot),
	.sdc_byte_strobe(sdc_byte_strobe),
	.sdc_byte_addr  (sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data),
	.ld_req         (atr_ld_req),
	.ld_addr        (atr_ld_addr),
	.ld_data        (atr_ld_data),
	.atr_ssize      (atr_ssize),
	.atr_scount     (atr_scount),
	.atr_ready      (atr_ready),
	.loading        (ld_loading),
	.xex_mode       (xex_mode),
	.dbg_nsec       (dbg_nsec),
	.dbg_waddr      (dbg_waddr)
);

// ------------------------------------------------------------------ machine
wire [23:0] vid_rgb, osd_rgb;
wire        vid_hs, vid_vs, vid_de;
wire        osd_hs, osd_vs, osd_de;
wire signed [17:0] aud_l, aud_r;

atari800_machine machine (
	.clk            (clk_sys),
	.clk_vid        (clk_sys),
	.reset          (any_reset),
	.power_reset    (power_reset),
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
	.sio_command    (sio_command),
	.sio_rxd        (sio_rxd),
	.sio_txd        (sio_txd),
	.sio_clock      (sio_clock),
	.sio_motor      (sio_motor),
	.dsk_req        (dsk_req),
	.dsk_addr       (dsk_addr),
	.dsk_data       (dsk_data),
	.dsk_ack        (dsk_ack),
	.dbg_defer      (dbg_defer),
	.MA             (MA),
	.MD             (MD),
	.MWR_N          (MWR_N),
	.MRD_N          (MRD_N)
);

// ------------------------------------------------------------------ raw XEX loading
// The FPGA-side DMA parser (xex_dma_loader.v) cannot run before the OS boot:
// the Altirra coldstart clears RAM from $0008 to the top ($EF1F..$EF31), so a
// segment DMA'ed before the boot is wiped and the stub jumps into zeros.
// For now a raw .xex uses the proven synthetic-ATR path: atari_atr_loader
// writes the 4-sector 6502 loader and the XEX to SRAM, and the loader runs
// after the coldstart and pulls the file through SIO.  The DMA parser stays
// in the tree for the later post-boot (stub-triggered) design.
assign xex_busy   = 1'b0;
assign xex_done   = 1'b0;
assign xex_rd_req = 1'b0;
assign xex_state  = 5'd0;

assign ld_req       = atr_ld_req;
assign ld_addr_sram = atr_ld_addr;
assign ld_data_sram = atr_ld_data;

assign dsk_req  = sio_dsk_req;
assign dsk_addr = sio_dsk_addr;
assign sio_ready = atr_ready;
assign sio_ssize = atr_ssize;
assign sio_scount= atr_scount;

// ------------------------------------------------------------------ 1050 SIO disk
atari_sio_disk sio_disk (
	.clk            (clk_sys),
	.reset          (any_reset),
	.atr_ssize      (sio_ssize),
	.atr_scount     (sio_scount),
	.atr_ready      (sio_ready),
	.sio_command    (sio_command),
	.sio_txd        (sio_txd),
	.sio_clock      (sio_clock),
	.sio_rxd        (sio_rxd),
	.dsk_req        (sio_dsk_req),
	.dsk_addr       (sio_dsk_addr),
	.dsk_data       (dsk_data),
	.dsk_ack        (dsk_ack),
	.dbg_cmd_cnt    (dbg_cmd_cnt),
	.dbg_last_code  (dbg_last_code),
	.dbg_ack_cnt    (dbg_ack_cnt),
	.dbg_tx_cnt     (dbg_tx_cnt),
	.dbg_rx_byte    (dbg_rx_byte),
	.dbg_cmd_edges  (dbg_cmd_edges),
	.dbg_bad_frames (dbg_bad_frames),
	.dbg_flags      (dbg_flags),
	.dbg_last_frame (dbg_last_frame),
	.dbg_data8      (dbg_data8),
	.dbg_sum        (dbg_sum),
	.dbg_sector     (dbg_sector),
	.dbg_code       (dbg_code),
	.dbg_base       (dbg_base)
);

// AUX DEBUG words for AT+KARABAS=debug:1 (addresses 0..8, ~0.17 s each):
//   0: {last command code, valid command frames}
//   1: {responses completed, ACKs}
//   2: {6'b0, atr_ready, loading, rx bytes}
//   3: atr_scount
//   4: atr_ssize (byte 16)
//   5: {deferred core reqs, flags: atr_ready,sclk,txd,cmd,sclk_ok,seen_txd,seen_cmd,seen_clk}
//   6..8: last raw command frame (5 bytes)
//   9..10: SRAM byte address of the last response (base)
//   11..12: last dsk_addr
//   13: last dsk_data
//   14: last R sector  15: last command code
//   16..17: atr_nsec (512-byte file sectors)
//   18..19: atr_waddr   20..21: sdc_sector
//   22: mcu byte (clk_host)   23: ld_data at 0x316A90   24: its capture count
//   25: mcu byte (clk_sys), LBA 181 / byte 144   26: its capture count
//   27..30: first 8 data bytes of the last 1050 response   31: its checksum
reg [7:0] d_cmd, d_last, d_ack, d_tx, d_rx;
reg [7:0] d_cedges, d_bad, d_flags, d_defer;
reg [39:0] d_frame;
reg [63:0] d_data8;
reg [7:0]  d_sum, d_code;
reg [15:0] d_sector;
reg [24:0] d_base, d_dsk_addr;
reg [7:0]  d_dsk_data;
reg [15:0] d_ssize;
reg [31:0] d_nsec, d_ld_sector;
reg [24:0] d_waddr;
reg [7:0]  d_mcu_byte, d_ld_byte, d_cap_cnt;
reg [7:0]  d_mcu_byte_sys, d_sdc_cnt;
always @(posedge clk_host) begin
	d_cmd   <= dbg_cmd_cnt;
	d_last  <= dbg_last_code;
	d_ack   <= dbg_ack_cnt;
	d_tx    <= dbg_tx_cnt;
	d_rx    <= dbg_rx_byte;
	d_cedges<= dbg_cmd_edges;
	d_bad   <= dbg_bad_frames;
	d_flags <= dbg_flags;
	d_defer <= dbg_defer;
	d_frame <= dbg_last_frame;
	d_data8 <= dbg_data8;
	d_sum   <= dbg_sum;
	d_sector<= dbg_sector;
	d_code  <= dbg_code;
	d_base  <= dbg_base;
	d_dsk_addr <= dsk_addr;
	d_dsk_data <= dsk_data;
	d_ssize <= atr_ssize;
	d_nsec  <= dbg_nsec;
	d_waddr <= dbg_waddr;
	d_ld_sector <= sdc_sector;
	d_mcu_byte <= dbg_mcu_byte;
	d_ld_byte  <= dbg_ld_byte;
	d_cap_cnt  <= dbg_cap_cnt;
	d_mcu_byte_sys <= dbg_mcu_byte_sys;
	d_sdc_cnt  <= dbg_sdc_cnt;
end
reg [25:0] dbg_div = 26'd0;
always @(posedge clk_host)
	dbg_div <= dbg_div + 26'd1;
wire [4:0] dbg_sel = dbg_div[25:21];
wire [15:0] dbg_w0 = {d_last, d_cmd};
wire [15:0] dbg_w1 = {d_tx, d_ack};
wire [15:0] dbg_w2 = {6'd0, atr_ready, ld_loading, d_rx};
wire [15:0] dbg_w3 = atr_scount[15:0];
wire [15:0] dbg_w4 = d_ssize;
wire [15:0] dbg_w5 = {d_defer, d_flags};
wire [15:0] dbg_w6 = d_frame[15:0];
wire [15:0] dbg_w7 = d_frame[31:16];
wire [15:0] dbg_w8 = {8'd0, d_frame[39:32]};
wire [15:0] dbg_w9  = d_base[15:0];
wire [15:0] dbg_w10 = {7'd0, d_base[24:16]};
wire [15:0] dbg_w11 = d_dsk_addr[15:0];
wire [15:0] dbg_w12 = {7'd0, d_dsk_addr[24:16]};
wire [15:0] dbg_w13 = {8'd0, d_dsk_data};
wire [15:0] dbg_w14 = d_sector;
wire [15:0] dbg_w15 = {8'd0, d_code};
wire [15:0] dbg_w16 = d_nsec[15:0];
wire [15:0] dbg_w17 = d_nsec[31:16];
wire [15:0] dbg_w18 = d_waddr[15:0];
wire [15:0] dbg_w19 = {7'd0, d_waddr[24:16]};
wire [15:0] dbg_w20 = d_ld_sector[15:0];
wire [15:0] dbg_w21 = d_ld_sector[31:16];
wire [15:0] dbg_w22 = {8'd0, d_mcu_byte};
wire [15:0] dbg_w23 = {8'd0, d_ld_byte};
wire [15:0] dbg_w24 = {11'd0, xex_state};
wire [15:0] dbg_w25 = {12'd0, xex_mode, xex_done, xex_busy, xex_rd_req};
wire [15:0] dbg_w26 = {8'd0, d_sdc_cnt};
//  27..30: the first 8 data bytes of the last 1050 response (a sector read)
//  31: its checksum (end-around)
wire [15:0] dbg_w27 = d_data8[15:0];
wire [15:0] dbg_w28 = d_data8[31:16];
wire [15:0] dbg_w29 = d_data8[47:32];
wire [15:0] dbg_w30 = d_data8[63:48];
wire [15:0] dbg_w31 = {8'd0, d_sum};
assign dbg_addr = {11'd0, dbg_sel};
assign dbg_data = (dbg_sel == 4'd0) ? dbg_w0 :
                  (dbg_sel == 4'd1) ? dbg_w1 :
                  (dbg_sel == 4'd2) ? dbg_w2 :
                  (dbg_sel == 4'd3) ? dbg_w3 :
                  (dbg_sel == 4'd4) ? dbg_w4 :
                  (dbg_sel == 4'd5) ? dbg_w5 :
                  (dbg_sel == 4'd6) ? dbg_w6 :
                  (dbg_sel == 4'd7) ? dbg_w7 :
                  (dbg_sel == 4'd8) ? dbg_w8 :
                  (dbg_sel == 4'd9) ? dbg_w9 :
                  (dbg_sel == 4'd10) ? dbg_w10 :
                  (dbg_sel == 4'd11) ? dbg_w11 :
                  (dbg_sel == 4'd12) ? dbg_w12 :
                  (dbg_sel == 4'd13) ? dbg_w13 :
                  (dbg_sel == 4'd14) ? dbg_w14 :
                  (dbg_sel == 4'd15) ? dbg_w15 :
                  (dbg_sel == 5'd16) ? dbg_w16 :
                  (dbg_sel == 5'd17) ? dbg_w17 :
                  (dbg_sel == 5'd18) ? dbg_w18 :
                  (dbg_sel == 5'd19) ? dbg_w19 :
                  (dbg_sel == 5'd20) ? dbg_w20 :
                  (dbg_sel == 5'd21) ? dbg_w21 :
                  (dbg_sel == 5'd22) ? dbg_w22 :
                  (dbg_sel == 5'd23) ? dbg_w23 :
                  (dbg_sel == 5'd24) ? dbg_w24 :
                  (dbg_sel == 5'd25) ? dbg_w25 :
                  (dbg_sel == 5'd26) ? dbg_w26 :
                  (dbg_sel == 5'd27) ? dbg_w27 :
                  (dbg_sel == 5'd28) ? dbg_w28 :
                  (dbg_sel == 5'd29) ? dbg_w29 :
                  (dbg_sel == 5'd30) ? dbg_w30 :
                  (dbg_sel == 5'd31) ? dbg_w31 : 16'd0;

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
// One sample per PCM5102 LRCK frame: kg_pcm5102 with DIV_BITS = 2 makes LRCK = clk / 512, i.e.
// 55.8 kHz at 28.571 MHz.  Updating aud_hold at that rate keeps the DAC pitch correct; the HDMI
// sampler takes its own 48 kHz strobe from this held value.
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

// ------------------------------------------------------------------ I2S DAC (PCM5102)
wire i2s_din, i2s_bck, i2s_ws;
kg_pcm5102 #(.DIV_BITS(2)) dac(
	.clk		(clk_vid),
	.reset	(areset),
	.left		(aud_hold[31:16]),
	.right	(aud_hold[15:0]),
	.din		(i2s_din),
	.bck		(i2s_bck),
	.lrck		(i2s_ws)
);
// PCM5102 on Mini G rev G2: BCK goes to the DAC directly, as on the Go board.
// kg_pcm5102 changes DIN/LRCK on the falling BCK; the DAC samples the next rising edge.
// The former ODDR2 inversion put the DIN/LRCK transitions on the sampling edge.
assign DAC_BCK = i2s_bck;
assign DAC_WS = i2s_ws;
assign DAC_DAT = i2s_din;

endmodule
`default_nettype wire

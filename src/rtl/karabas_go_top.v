`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Atari 800XL for Karabas Go (XC6SLX25, VGA through the video DAC, PCM5102).
--
-- 28.571 MHz core and pixel clock (VCO 800 MHz), 25 MHz MCU link, 8 MHz FT812 clock.
-- The Atari machine is in atari800_machine.v; this wrapper is the board: MCU link, OSD, VGA, I2S DAC.
--
-------------------------------------------------------------------------------------------------------------------*/

module karabas_go_top (
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

	//------------------ vga dac -------------
	output wire [7:0] 		VGA_R,
	output wire [7:0] 		VGA_G,
	output wire [7:0] 		VGA_B,
	output wire 			VGA_HS,
	output wire 			VGA_VS,
	output wire 			V_CLK,

	//------------------ ft812 spi and ctl ---
	output wire 			FT_SPI_CS_N,
	output wire 			FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	output wire 			FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	output wire 			FT_OE_N,

	//------------------ cf card -------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//------------------ fdc -----------------
	input wire 				FDC_INDEX,
	output wire [1:0] 		FDC_DRIVE,
	output wire 			FDC_MOTOR,
	output wire 			FDC_DIR,
	output wire 			FDC_STEP,
	output wire 			FDC_WDATA,
	output wire 			FDC_WGATE,
	input wire 				FDC_TR00,
	input wire 				FDC_WPRT,
	input wire 				FDC_RDATA,
	output wire 			FDC_SIDE_N,

	//------------------ analog in/out -------
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,
	output wire 			BEEPER,

	//------------------ i2s dac -------------
	output wire          DAC_LRCK,
	output wire          DAC_DAT,
	output wire          DAC_BCK,
	output wire          DAC_MUTE,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	inout wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	input wire 				MCU_SPI_FT_CS_N,
	input wire 				MCU_SPI_SD2_CS_N,
	inout wire [1:0] 		MCU_SPI_IO,

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

// unused board pins
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
assign BEEPER = 1'b0;
assign UART_CTS = 1'bz;
assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FT_OE_N = 1'b1;
assign DAC_MUTE = 1'b1;
assign FDC_DRIVE = 2'b00;
assign FDC_MOTOR = 1'b0;
assign FDC_DIR = 1'b0;
assign FDC_STEP = 1'b0;
assign FDC_WDATA = 1'b0;
assign FDC_WGATE = 1'b0;
assign FDC_SIDE_N = 1'b1;
assign SDR_A = 13'd0;
assign SDR_CLK = 1'b0;
assign SDR_BA = 2'd0;
assign SDR_DQM = 2'b11;
assign SDR_WE_N = 1'b1;
assign SDR_CAS_N = 1'b1;
assign SDR_RAS_N = 1'b1;
assign SDR_DQ = 16'hzzzz;

// ------------------------------------------------------------------ clocks
// VCO 800 MHz (50 * 16):
//   clk_sys   800 / 28 = 28.571 MHz  (Atari 16 * 1.79 MHz, also the VGA pixel clock)
//   clk_8mhz  800 / 100 = 8 MHz      (FT812)
//   clk_host  800 / 32 = 25 MHz      (MCU link)
wire [5:0] pll_clk;
wire locked;
kg_pll #(
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(16),
	.CLKOUT0_DIVIDE(28),
	.CLKOUT1_DIVIDE(28),
	.CLKOUT2_DIVIDE(100),
	.CLKOUT3_DIVIDE(32),
	.CLKOUT4_DIVIDE(14),
	.BUFG_MASK(6'b001101)
) pll (
	.clk_in		(CLK_50MHZ),
	.rst			(1'b0),
	.clk_out		(pll_clk),
	.locked		(locked)
);
// Match Mini G: machine and video on PLL1, VGA pixel clock from the same BUFG.
wire clk_vid_pll = pll_clk[1];
wire clk_vid;
BUFG bufg_clk_vid(.I(clk_vid_pll), .O(clk_vid));
wire clk_sys = clk_vid;
wire clk_8mhz = pll_clk[2];
wire clk_host = pll_clk[3];
wire areset = ~locked;

// pixel clock to the VGA DAC
ODDR2 u_v_clk(.Q(V_CLK), .C0(clk_vid), .C1(~clk_vid), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

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
// burst, one 25 MHz strobe per byte.  Queue the set-2 bytes and pop them in
// clk_sys, so the code and the strobe change together (no CDC race).
wire [7:0] ps2_dout;
wire       ps2_empty, ps2_full;
reg        ps2_rd = 1'b0;
reg  [1:0] ps2_state = 2'd0;
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
				ps2_rd <= 1'b1;
				ps2_state <= 2'd1;
			end
			2'd1: ps2_state <= 2'd2;
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

// LOAD: the file loader is not connected yet
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_size, ld_addr;
wire ld_start, ld_active, ld_end, ld_wr;

// MCU image service -> ATR loader (same as MiniG)
wire [7:0]  sdc_img_mounted;
wire [63:0] sdc_img_size;
wire [7:0]  sdc_rd;
wire [31:0] sdc_sector;
wire        sdc_busy, sdc_done, sdc_error;
wire [2:0]  sdc_slot;
wire        sdc_byte_strobe;
wire [8:0]  sdc_byte_addr;
wire [7:0]  sdc_byte_in_data;

// OSD: the bitmap of kg_l2_osd, drawn by kg_l2_osd_overlay in clk_vid
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

assign MCU_SPI_IO[0] = mcu_int;
assign MCU_SPI_IO[1] = 1'bz;

wire mcu_ft_spi_on, mcu_ft_vga_on, mcu_ft_sck, mcu_ft_mosi, mcu_ft_cs_n;
assign FT_SPI_CS_N = mcu_ft_spi_on ? mcu_ft_cs_n : 1'b1;
assign FT_SPI_SCK = mcu_ft_spi_on ? mcu_ft_sck : 1'b1;
assign FT_SPI_MOSI = mcu_ft_spi_on ? mcu_ft_mosi : 1'b1;

kg_mcu2 #(
	.CAPS(16'h0000),
	.SW_N(6),
	.SW_INIT(48'h000000000000),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),
	.ENABLE_FT(1),
	.ENABLE_SD2(0),
	.ENABLE_AUX(1)
) mcu(
	.CLK				(clk_host),
	.N_RESET			(locked),

	.MCU_SCK			(MCU_SCK),
	.MCU_MOSI		(MCU_MOSI),
	.MCU_MISO		(MCU_MISO),
	.MCU_SS			(MCU_CS_N),
	.MCU_INT			(mcu_int),
	.MCU_SPI_FT_SS	(MCU_SPI_FT_CS_N),
	.MCU_SPI_SD2_SS(MCU_SPI_SD2_CS_N),

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

	.FT_SPI_ON		(mcu_ft_spi_on), .FT_VGA_ON(mcu_ft_vga_on), .FT_RESET(),
	.FT_SCK			(mcu_ft_sck), .FT_MOSI(mcu_ft_mosi), .FT_CS_N(mcu_ft_cs_n),
	.FT_MISO			(FT_SPI_MISO),
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
wire        xex_mode, xex_busy, xex_done;
wire        xex_start;
wire [15:0] xex_boot_ssize;
wire [31:0] xex_boot_scount;
wire        xex_rd_req;
wire [24:0] xex_rd_addr;
wire [4:0]  xex_state;
wire [31:0] dbg_nsec;
wire [24:0] dbg_waddr;
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
wire        xex_reset;
wire [7:0]  dbg_cmd_cnt, dbg_last_code, dbg_ack_cnt, dbg_tx_cnt, dbg_rx_byte;
wire [7:0]  dbg_cmd_edges, dbg_bad_frames, dbg_flags;
wire [39:0] dbg_last_frame;
wire [63:0] dbg_data8;
wire [7:0]  dbg_sum;
wire [15:0] dbg_sector;
wire [7:0]  dbg_code;
wire [24:0] dbg_base;
wire [15:0] dbg_addr, dbg_data;
wire any_reset   = areset | sw_reset | cold_reset | ld_loading;
wire power_reset = areset | cold_reset | ld_loading;
// No disk mounted: reset must cold-start the OS, or the XEX DOSVEC runs the demo again.
wire force_cold  = ~atr_ready & (sw_reset | cold_reset);

// ------------------------------------------------------------------ ATR image loader
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
wire signed [17:0] aud_l, aud_r;

atari800_machine #(
	.HS_START (10'd744),
	.HS_END   (10'd808)
) machine (
	.clk            (clk_sys),
	.clk_vid        (clk_vid),
	.reset          (any_reset),
	.power_reset    (power_reset),
	.force_cold     (force_cold),
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
	.MA             (MA),
	.MD             (MD),
	.MWR_N          (MWR_N),
	.MRD_N          (MRD_N)
);

// ------------------------------------------------------------------ raw XEX DMA loader
// atari_atr_loader has copied the raw file to SRAM and built a synthetic
// A raw .xex is served through the same synthetic-ATR + 6502 loader as on
// MiniG: the OS coldstart clears RAM from $0008 to the top, so a segment
// DMA'ed before the boot would be wiped (see doc/XEX_DMA_COLDSTART_CLEAR.md).
// xex_dma_loader.v stays in the tree for the later post-boot design.
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

// AUX DEBUG words for AT+KARABAS=debug:1 (addresses 0..15):
//   0: atr_ready        1: atr_scount          2: atr_ssize
//   3: last SIO code    4: last R sector       5: tx responses
//   6: valid commands   7: first data byte      8: SIO flags
//   9: SIO code        10: data checksum       11..12: img_size (0 = ejected)
//  13: ATR loader sectors  14..15: last SRAM write address
reg [25:0] dbg_div = 26'd0;
always @(posedge clk_host)
	dbg_div <= dbg_div + 26'd1;
wire [3:0] dbg_sel = dbg_div[25:22];
wire [15:0] dbg_word =
	(dbg_sel == 4'd0)  ? {15'd0, atr_ready} :
	(dbg_sel == 4'd1)  ? atr_scount[15:0] :
	(dbg_sel == 4'd2)  ? atr_ssize :
	(dbg_sel == 4'd3)  ? {8'd0, dbg_last_code} :
	(dbg_sel == 4'd4)  ? dbg_sector :
	(dbg_sel == 4'd5)  ? {8'd0, dbg_tx_cnt} :
	(dbg_sel == 4'd6)  ? {8'd0, dbg_cmd_cnt} :
	(dbg_sel == 4'd7)  ? {8'd0, dbg_data8[7:0]} :
	(dbg_sel == 4'd8)  ? {8'd0, dbg_flags} :
	(dbg_sel == 4'd9)  ? {8'd0, dbg_code} :
	(dbg_sel == 4'd10) ? {8'd0, dbg_sum} :
	(dbg_sel == 4'd11) ? sdc_img_size[15:0] :
	(dbg_sel == 4'd12) ? sdc_img_size[31:16] :
	(dbg_sel == 4'd13) ? dbg_nsec[15:0] :
	(dbg_sel == 4'd14) ? {12'd0, xex_mode, xex_done, xex_busy, xex_rd_req} :
	                     {11'd0, xex_state};
assign dbg_addr = {12'd0, dbg_sel};
assign dbg_data = dbg_word;

// The bitmap OSD of link v2 (kg_l2_osd_overlay): the settings cross from clk_host
// internally; the picture is centred in the active area.
wire        osd_hs, osd_vs, osd_de;
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
// One sample per PCM5102 LRCK frame: kg_pcm5102 with DIV_BITS = 2 makes LRCK = clk / 512,
// i.e. 55.8 kHz at 28.571 MHz.  Every DAC frame gets a fresh sample.
reg [8:0]  aud_acc = 9'd0;
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

wire i2s_din, i2s_bck, i2s_ws;
kg_pcm5102 #(.DIV_BITS(2)) dac(
	.clk		(clk_sys),
	.reset	(areset),
	.left		(aud_hold[31:16]),
	.right	(aud_hold[15:0]),
	.din		(i2s_din),
	.bck		(i2s_bck),
	.lrck		(i2s_ws)
);
assign DAC_BCK = i2s_bck;
assign DAC_LRCK = i2s_ws;
assign DAC_DAT = i2s_din;

// ------------------------------------------------------------------ VGA
// Normal Go: the same video pipeline as MiniG (machine -> atari_video ->
// kg_l2_osd_overlay), with the HDMI serializer replaced by the VGA DAC.
assign VGA_R = osd_rgb[23:16];
assign VGA_G = osd_rgb[15:8];
assign VGA_B = osd_rgb[7:0];
assign VGA_HS = ~osd_hs;
assign VGA_VS = ~osd_vs;

endmodule
`default_nettype wire

`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- ATR image loader for the Karabas Atari 800XL core (link v2, kg_l2_img).
--
-- The firmware exposes the mounted .atr as 512-byte sectors of the file.  This
-- module copies the whole file into the free 1 MB of the external SRAM at
-- 0x300000, one byte per SRAM write, and parses the 16-byte ATR header.
--
-- The bytes of a sector arrive as a burst from clk_host; a small asynchronous
-- FIFO hands them to the SRAM clock.  The SRAM address is a simple counter
-- (every sector is 512 bytes, the last one is padded by the file mounter), so
-- the FIFO carries data only.  Only the first 16 bytes go to a header buffer.
--
--   0x000000-0x1FFFFF  Atari RAM / banks
--   0x200000-0x2FFFFF  cartridge
--   0x300000-0x3FFFFF  the ATR file (header + sectors), read by atari_sio_disk
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_atr_loader (
	input wire        clk_host,
	input wire        clk,
	input wire        reset_host,

	// image mounter (slot 1 = the .atr)
	input wire [7:0]  img_mounted,
	input wire [63:0] img_size,

	// kg_mcu2 sector read interface
	output reg [7:0]  sdc_rd,
	output reg [31:0] sdc_sector,
	input wire        sdc_busy,
	input wire        sdc_done,
	input wire        sdc_error,
	input wire [2:0]  sdc_slot,
	input wire        sdc_byte_strobe,
	input wire [8:0]  sdc_byte_addr,
	input wire [7:0]  sdc_byte_in_data,

	// atari_sram loader port (clk)
	output wire        ld_req,
	output wire [24:0] ld_addr,
	output wire [7:0]  ld_data,

	// ATR geometry / status
	output reg [15:0]  atr_ssize,
	output reg [31:0]  atr_scount,
	output reg         atr_ready,
	output reg         loading,       // clk_host: hold the machine in reset
	output wire        xex_mode,      // raw .xex in the Disk slot
	output wire [31:0] dbg_nsec,      // diagnostic: planned / requested 512-byte sectors
	output wire [24:0] dbg_waddr      // diagnostic: last SRAM write address
);

localparam [24:0] ATR_BASE = 25'h300000;
localparam [31:0] MAX_SEC  = 32'd2048;    // 1 MB / 512

localparam [2:0] S_IDLE  = 3'd0;
localparam [2:0] S_REQ   = 3'd1;
localparam [2:0] S_WAIT  = 3'd2;
localparam [2:0] S_NEXT  = 3'd3;
localparam [2:0] S_DRAIN = 3'd4;

// ~160 us at 25 MHz: the FIFO is empty long before, the last SRAM writes finish
localparam [12:0] DRAIN_CYCLES = 13'd4095;

reg [2:0]  state = S_IDLE;
reg [31:0] sector = 32'd0;
reg [31:0] nsec = 32'd0;
reg [31:0] size_d = 32'd0;
reg        start_req = 1'b0;
reg [12:0] drain = 13'd0;
reg [7:0]  hdr [0:15];

wire [31:0] size32 = img_size[31:0];
wire [31:0] nsec_calc = (size32 + 32'd511) >> 9;
wire [31:0] paras = {hdr[7], hdr[6], hdr[3], hdr[2]};
// ATR sizes: 16 + 128*n (SD) or 400 + 256*n (DD); this also rejects a cartridge
// mount (a power of two) coming through the shared size of kg_l2_img.
wire atr_size_ok = (size32[6:0] == 7'd16) || (size32[7:0] == 8'd144);
// A raw .xex mounted in the Disk slot is not an ATR: build a synthetic
// 128-byte boot disk in SRAM (ATR header + loader) and put the file bytes
// at sector 5.  A normal ATR keeps the old path.
wire is_xex = (size32 != 32'd0) && !atr_size_ok;
assign xex_mode = is_xex;

// ------------------------------------------------------------------ data FIFO (bytes only)
reg        prefix_active = 1'b0;
reg        prefix_done   = 1'b0;
reg [9:0]  prefix_addr   = 10'd0;
reg        xex_mode_c    = 1'b0;
reg [31:0] xex_size_c    = 32'd0;
wire [7:0] fifo_dout;
wire       fifo_empty, fifo_full;
wire       fifo_wr = (state == S_WAIT) && sdc_byte_strobe && !fifo_full;
// Do not consume file bytes until the synthetic XEX prefix is written.
wire       fifo_rd = ~fifo_empty && (!xex_mode_c || prefix_done);

kg_async_fifo #(.DW(8), .AW(7)) fifo (
	.wclk   (clk_host),
	.wreset (reset_host),
	.wr     (fifo_wr),
	.din    (sdc_byte_in_data),
	.full   (fifo_full),
	.rclk   (clk),
	.rreset (reset_host),
	.rd     (fifo_rd),
	.dout   (fifo_dout),
	.empty  (fifo_empty),
	.rcount ()
);

// ------------------------------------------------------------------ SRAM write side (clk)
reg        rd_d1 = 1'b0, rd_d2 = 1'b0;
reg [24:0] ld_addr_r = ATR_BASE;
reg [7:0]  ld_data_r = 8'd0;
reg [24:0] waddr = ATR_BASE;
reg [24:0] waddr_last = ATR_BASE;
reg [1:0]  load_s = 2'b00;

always @(posedge clk)
	load_s <= {load_s[0], loading};
wire load_clk = load_s[1];

// Synthetic prefix: ATR header + 512-byte XEX loader at ATR_BASE, while the
// raw file bytes go to ATR_BASE+528 = sector 5.
wire [7:0] prefix_data;
xex_prefix_rom xex_prefix (
	.addr     (prefix_addr),
	.xex_size (xex_size_c),
	.d        (prefix_data)
);

always @(posedge clk) begin
	if (!load_clk) begin
		xex_mode_c <= is_xex;
		xex_size_c <= size32;
	end
	if (!load_clk) begin
		prefix_active <= 1'b0;
		prefix_done   <= 1'b0;
		prefix_addr   <= 10'd0;
	end
	else if (xex_mode_c && !prefix_done) begin
		prefix_active <= 1'b1;
		if (prefix_addr == 10'd527) begin
			prefix_active <= 1'b0;
			prefix_done   <= 1'b1;
			prefix_addr   <= 10'd0;
		end
		else
			prefix_addr <= prefix_addr + 10'd1;
	end
	else
		prefix_active <= 1'b0;
end

always @(posedge clk) begin
	rd_d1 <= fifo_rd;
	rd_d2 <= rd_d1;
	if (rd_d1) begin
		ld_addr_r <= waddr;
		ld_data_r <= fifo_dout;
	end
	if (!load_clk)
		waddr <= xex_mode_c ? (ATR_BASE + 25'd528) : ATR_BASE; // XEX data starts at sector 5
	else begin
		waddr_last <= waddr;               // retain the end address for debug
		if (rd_d1)
			waddr <= waddr + 25'd1;
	end
end

assign ld_req  = prefix_active | (rd_d2 & load_clk);
assign ld_addr = prefix_active ? (ATR_BASE + {15'd0, prefix_addr}) : ld_addr_r;
assign ld_data = prefix_active ? prefix_data : ld_data_r;
assign dbg_nsec = nsec;
assign dbg_waddr = waddr_last;

// ------------------------------------------------------------------ producer (clk_host)
always @(posedge clk_host) begin
	if (reset_host) begin
		state <= S_IDLE;
		sector <= 32'd0;
		nsec <= 32'd0;
		size_d <= 32'd0;
		start_req <= 1'b0;
		drain <= 13'd0;
		sdc_rd <= 8'd0;
		sdc_sector <= 32'd0;
		loading <= 1'b0;
		atr_ready <= 1'b0;
		atr_ssize <= 16'd128;
		atr_scount <= 32'd0;
	end
	else begin
		size_d <= size32;
		if (size32 == 32'd0)
			start_req <= 1'b0;
		// Start only while no image is ready.  Without !atr_ready a stale
		// size_d/mount edge after S_DRAIN can re-assert start_req and reload
		// the same image forever; the parser then never sees a stable
		// atr_ready/xex_start (system TB, 2026-11-16).
		else if ((img_mounted[0] || size32 != size_d) && !atr_ready)
			start_req <= 1'b1;
		case (state)
			S_IDLE: begin
				sdc_rd <= 8'd0;
				if (size32 == 32'd0) begin
					// eject, or the size-0 mount before the real size
					loading <= 1'b0;
					atr_ready <= 1'b0;
				end
				// !atr_ready also prevents a stale start_req from reloading
				// the image after S_DRAIN.  A new mount arrives as size=0
				// first, which clears atr_ready and start_req.
				else if (start_req && !atr_ready && (atr_size_ok || is_xex) && !sdc_busy) begin
					start_req <= 1'b0;
					sector <= 32'd0;
					nsec <= (nsec_calc > MAX_SEC) ? MAX_SEC : nsec_calc;
					loading <= 1'b1;
					atr_ready <= 1'b0;
					state <= S_REQ;
				end
			end

			S_REQ: begin
				if (sector >= nsec) begin
					drain <= DRAIN_CYCLES;
					state <= S_DRAIN;
				end
				else begin
					sdc_sector <= sector;
					sdc_rd[0] <= 1'b1;
					state <= S_WAIT;
				end
			end

			S_WAIT: begin
				// The mounter takes the request as sdc_busy rises and never looks at sdc_rd
				// again until its own S_IDLE. A request held up to sdc_done is therefore seen
				// in S_IDLE again in the very cycle sdc_done pulses and starts a second,
				// spurious read of the same sector; the next sector then receives the data of
				// the previous one and the whole file shifts by 512 bytes (the board showed
				// 361 reads for a 360-sector image and the ATR header at SRAM offset 512).
				// C64's c64_d64_loader drops sdc_rd the same way.
				if (sdc_busy)
					sdc_rd[0] <= 1'b0;
				if (sdc_byte_strobe && sector == 32'd0 && sdc_byte_addr[8:4] == 5'd0)
					hdr[sdc_byte_addr[3:0]] <= sdc_byte_in_data;
				if (sdc_done) begin
					sdc_rd[0] <= 1'b0;
					state <= S_NEXT;
				end
				else if (sdc_error) begin
					sdc_rd[0] <= 1'b0;
					loading <= 1'b0;
					atr_ready <= 1'b0;
					state <= S_IDLE;
				end
			end

			S_NEXT: begin
				if (sector == 32'd0) begin
					if (is_xex) begin
						// synthetic disk: sectors 1-4 = loader, 5.. = raw XEX
						atr_ssize  <= 16'd128;
						atr_scount <= 32'd4 + ((size32 + 32'd127) >> 7);
					end
					// the ATR header: 3 boot sectors of 128 bytes, then atr_ssize
					else if (hdr[0] == 8'h96 && hdr[1] == 8'h02) begin
						if (hdr[5] == 8'd1 && hdr[4] == 8'd0) begin
							atr_ssize <= 16'd256;
							if (paras >= 32'd24)
								atr_scount <= 32'd3 + ((paras - 32'd24) >> 4);
							else
								atr_scount <= 32'd0;
						end
						else begin
							atr_ssize <= 16'd128;
							atr_scount <= paras >> 3;
						end
						if (paras == 32'd0) begin
							if (hdr[5] == 8'd1 && hdr[4] == 8'd0)
								atr_scount <= (size32 > 32'd400) ?
									(32'd3 + ((size32 - 32'd400) >> 8)) : 32'd0;
							else
								atr_scount <= (size32 > 32'd16) ?
									((size32 - 32'd16) >> 7) : 32'd0;
						end
					end
				end
				sector <= sector + 32'd1;
				state <= S_REQ;
			end

			S_DRAIN: begin
				if (drain != 13'd0)
					drain <= drain - 13'd1;
				else begin
					loading <= 1'b0;
					atr_ready <= 1'b1;
					state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
		endcase

		// Eject / the size-0 frame before every mount: abort immediately,
		// whatever state the loader is in.  The old code cleared the state
		// only in S_IDLE; an eject while S_WAIT/S_DRAIN could leave
		// atr_ready=1, and the next cold reset booted the old ATR from SRAM
		// (observed on Go 2026-11-16: Disk shows unmounted, Montezuma still
		// boots after reset).  These assignments are after the case, so they
		// win over anything the case did in this clock.
		if (size32 == 32'd0) begin
			start_req <= 1'b0;
			state <= S_IDLE;
			loading <= 1'b0;
			atr_ready <= 1'b0;
			sdc_rd <= 8'd0;
			sector <= 32'd0;
			nsec <= 32'd0;
			drain <= 13'd0;
		end
	end
end

endmodule
`default_nettype wire

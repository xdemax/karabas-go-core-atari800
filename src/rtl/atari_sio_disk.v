`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Read-only Atari 1050 SIO responder (revised).
--
-- Protocol (what the OS really expects):
--   command frame : DEV(0x31) CMD AUX1 AUX2 CKS   (CMD line low)
--   CMD line high -> ~300 us -> 'A' (0x41)  ACK   (a BYTE, not a low level!)
--                 -> ~300 us -> 'C' (0x43)  COMPLETE
--                 -> data bytes -> CKS        (status: 4 bytes, read: 128/256)
--   unsupported command / bad sector -> 'N' (0x4E) NAK
--   CKS = 8-bit sum WITH end-around carry (carry is added back).
--
-- Bit timing: POKEY serout clock rising edge (while it runs), otherwise an
-- internal 19200 baud timer (auto fallback, so a missing/stopped serout clock
-- cannot hang the responder).
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_sio_disk #(
	parameter       USE_SCLK   = 1,       // 1: use POKEY clock when it runs, 0: internal timer only
	parameter       BIT_CYCLES = 1488,    // clk cycles per bit (28.571 MHz / 19200)
	parameter [7:0] DEV_ID     = 8'h31,   // D1:
	parameter       GAP_ACK    = 9000,    // CMD high -> 'A'      (~315 us @ 28.571 MHz)
	parameter       GAP_CMPL   = 28571,   // 'A' -> 'C'           (~1 ms; DOS 2.0S needs >=600 us)
	parameter       GAP_DATA   = 6000     // 'C' -> first data byte
) (
	input wire        clk,
	input wire        reset,

	// ATR geometry from atari_atr_loader
	input wire [15:0] atr_ssize,
	input wire [31:0] atr_scount,
	input wire        atr_ready,

	// internal POKEY SIO pins
	input wire        sio_command,
	input wire        sio_txd,
	input wire        sio_clock,
	output reg        sio_rxd,

	// atari_sram single-byte disk read port
	output reg        dsk_req,
	output reg [24:0] dsk_addr,
	input wire [7:0]  dsk_data,
	input wire        dsk_ack,

	// debug counters (cleared by reset)
	output reg [7:0]  dbg_cmd_cnt,     // valid command frames
	output reg [7:0]  dbg_last_code,   // code of the last one (52 R, 53 S)
	output reg [7:0]  dbg_ack_cnt,     // 'A' bytes sent
	output reg [7:0]  dbg_tx_cnt,      // responses completed
	output reg [7:0]  dbg_rx_byte,     // 8-bit frames captured (valid or not)

	// extra debug, NOT cleared by reset (only at FPGA configuration):
	// compare before/after a reset to see if the OS talks at all
	output reg [7:0]  dbg_cmd_edges,   // falling edges of SIO_COMMAND
	output reg [7:0]  dbg_bad_frames,  // 5-byte frames with bad checksum / device
	output reg [7:0]  dbg_flags,       // see below
	output reg [39:0] dbg_last_frame,  // last raw 5 bytes {b4,b3,b2,b1,b0}

	// last data-frame payload, NOT cleared by reset
	output reg [63:0] dbg_data8,       // first 8 data bytes of the last response
	output reg [7:0]  dbg_sum,         // its checksum
	output reg [15:0] dbg_sector,      // last R sector
	output reg [7:0]  dbg_code,        // last command
	output wire [24:0] dbg_base         // SRAM byte address of the last response
);

localparam [24:0] ATR_BASE = 25'h300000;

// ------------------------------------------------------------------ checksum, end-around carry
function [7:0] ck_add;
	input [7:0] s;
	input [7:0] b;
	reg   [8:0] t;
	begin
		t = {1'b0, s} + {1'b0, b};
		ck_add = t[7:0] + {7'd0, t[8]};
	end
endfunction

// ------------------------------------------------------------------ SIO synchronizers / edges
reg [1:0] cmd_s = 2'b11, txd_s = 2'b11, clk_s = 2'b11;
always @(posedge clk) begin
	cmd_s <= {cmd_s[0], sio_command};
	txd_s <= {txd_s[0], sio_txd};
	clk_s <= {clk_s[0], sio_clock};
end
wire cmd  = cmd_s[1];
wire txd  = txd_s[1];
wire sclk = clk_s[1];
reg sclk_d = 1'b0, cmd_d = 1'b1;
always @(posedge clk) begin
	sclk_d <= sclk;
	cmd_d  <= cmd;
end
wire rise = sclk && !sclk_d;   // POKEY sets the data here
wire fall = sclk_d && !sclk;   // and the other side samples here

// ------------------------------------------------------------------ bit tick for the transmitter
reg [12:0] alive = 13'd0;                 // POKEY serout clock seen recently
always @(posedge clk) begin
	if (rise)
		alive <= 13'd6000;                // ~4 bit times
	else if (alive != 13'd0)
		alive <= alive - 13'd1;
end
wire sclk_ok = (alive != 13'd0);

reg [11:0] icnt = 12'd0;                  // internal 19200 baud free-running timer
always @(posedge clk) begin
	if (icnt == 12'd0)
		icnt <= BIT_CYCLES - 1;
	else
		icnt <= icnt - 12'd1;
end
wire itick = (icnt == 12'd0);
wire btick = (USE_SCLK != 0 && sclk_ok) ? rise : itick;

// ------------------------------------------------------------------ raw-line debug (no reset)
reg seen_clk = 1'b0, seen_cmd = 1'b0, seen_txd = 1'b0;
always @(posedge clk) begin
	if (cmd_d && !cmd)
		dbg_cmd_edges <= dbg_cmd_edges + 8'd1;
	if (rise)  seen_clk <= 1'b1;
	if (!cmd)  seen_cmd <= 1'b1;
	if (!cmd && !txd) seen_txd <= 1'b1;
	dbg_flags <= {atr_ready, sclk, txd, cmd, sclk_ok, seen_txd, seen_cmd, seen_clk};
end
initial begin
	dbg_cmd_edges = 8'd0;
	dbg_bad_frames = 8'd0;
	dbg_flags = 8'd0;
	dbg_last_frame = 40'd0;
	dbg_data8 = 64'd0;
	dbg_sum = 8'd0;
	dbg_sector = 16'd0;
	dbg_code = 8'd0;
end

// ------------------------------------------------------------------ command frame receiver
reg        rx_active = 1'b0;
reg        rx_armed = 1'b1;      // a high stop bit was seen: the next low is a start
reg        rx_skip = 1'b0;       // the first falling edge is the start bit's sample
reg [3:0]  rbit = 4'd0;
reg [7:0]  rsh = 8'd0;
reg [2:0]  rbyte = 3'd0;
reg [7:0]  cmdbuf [0:4];
reg        cmd_pulse = 1'b0;
reg [7:0]  cmd_code = 8'd0;
reg [15:0] cmd_sector = 16'd0;

wire [7:0] rx_now = {txd, rsh[7:1]};   // byte being completed at the 8th sample

always @(posedge clk) begin
	if (reset) begin
		rx_active <= 1'b0;
		rx_armed <= 1'b1;
		rx_skip <= 1'b0;
		rbit <= 4'd0;
		rsh <= 8'd0;
		rbyte <= 3'd0;
		cmd_pulse <= 1'b0;
		cmd_code <= 8'd0;
		cmd_sector <= 16'd0;
		dbg_rx_byte <= 8'd0;
	end
	else if (!cmd) begin
		cmd_pulse <= 1'b0;
		if (!rx_active) begin
			if (txd)
				rx_armed <= 1'b1;
			else if (rx_armed) begin
				rx_active <= 1'b1;
				rx_armed <= 1'b0;
				rx_skip <= 1'b1;
				rbit <= 4'd0;
			end
		end
		else if (fall) begin
			if (rx_skip)
				rx_skip <= 1'b0;
			else begin
				rsh <= {txd, rsh[7:1]};
				rbit <= rbit + 4'd1;
				if (rbit == 4'd7) begin
					rx_active <= 1'b0;
					rx_armed <= 1'b0;
					rx_skip <= 1'b0;
					dbg_rx_byte <= dbg_rx_byte + 8'd1;
					cmdbuf[rbyte] <= rx_now;
					if (rbyte == 3'd4) begin
						rbyte <= 3'd0;
						dbg_last_frame <= {rx_now, cmdbuf[3], cmdbuf[2], cmdbuf[1], cmdbuf[0]};
						if (rx_now == ck_add(ck_add(ck_add(cmdbuf[0], cmdbuf[1]), cmdbuf[2]), cmdbuf[3]) &&
						    cmdbuf[0] == DEV_ID) begin
							cmd_pulse <= 1'b1;
							cmd_code <= cmdbuf[1];
							cmd_sector <= {cmdbuf[3], cmdbuf[2]};
						end
						else
							dbg_bad_frames <= dbg_bad_frames + 8'd1;
					end
					else
						rbyte <= rbyte + 3'd1;
				end
			end
		end
	end
	else begin
		rx_active <= 1'b0;
		rbyte <= 3'd0;
		cmd_pulse <= 1'b0;
	end
end

// ------------------------------------------------------------------ sector geometry
wire [15:0] ssize = (atr_ssize == 16'd128 || atr_ssize == 16'd256) ? atr_ssize : 16'd128;
wire [15:0] sec_len = (cmd_sector <= 16'd3) ? 16'd128 : ssize;
wire [24:0] sec_ofs = (cmd_sector <= 16'd3) ? ((cmd_sector - 16'd1) * 25'd128)
                                            : (25'd384 + (cmd_sector - 16'd4) * {9'd0, ssize});

// ------------------------------------------------------------------ response engine
localparam [2:0] S_IDLE = 3'd0;   // nothing to do
localparam [2:0] S_WCMD = 3'd1;   // command accepted, wait for CMD line high
localparam [2:0] S_GAP  = 3'd2;   // inter-byte delay
localparam [2:0] S_WAIT = 3'd3;   // wait for the tick (and for the data) to start a byte
localparam [2:0] S_BITS = 3'd4;   // data bits
localparam [2:0] S_STOP = 3'd5;   // stop bit

reg [2:0]  cs = S_IDLE;
reg [1:0]  stage = 2'd0;         // 0: 'A'/'N', 1: 'C', 2: data + checksum
reg [15:0] gap = 16'd0;
reg [15:0] resp_len = 16'd0;     // data bytes before the checksum
reg [15:0] sent = 16'd0;         // data bytes already started
reg [24:0] resp_base = 25'd0;    // SRAM byte address of data byte 0
reg [7:0]  resp_sum = 8'd0;
reg        resp_status = 1'b0;
reg        resp_nak = 1'b0;
reg [7:0]  tx_byte = 8'd0;
reg [3:0]  tx_bit = 4'd0;
reg        last = 1'b0;
reg        byte_ready = 1'b0;
reg [7:0]  byte_data = 8'd0;

// 1050 status: [drive status] [FDC status, inverted: FF = ok] [format timeout E0] [00]
// drive status: bit5 = double density (256 byte sectors), bit4 = motor on
wire [7:0] st_byte = (sent == 16'd0) ? ((ssize == 16'd256) ? 8'h30 : 8'h10) :
                     (sent == 16'd1) ? 8'hFF :
                     (sent == 16'd2) ? 8'hE0 : 8'h00;
wire [7:0] cur_data = resp_status ? st_byte : byte_data;
wire       data_avail = resp_status || byte_ready;
wire       can_start = (stage != 2'd2) || (sent >= resp_len) || data_avail;
wire [7:0] cur_tx = (stage == 2'd0) ? (resp_nak ? 8'h4E : 8'h41) :
                    (stage == 2'd1) ? 8'h43 :
                    (sent < resp_len) ? cur_data : resp_sum;

wire [24:0] read_addr = resp_base + {9'd0, sent};
assign dbg_base = resp_base;
wire need_read = (cs != S_IDLE) && !resp_status && !resp_nak && !byte_ready && !dsk_req && (sent < resp_len);

wire start_now = btick && can_start &&
                 ((cs == S_WAIT) || (cs == S_STOP && stage == 2'd2 && !last));

always @(posedge clk) begin
	if (reset) begin
		cs <= S_IDLE;
		stage <= 2'd0;
		gap <= 16'd0;
		resp_len <= 16'd0;
		sent <= 16'd0;
		resp_base <= 25'd0;
		resp_sum <= 8'd0;
		resp_status <= 1'b0;
		resp_nak <= 1'b0;
		tx_byte <= 8'd0;
		tx_bit <= 4'd0;
		last <= 1'b0;
		byte_ready <= 1'b0;
		byte_data <= 8'd0;
		dsk_req <= 1'b0;
		dsk_addr <= 25'd0;
		dbg_cmd_cnt <= 8'd0;
		dbg_last_code <= 8'd0;
		dbg_ack_cnt <= 8'd0;
		dbg_tx_cnt <= 8'd0;
		sio_rxd <= 1'b1;
	end
	else begin
		if (cmd_pulse) begin
			dbg_cmd_cnt <= dbg_cmd_cnt + 8'd1;
			dbg_last_code <= cmd_code;
			dbg_sector <= {cmdbuf[3], cmdbuf[2]};
			dbg_code <= cmd_code;
		end

		// one-byte SRAM read, started ahead of the byte that needs it
		if (dsk_req) begin
			if (dsk_ack) begin
				byte_data <= dsk_data;
				byte_ready <= 1'b1;
				dsk_req <= 1'b0;
			end
		end
		else if (need_read) begin
			dsk_addr <= read_addr;
			dsk_req <= 1'b1;
		end

		// command accepted (no image -> no drive, no answer)
		if (cmd_pulse && cs == S_IDLE && atr_ready) begin
			sent <= 16'd0;
			resp_sum <= 8'd0;
			byte_ready <= 1'b0;
			dsk_req <= 1'b0;
			last <= 1'b0;
			stage <= 2'd0;
			cs <= S_WCMD;
			if (cmd_code == 8'h52 && cmd_sector != 16'd0 && {16'd0, cmd_sector} <= atr_scount) begin
				resp_nak <= 1'b0;
				resp_status <= 1'b0;
				resp_len <= sec_len;
				resp_base <= ATR_BASE + 25'd16 + sec_ofs;
			end
			else if (cmd_code == 8'h53) begin
				resp_nak <= 1'b0;
				resp_status <= 1'b1;
				resp_len <= 16'd4;
			end
			else begin
				resp_nak <= 1'b1;       // write, format, percom...: read-only drive
				resp_status <= 1'b0;
				resp_len <= 16'd0;
			end
		end

		case (cs)
			S_IDLE: sio_rxd <= 1'b1;

			S_WCMD: begin               // the answer starts only after CMD goes high
				sio_rxd <= 1'b1;
				if (cmd) begin
					gap <= GAP_ACK;
					cs <= S_GAP;
				end
			end

			S_GAP: begin
				sio_rxd <= 1'b1;
				if (gap != 16'd0)
					gap <= gap - 16'd1;
				else
					cs <= S_WAIT;
			end

			S_WAIT: sio_rxd <= 1'b1;    // start_now below

			S_BITS: begin
				if (btick) begin
					if (tx_bit < 4'd8) begin
						sio_rxd <= tx_byte[tx_bit[2:0]];
						tx_bit <= tx_bit + 4'd1;
					end
					else begin
						sio_rxd <= 1'b1;  // stop bit
						cs <= S_STOP;
					end
				end
			end

			S_STOP: begin
				sio_rxd <= 1'b1;
				if (btick) begin
					if (stage == 2'd0) begin
						if (resp_nak)
							cs <= S_IDLE;
						else begin
							stage <= 2'd1;
							gap <= GAP_CMPL;
							cs <= S_GAP;
						end
					end
					else if (stage == 2'd1) begin
						stage <= 2'd2;
						gap <= GAP_DATA;
						cs <= S_GAP;
					end
					else if (last) begin
						cs <= S_IDLE;
						dbg_tx_cnt <= dbg_tx_cnt + 8'd1;
					end
					else
						cs <= S_WAIT;     // start_now overrides when the next byte is ready
				end
			end

			default: cs <= S_IDLE;
		endcase

		// start a byte: start bit now
		if (start_now) begin
			tx_byte <= cur_tx;
			sio_rxd <= 1'b0;
			tx_bit <= 4'd0;
			cs <= S_BITS;
			if (stage == 2'd0 && !resp_nak)
				dbg_ack_cnt <= dbg_ack_cnt + 8'd1;
			if (stage == 2'd2) begin
				if (sent < 16'd8)
					dbg_data8[{sent[2:0], 3'b0} +: 8] <= cur_data;
				if (sent >= resp_len)
					dbg_sum <= resp_sum;
				if (sent < resp_len) begin
					sent <= sent + 16'd1;
					resp_sum <= ck_add(resp_sum, cur_data);
					if (!resp_status)
						byte_ready <= 1'b0;
				end
				else
					last <= 1'b1;
			end
		end

		// a new command frame (CMD low again) aborts any answer
		if (!cmd && cs != S_IDLE && cs != S_WCMD) begin
			cs <= S_IDLE;
			sio_rxd <= 1'b1;
		end
	end
end

endmodule
`default_nettype wire

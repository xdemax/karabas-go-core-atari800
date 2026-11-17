`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- SRAM controller of the Atari 800 core (Karabas Go, IS61WV20488, 2M x 16, 10 ns).
--
-- The Atari core asks for a byte / word / longword at a 32-bit byte address.  This controller serves one
-- byte per core clock: the address is driven at one edge, and the data of that access is sampled at the
-- next edge (35 ns at 28.571 MHz, enough for pad delay + tAA + pad in of the asynchronous SRAM).  A 32-bit
-- access therefore takes four clocks.  The MCU file loader has a byte write port; while the Atari machine
-- is in reset (the loader holds it) this port owns the SRAM.
--
-- Byte address map of this core:
--   0x000000-0x1FFFFF  Atari RAM / extended banks (low_memory=4, up to 1088K used)
--   0x200000-0x2FFFFF  cartridge image (1 MB)
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_sram (
	input wire        clk,
	input wire        reset,

	// logical 32-bit memory port of atari800core_simple_sdram (byte address)
	input wire        req,          // one-clock pulse
	input wire [24:0] addr,
	input wire [31:0] wdata,
	input wire        we,
	input wire        b8,
	input wire        b16,
	input wire        b32,
	output reg [31:0] rdata,
	output wire       complete,      // high after the access, low while a new req is seen

	// MCU file loader: one byte per request, no completion needed
	input wire        ld_req,
	input wire [24:0] ld_addr,
	input wire [7:0]  ld_data,
	input wire        cold_clear,     // Option+F12: clear the OS warm-start validation bytes

	// SIO disk read port (one byte, clk)
	input wire        dsk_req,
	input wire [24:0] dsk_addr,
	output reg  [7:0] dsk_data,
	output reg        dsk_ack,
	output reg  [7:0] dbg_defer,      // core requests that had to wait (diagnostic)

	// SRAM pins
	output reg [20:0] MA = 21'd0,
	inout wire [15:0] MD,
	output reg [1:0]  MWR_N = 2'b11,
	output reg [1:0]  MRD_N = 2'b11
);

reg        complete_r = 1'b0;
reg        busy = 1'b0;
reg        is_ld = 1'b0;
reg        wr = 1'b0;
reg [24:0] a = 25'd0;
reg [31:0] wd = 32'd0;
reg [1:0]  nbytes = 2'd1;
reg [1:0]  idx = 2'd0;
reg [1:0]  cold_cnt = 2'd0;
reg        dsk_busy = 1'b0;
reg [24:0] dsk_a = 25'd0;

// The core's SDRAM_REQUEST is a one-clock pulse.  Latch it here so a request that
// arrives while a disk byte, a loader byte or cold_clear owns the SRAM is not
// lost; the core waits for COMPLETE and cannot retry.
reg        req_p = 1'b0;
reg [24:0] req_a = 25'd0;
reg [31:0] req_wd = 32'd0;
reg        req_we = 1'b0, req_b16 = 1'b0, req_b32 = 1'b0;
wire        go     = req | req_p;
wire [24:0] go_a   = req_p ? req_a   : addr;
wire [31:0] go_wd  = req_p ? req_wd  : wdata;
wire        go_we  = req_p ? req_we  : we;
wire        go_b16 = req_p ? req_b16 : b16;
wire        go_b32 = req_p ? req_b32 : b32;

wire [15:0] md_in = MD;
wire md_out_en = (busy | is_ld) && wr;
wire [24:0] next_addr = a + {23'd0, idx} + 25'd1;
// the byte lane of the current access: the SRAM is 2M x 16, byte 0 in MD[7:0], byte 1 in MD[15:8]
wire       cur_hi = is_ld ? a[0] : ab[0];
wire [7:0] md_byte = cur_hi ? md_in[15:8] : md_in[7:0];

reg [7:0] byte_out;
always @(*) begin
	if (is_ld)
		byte_out = wd[7:0];
	else
		case (idx)
			2'd0: byte_out = wd[7:0];
			2'd1: byte_out = wd[15:8];
			2'd2: byte_out = wd[23:16];
			default: byte_out = wd[31:24];
		endcase
end

assign MD = md_out_en ? (cur_hi ? {byte_out, 8'h00} : {8'h00, byte_out}) : 16'hzzzz;

// like the SDRAM statemachine: COMPLETE is low while a new request is visible, so the core cannot
// take the previous access as already finished.
assign complete = complete_r & ~req & ~req_p;

// prepare the SRAM pins for the current byte (a + idx for core, a for loader)
wire [24:0] ab = a + {23'd0, idx};
wire [24:0] cold_addr = 25'h000033D + {23'd0, cold_cnt};

always @(posedge clk) begin
	// Catch the one-clock core request even while another owner has the SRAM.
	if (req && !req_p) begin
		req_p  <= 1'b1;
		req_a  <= addr;
		req_wd <= wdata;
		req_we <= we;
		req_b16 <= b16;
		req_b32 <= b32;
	end

	if (reset) begin
		busy <= 1'b0;
		is_ld <= 1'b0;
		complete_r <= 1'b0;
		cold_cnt <= 2'd0;
		MA <= 21'd0;
		MWR_N <= 2'b11;
		MRD_N <= 2'b11;
		rdata <= 32'd0;
		dsk_busy <= 1'b0;
		dsk_ack <= 1'b0;
		dsk_data <= 8'd0;
		req_p <= 1'b0;
		dbg_defer <= 8'd0;
	end
	else if (dsk_busy) begin
		// one-byte disk read; the external SRAM data is valid now
		dsk_data <= dsk_a[0] ? md_in[15:8] : md_in[7:0];
		dsk_ack <= 1'b1;
		dsk_busy <= 1'b0;
		MRD_N <= 2'b11;
	end
	else if (dsk_req && !dsk_ack && !busy && !is_ld && !go) begin
		dsk_busy <= 1'b1;
		dsk_a <= dsk_addr;
		dsk_ack <= 1'b0;
		MA <= dsk_addr[21:1];
		MWR_N <= 2'b11;
		MRD_N <= 2'b00;
	end
	else if (!busy) begin
		dsk_ack <= 1'b0;
		complete_r <= 1'b0;
		if (!cold_clear)
			cold_cnt <= 2'd0;
		if (cold_clear && cold_cnt != 2'd3) begin
			// Option+F12: force the OS cold-start check by clearing PUPBT1..3 ($033D..$033F).
			busy <= 1'b1;
			is_ld <= 1'b1;
			wr <= 1'b1;
			a <= cold_addr;
			wd <= 32'd0;
			nbytes <= 2'd1;
			idx <= 2'd0;
			MA <= cold_addr[21:1];
			MWR_N <= cold_addr[0] ? 2'b01 : 2'b10;
			MRD_N <= 2'b11;
			cold_cnt <= cold_cnt + 2'd1;
		end
		else if (ld_req) begin
			// loader write: one byte per clock, WE stays low while the stream runs
			busy <= 1'b1;
			is_ld <= 1'b1;
			wr <= 1'b1;
			a <= ld_addr;
			wd <= {24'd0, ld_data};
			nbytes <= 2'd1;
			idx <= 2'd0;
			MA <= ld_addr[21:1];
			MWR_N <= ld_addr[0] ? 2'b01 : 2'b10;
			MRD_N <= 2'b11;
		end
		else if (go) begin
			// A latched request was delayed by a disk/loader/cold access.
			if (req_p)
				dbg_defer <= dbg_defer + 8'd1;
			req_p <= 1'b0;
			busy <= 1'b1;
			is_ld <= 1'b0;
			wr <= go_we;
			a <= go_a;
			wd <= go_wd;
			nbytes <= go_b32 ? 2'd4 : (go_b16 ? 2'd2 : 2'd1);
			idx <= 2'd0;
			MA <= go_a[21:1];
			MWR_N <= go_we ? (go_a[0] ? 2'b01 : 2'b10) : 2'b11;
			MRD_N <= go_we ? 2'b11 : 2'b00;
		end
	end
	else if (is_ld) begin
		dsk_ack <= 1'b0;
		// previous loader byte was written during the last clock
		if (ld_req) begin
			// next byte: address/data change together, WE remains low
			a <= ld_addr;
			wd <= {24'd0, ld_data};
			MA <= ld_addr[21:1];
			MWR_N <= ld_addr[0] ? 2'b01 : 2'b10;
			MRD_N <= 2'b11;
		end
		else begin
			busy <= 1'b0;
			is_ld <= 1'b0;
			wr <= 1'b0;
			MWR_N <= 2'b11;
			MRD_N <= 2'b11;
		end
	end
	else begin
		dsk_ack <= 1'b0;
		// core access: sample the byte of the address driven last clock
		if (!wr)
			case (idx)
				2'd0: rdata[7:0]   <= md_byte;
				2'd1: rdata[15:8]  <= md_byte;
				2'd2: rdata[23:16] <= md_byte;
				2'd3: rdata[31:24] <= md_byte;
			endcase

		if (idx == nbytes - 2'd1) begin
			busy <= 1'b0;
			wr <= 1'b0;
			complete_r <= 1'b1;
			MWR_N <= 2'b11;
			MRD_N <= 2'b11;
		end
		else begin
			idx <= idx + 2'd1;
			MA <= next_addr[21:1];
			MWR_N <= wr ? (next_addr[0] ? 2'b01 : 2'b10) : 2'b11;
			MRD_N <= wr ? 2'b11 : 2'b00;
		end
	end
end

endmodule
`default_nettype wire

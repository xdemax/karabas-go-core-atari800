`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
-- xex_dma_loader.v
--
-- Parses a raw .xex that atari_atr_loader has already copied to external SRAM
-- at ATR_BASE (0x300000).  The XEX file bytes start at ATR_BASE+528 (the
-- synthetic loader's sector 5).  Segments are written directly into Atari RAM
-- through the same ld_* byte port used by atari_atr_loader, so BASIC/ROM
-- banking does not matter: the data goes to SRAM, and the boot stub turns
-- BASIC off before RUNAD.
--
-- After all segments, a 3-sector boot stub is written at ATR_BASE:
--   sector 1: 00 03 00 07 06 07 + 6502 code
--             LDA #$FD / STA $D301 / optional JSR (INITAD) / JMP (RUNAD)
-- This module holds the Atari in reset (busy) while it parses.
-------------------------------------------------------------------------------------------------------------------*/
module xex_dma_loader (
	input wire        clk,
	input wire        reset,

	input wire        start,          // atr_ready && xex_mode && !done
	input wire [31:0] size,           // raw XEX byte length
	output reg        busy,
	output reg        done,

	// SRAM read port (ATR file at 0x300000)
	output reg        rd_req,
	output reg [24:0] rd_addr,
	input wire [7:0]  rd_data,
	input wire        rd_ack,

	// SRAM write port (Atari RAM, addresses 0x000000..)
	output reg        ld_req,
	output reg [24:0] ld_addr,
	output reg [7:0]  ld_data,

	output reg [15:0] boot_ssize,
	output reg [31:0] boot_scount,
	output wire [4:0] state_dbg
);
assign state_dbg = state;

localparam [24:0] ATR_BASE = 25'h300000;
localparam [24:0] XEX_BASE = 25'h300000 + 25'd528;
localparam [8:0]  STUB_LEN = 9'd400;

localparam [4:0] S_IDLE = 5'd0;
localparam [4:0] S_RD   = 5'd1;
localparam [4:0] S_M1   = 5'd2;
localparam [4:0] S_M2   = 5'd3;
localparam [4:0] S_M3   = 5'd4;
localparam [4:0] S_E1   = 5'd5;
localparam [4:0] S_E2   = 5'd6;
localparam [4:0] S_E3   = 5'd7;
localparam [4:0] S_C1   = 5'd8;
localparam [4:0] S_C2   = 5'd9;
localparam [4:0] S_C3   = 5'd10;
localparam [4:0] S_STUB = 5'd11;

reg [4:0]  state = S_IDLE;
reg [4:0]  ret = S_IDLE;
reg [31:0] pos = 32'd0;
reg [15:0] start_addr = 16'd0;
reg [15:0] end_addr = 16'd0;
reg [15:0] dest = 16'd0;
reg [15:0] count = 16'd0;
reg [7:0]  b0 = 8'd0;
reg [7:0]  data = 8'd0;
reg [8:0]  stub_addr = 9'd0;
reg [15:0] run_addr = 16'd0;
reg [15:0] init_addr = 16'd0;
reg [15:0] first_addr = 16'd0;
reg        has_run = 1'b0;
reg        has_init = 1'b0;
reg        first_set = 1'b0;

wire [7:0] stub_data;
xex_boot_stub stub_rom (
	.addr (stub_addr),
	.d    (stub_data)
);

// The OS coldstart may clear $02E0/$02E2 before the stub runs.  Patch the
// stub's JMP operands with the addresses we saw in the XEX instead of using
// the (possibly cleared) zero-page vectors.
reg [7:0] stub_byte;
always @(*) begin
	stub_byte = stub_data;
	// JMP ($02E0) at stub offset 43 -> JMP <run|first segment>
	if (stub_addr == 9'd43 && (has_run || first_set)) stub_byte = 8'h4C;
	if (stub_addr == 9'd44 && (has_run || first_set)) stub_byte = has_run ? run_addr[7:0] : first_addr[7:0];
	if (stub_addr == 9'd45 && (has_run || first_set)) stub_byte = has_run ? run_addr[15:8] : first_addr[15:8];
	// JMP ($02E2) at stub offset 46 -> JMP <init>
	if (stub_addr == 9'd46 && has_init) stub_byte = 8'h4C;
	if (stub_addr == 9'd47 && has_init) stub_byte = init_addr[7:0];
	if (stub_addr == 9'd48 && has_init) stub_byte = init_addr[15:8];
	// If INITAD exists, do not test the (possibly cleared) $02E2: always JSR it.
	if (has_init && (stub_addr == 9'd33 || stub_addr == 9'd34)) stub_byte = 8'hEA;
end

always @(posedge clk) begin
	if (reset) begin
		state <= S_IDLE;
		ret <= S_IDLE;
		pos <= 32'd0;
		start_addr <= 16'd0;
		end_addr <= 16'd0;
		dest <= 16'd0;
		count <= 16'd0;
		b0 <= 8'd0;
		data <= 8'd0;
		stub_addr <= 9'd0;
		run_addr <= 16'd0;
		init_addr <= 16'd0;
		first_addr <= 16'd0;
		has_run <= 1'b0;
		has_init <= 1'b0;
		first_set <= 1'b0;
		busy <= 1'b0;
		done <= 1'b0;
		rd_req <= 1'b0;
		rd_addr <= 25'd0;
		ld_req <= 1'b0;
		ld_addr <= 25'd0;
		ld_data <= 8'd0;
		boot_ssize <= 16'd128;
		boot_scount <= 32'd0;
	end
	else begin
		rd_req <= 1'b0;
		ld_req <= 1'b0;

		case (state)
			S_IDLE: begin
				busy <= 1'b0;
				if (start && !busy) begin
					pos <= 32'd0;
					stub_addr <= 9'd0;
					run_addr <= 16'd0;
					init_addr <= 16'd0;
					first_addr <= 16'd0;
					has_run <= 1'b0;
					has_init <= 1'b0;
					first_set <= 1'b0;
					busy <= 1'b1;
					done <= 1'b0;
					state <= S_M1;
				end
			end

			// one byte read; ret says where to go after rd_ack
			S_RD: begin
				if (rd_ack) begin
					data <= rd_data;
					pos <= pos + 32'd1;
					rd_req <= 1'b0;
					state <= ret;
				end
			end

			S_M1: begin
				if (pos >= size) state <= S_STUB;
				else begin
					rd_addr <= XEX_BASE + pos[24:0];
					rd_req <= 1'b1;
					ret <= S_M2;
					state <= S_RD;
				end
			end
			S_M2: begin
				b0 <= data;
				if (pos >= size) state <= S_STUB;
				else begin
					rd_addr <= XEX_BASE + pos[24:0];
					rd_req <= 1'b1;
					ret <= S_M3;
					state <= S_RD;
				end
			end
			S_M3: begin
				if (b0 == 8'hFF && data == 8'hFF) begin
					state <= S_M1;           // segment separator
				end
				else begin
					start_addr <= {data, b0};
					state <= S_E1;
				end
			end

			S_E1: begin
				if (pos >= size) state <= S_STUB;
				else begin
					rd_addr <= XEX_BASE + pos[24:0];
					rd_req <= 1'b1;
					ret <= S_E2;
					state <= S_RD;
				end
			end
			S_E2: begin
				end_addr[7:0] <= data;
				if (pos >= size) state <= S_STUB;
				else begin
					rd_addr <= XEX_BASE + pos[24:0];
					rd_req <= 1'b1;
					ret <= S_E3;
					state <= S_RD;
				end
			end
			S_E3: begin
				end_addr[15:8] <= data;
				if (!first_set) begin
					first_addr <= start_addr;
					first_set <= 1'b1;
				end
				dest <= start_addr;
				count <= ({data, end_addr[7:0]} - start_addr) + 16'd1;
				if (start_addr == 16'd0 && {data, end_addr[7:0]} == 16'd0)
					state <= S_M1;           // ignore empty terminator segments
				else
					state <= S_C1;
			end

			S_C1: begin
				if (count == 16'd0) state <= S_M1;
				else if (pos >= size) state <= S_STUB;
				else begin
					rd_addr <= XEX_BASE + pos[24:0];
					rd_req <= 1'b1;
					ret <= S_C2;
					state <= S_RD;
				end
			end
			S_C2: begin
				ld_addr <= {9'd0, dest};
				ld_data <= data;
				ld_req <= 1'b1;
				if (dest == 16'h02E0) begin run_addr[7:0] <= data; has_run <= 1'b1; end
				if (dest == 16'h02E1) run_addr[15:8] <= data;
				if (dest == 16'h02E2) begin init_addr[7:0] <= data; has_init <= 1'b1; end
				if (dest == 16'h02E3) init_addr[15:8] <= data;
				state <= S_C3;
			end
			S_C3: begin
				dest <= dest + 16'd1;
				count <= count - 16'd1;
				state <= S_C1;
			end

			S_STUB: begin
				ld_addr <= ATR_BASE + {16'd0, stub_addr};
				ld_data <= stub_byte;
				ld_req <= 1'b1;
				if (stub_addr == STUB_LEN - 9'd1) begin
					stub_addr <= 9'd0;
					boot_ssize <= 16'd128;
					boot_scount <= 32'd3;
					busy <= 1'b0;
					done <= 1'b1;
					state <= S_IDLE;
				end
				else
					stub_addr <= stub_addr + 9'd1;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
`default_nettype wire

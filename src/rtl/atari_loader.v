`timescale 1ns / 1ps
`default_nettype none
/*-------------------------------------------------------------------------------------------------------------------
--
-- Cartridge file loader for the Karabas Go Atari core.
--
-- The MCU file loader (OSD `F`/`FL` items) sends a .car image byte by byte to the core in clk_host.  This
-- module stages the bytes in a small asynchronous FIFO and writes them to SRAM at 0x200000 + (offset - 16):
-- the 16-byte CAR header is not part of the cartridge image.  The CAR type is captured so a later build can
-- select the CartLogic mode automatically; the current top selects it from the OSD.
--
-------------------------------------------------------------------------------------------------------------------*/

module atari_loader (
	input wire        clk_host,
	input wire        clk,
	input wire        reset_host,      // power-on / PLL lock

	input wire        file_reset,
	input wire        file_active,
	input wire        file_wr,
	input wire [31:0] file_addr,
	input wire [7:0]  file_data,
	input wire [7:0]  file_slot,

	output wire        loading,        // clk_host: the machine must stay in reset
	output reg  [15:0] cart_type,      // CAR type, big-endian bytes 4..5/6..7

	// to atari_sram (clk)
	output wire        ld_req,
	output wire [24:0] ld_addr,
	output wire [7:0]  ld_data
);

localparam [7:0] SLOT_CART = 8'd0;

wire        fifo_wr;
wire [32:0] fifo_din;
wire        fifo_full;
wire        fifo_rd;
wire [32:0] fifo_dout;
wire        fifo_empty;
wire [4:0]  fifo_count;
wire        fifo_wreset = file_reset | reset_host;
wire        fifo_rreset = file_reset | reset_host;

// address inside the cartridge image: CAR header = 16 bytes
wire [24:0] cart_addr = 25'h200000 + {4'd0, file_addr[20:0]} - 25'd16;
assign fifo_wr  = file_active & file_wr & (file_slot == SLOT_CART) & (file_addr >= 32'd16);
assign fifo_din = {cart_addr, file_data};

kg_async_fifo #(.DW(33), .AW(4)) fifo (
	.wclk   (clk_host),
	.wreset (fifo_wreset),
	.wr     (fifo_wr),
	.din    (fifo_din),
	.full   (fifo_full),
	.rclk   (clk),
	.rreset (fifo_rreset),
	.rd     (fifo_rd),
	.dout   (fifo_dout),
	.empty  (fifo_empty),
	.rcount (fifo_count)
);

// dout is registered one clock after rd; shift the request through the same pipeline as the data
reg        rd_d1 = 1'b0, rd_d2 = 1'b0;
reg [24:0] ld_addr_r = 25'd0;
reg [7:0]  ld_data_r = 8'd0;

assign fifo_rd = ~fifo_empty;

always @(posedge clk) begin
	rd_d1 <= fifo_rd;
	rd_d2 <= rd_d1;
	if (rd_d1) begin
		ld_addr_r <= fifo_dout[32:8];
		ld_data_r <= fifo_dout[7:0];
	end
end

assign ld_req  = rd_d2;
assign ld_addr = ld_addr_r;
assign ld_data = ld_data_r;

// CAR header: bytes 4..7 are the 32-bit big-endian type.  Keep the low 16 bits.
always @(posedge clk_host) begin
	if (file_reset || reset_host)
		cart_type <= 16'd0;
	else if (file_active && file_wr && (file_slot == SLOT_CART)) begin
		case (file_addr[2:0])
			3'd4: cart_type[15:8] <= file_data;
			3'd5: cart_type[7:0]  <= file_data;
			default: ;
		endcase
	end
end

// loading: high from file_reset through file_active; the top adds a short hold after it falls
reg loading_r = 1'b0;
always @(posedge clk_host) begin
	if (reset_host)
		loading_r <= 1'b0;
	else if (file_reset && file_slot == SLOT_CART)
		loading_r <= 1'b1;
	else if (file_active && file_slot == SLOT_CART)
		loading_r <= 1'b1;
	else if (!file_active)
		loading_r <= 1'b0;
end
assign loading = loading_r;

endmodule
`default_nettype wire

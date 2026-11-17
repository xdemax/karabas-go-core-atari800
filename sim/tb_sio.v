`timescale 1ns / 1ps
// Testbench for the revised 1050 responder: command frame (POKEY-like clock),
// then 'A' 0x41, 'C' 0x43, status/read data and a checksum with end-around carry.
module tb_sio;

reg clk = 1'b0;
always #17.5 clk = ~clk;          // 28.571 MHz

localparam integer BITC = 1488;   // 19200 baud at this clock

reg reset = 1'b1;
reg sio_command = 1'b1;
reg sio_txd = 1'b1;
reg sio_clock = 1'b0;
wire sio_rxd;

wire        dsk_req;
wire [24:0] dsk_addr;
wire [7:0]  dsk_data;
reg         dsk_ack = 1'b0;

assign dsk_data = dsk_addr[7:0] ^ 8'h5A;
always @(posedge clk) dsk_ack <= dsk_req && !dsk_ack;

atari_sio_disk dut (
	.clk        (clk),
	.reset      (reset),
	.atr_ssize  (16'd256),
	.atr_scount (32'd720),
	.atr_ready  (1'b1),
	.sio_command(sio_command),
	.sio_txd    (sio_txd),
	.sio_clock  (sio_clock),
	.sio_rxd    (sio_rxd),
	.dsk_req    (dsk_req),
	.dsk_addr   (dsk_addr),
	.dsk_data   (dsk_data),
	.dsk_ack    (dsk_ack)
);

function [7:0] ck;
	input [7:0] s;
	input [7:0] b;
	reg [8:0] t;
	begin
		t = {1'b0, s} + {1'b0, b};
		ck = t[7:0] + {7'd0, t[8]};
	end
endfunction

// POKEY-like command frame: clock idle low, data changes on the rising edge,
// the drive samples on the falling edge (the module has rx_skip for the start).
localparam integer T = 2000;
task send_bit(input v);
begin
	sio_clock = 1'b1;
	sio_txd = v;
	#(T/2);
	sio_clock = 1'b0;
	#(T/2);
end
endtask

task send_byte(input [7:0] v);
integer k;
begin
	send_bit(1'b0);                 // start
	for (k = 0; k < 8; k = k + 1)
		send_bit(v[k]);
	send_bit(1'b1);                 // stop
end
endtask


// UART receiver for the answer: the module uses its internal 19200 timer.
task rx_byte(output [7:0] v);
integer k;
begin
	@(negedge sio_rxd);
	repeat (BITC + BITC/2) @(posedge clk);
	for (k = 0; k < 8; k = k + 1) begin
		v[k] = sio_rxd;
		repeat (BITC) @(posedge clk);
	end
	repeat (BITC/2) @(posedge clk);
end
endtask

integer errors = 0;
reg [7:0] a, c, b0, b1, b2, b3, cs, got;
reg [7:0] sum;
integer i;

initial begin
	#500_000_000;
	$display("TIMEOUT");
	$finish;
end

initial begin
	#200 reset = 1'b0;
	#2000;

	// ---- command S (status), D1: 31 53 00 00 84 ----
	sio_command = 1'b0;
	send_byte(8'h31);
	send_byte(8'h53);
	send_byte(8'h00);
	send_byte(8'h00);
	send_byte(8'h84);
	sio_command = 1'b1;

	rx_byte(a);
	rx_byte(c);
	for (i = 0; i < 4; i = i + 1) begin
		rx_byte(got);
		if (i == 0) b0 = got;
		else if (i == 1) b1 = got;
		else if (i == 2) b2 = got;
		else b3 = got;
	end
	rx_byte(cs);
	$display("S: A=%h C=%h status=%h %h %h %h cks=%h", a, c, b0, b1, b2, b3, cs);
	if (a !== 8'h41 || c !== 8'h43) begin $display("ERROR S: no A/C"); errors=errors+1; end
	if (b0 !== 8'h30 || b1 !== 8'hFF || b2 !== 8'hE0 || b3 !== 8'h00) begin
		$display("ERROR S: status bytes for 256-byte ATR"); errors=errors+1;
	end
	#2_000_000;
	if (sio_rxd !== 1'b1) begin $display("ERROR S: extra byte after checksum"); errors=errors+1; end
	sum = ck(ck(ck(b0, b1), b2), b3);
	if (cs !== sum) begin $display("ERROR S checksum: got %h want %h", cs, sum); errors=errors+1; end

	#50000;

	// ---- command R, sector 1: 31 52 01 00 84 ----
	sio_command = 1'b0;
	send_byte(8'h31);
	send_byte(8'h52);
	send_byte(8'h01);
	send_byte(8'h00);
	send_byte(8'h84);
	sio_command = 1'b1;

	rx_byte(a);
	rx_byte(c);
	$display("R: A=%h C=%h", a, c);
	if (a !== 8'h41 || c !== 8'h43) begin $display("ERROR R: no A/C"); errors=errors+1; end
	sum = 8'd0;
	for (i = 0; i < 128; i = i + 1) begin
		rx_byte(got);
		sum = ck(sum, got);
		if (got !== ((8'h10 + i[7:0]) ^ 8'h5A)) begin
			$display("ERROR R byte %0d: got %h", i, got);
			errors=errors+1;
		end
	end
	rx_byte(cs);
	if (cs !== sum) begin $display("ERROR R checksum: got %h want %h", cs, sum); errors=errors+1; end
	#2_000_000;
	if (sio_rxd !== 1'b1) begin $display("ERROR R: extra byte after checksum"); errors=errors+1; end

	// ---- command R, sector 4 (256-byte data area) ----
	sio_command = 1'b0;
	send_byte(8'h31);
	send_byte(8'h52);
	send_byte(8'h04);
	send_byte(8'h00);
	send_byte(8'h87);
	sio_command = 1'b1;

	rx_byte(a);
	rx_byte(c);
	$display("R4: A=%h C=%h", a, c);
	if (a !== 8'h41 || c !== 8'h43) begin $display("ERROR R4: no A/C"); errors=errors+1; end
	sum = 8'd0;
	for (i = 0; i < 256; i = i + 1) begin
		rx_byte(got);
		sum = ck(sum, got);
		if (got !== ((8'h90 + i[7:0]) ^ 8'h5A)) begin
			$display("ERROR R4 byte %0d: got %h", i, got);
			errors=errors+1;
		end
	end
	rx_byte(cs);
	if (cs !== sum) begin $display("ERROR R4 checksum: got %h want %h", cs, sum); errors=errors+1; end
	#2_000_000;
	if (sio_rxd !== 1'b1) begin $display("ERROR R4: extra byte after checksum"); errors=errors+1; end

	if (errors == 0) $display("tb_sio: 0 errors");
	else             $display("tb_sio: %0d errors", errors);
	$finish;
end

endmodule

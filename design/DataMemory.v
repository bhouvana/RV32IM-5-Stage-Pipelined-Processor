`default_nettype none

module DataMemory #(
	parameter SIZE_BYTES = 128   // was a hardcoded 128 throughout; now threaded
	                              // from PIPELINED so FPGA/research-platform
	                              // configs (docs/ROADMAP.md Phase 6/7) can pick
	                              // a different size without editing this file.
)(
	input rst,
	input clk,
	input memWrite,
	input memRead,
	input [31:0] address,
	input [31:0] writeData,
	input [2:0] funct3,   // access width/signedness: 000=b(signed) 001=h(signed) 010=w 100=bu 101=hu
	output reg [31:0] readData
);

	reg [7:0] data_memory [0:SIZE_BYTES-1];
	integer rst_i;
	always @ (posedge clk) begin
		if(~rst) begin
			for (rst_i = 0; rst_i < SIZE_BYTES; rst_i = rst_i + 1)
				data_memory[rst_i] <= 8'b0;
		end
		else begin
			if(memWrite) begin
				// funct3[1:0]: 00=sb, 01=sh, 10=sw (funct3[2] unused for stores)
				case(funct3[1:0])
					2'b00: begin // sb
						data_memory[address] <= writeData[7:0];
					end
					2'b01: begin // sh
						data_memory[address + 1] <= writeData[15:8];
						data_memory[address]     <= writeData[7:0];
					end
					default: begin // sw
						data_memory[address + 3] <= writeData[31:24];
						data_memory[address + 2] <= writeData[23:16];
						data_memory[address + 1] <= writeData[15:8];
						data_memory[address]     <= writeData[7:0];
					end
				endcase
			end

			end
	end

	always @(*) begin
		if(memRead) begin
			// funct3: 000=lb 001=lh 010=lw 100=lbu 101=lhu
			case(funct3)
				3'b000: readData = {{24{data_memory[address][7]}}, data_memory[address]};                      //lb
				3'b100: readData = {24'b0, data_memory[address]};                                               //lbu
				3'b001: readData = {{16{data_memory[address+1][7]}}, data_memory[address+1], data_memory[address]}; //lh
				3'b101: readData = {16'b0, data_memory[address+1], data_memory[address]};                       //lhu
				default: readData = {data_memory[address+3], data_memory[address+2], data_memory[address+1], data_memory[address]}; //lw
			endcase
		end
		else begin
			readData          = 32'b0;
		end
	end

endmodule

`default_nettype wire

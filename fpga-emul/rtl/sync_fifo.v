// sync_fifo.v
// Synchronous FIFO using distributed RAM (LUTRAM) for combinational read output.
// Using distributed RAM avoids the 1-cycle BRAM read latency, allowing the AXI
// peripheral to read FIFO head data and advance the pointer in the same cycle.
//
// Parameters:
//   DATA_W  data width  (default 64)
//   ADDR_W  log2(depth) (default 8 → 256 entries)
//
// Read protocol (FWFT — First Word Fall Through):
//   rd_data reflects the current head combinatorially.
//   Assert rd_en for one cycle to advance the read pointer.
//   rd_data updates combinatorially the same cycle rd_en is asserted.
//   Do NOT assert rd_en when empty.
//
// Write protocol:
//   Assert wr_en with wr_data. Ignored when full.

`default_nettype none

module sync_fifo #(
    parameter DATA_W = 64,
    parameter ADDR_W = 8    // depth = 2^ADDR_W
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,

    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty,
    output wire              half
);
    localparam DEPTH = 1 << ADDR_W;

    // Distributed RAM: combinational read port
    (* ram_style = "distributed" *)
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [ADDR_W:0] wr_ptr;   // one extra bit for full/empty
    reg [ADDR_W:0] rd_ptr;

    wire [ADDR_W-1:0] wr_addr = wr_ptr[ADDR_W-1:0];
    wire [ADDR_W-1:0] rd_addr = rd_ptr[ADDR_W-1:0];

    assign full  = (wr_ptr[ADDR_W] != rd_ptr[ADDR_W]) &&
                   (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);
    assign empty = (wr_ptr == rd_ptr);
    assign half  = ({1'b0, wr_ptr} - {1'b0, rd_ptr}) >= DEPTH[ADDR_W:0] >> 1;

    // Combinational read (distributed RAM → no latency)
    assign rd_data = mem[rd_addr];

    // Write (synchronous)
    always @(posedge clk) begin
        if (wr_en && !full)
            mem[wr_addr] <= wr_data;
    end

    // Pointer update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (wr_en && !full)  wr_ptr <= wr_ptr + 1'b1;
            if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule
`default_nettype wire

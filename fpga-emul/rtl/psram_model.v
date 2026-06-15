// psram_model.v
// Synthesizable BRAM-backed behavioral model of the APS6404L PSRAM, sufficient
// for the subset of QPI transactions that psram_buf_ctrl issues. Used on the
// Arty A7 FPGA emulation in place of a real PSRAM chip (the PSRAM PMOD board is
// not yet available). Drop-in for the psram_buf_ctrl QPI pad interface.
//
// Modelled QPI commands (the only ones psram_buf_ctrl uses after QE init):
//   0x02  quad write : cmd(2 nib) + addr(6 nib) + data(N×2 nib)
//   0xEB  fast read  : cmd(2 nib) + addr(6 nib) + 6 dummy + data(N×2 nib)
// SPI-mode init bytes (0x66/0x99/0x35) are ignored — in SPI mode sio carries a
// single bit (nibble 0x0/0x1), so the 0x2/0xE/0xB nibbles of the QPI commands
// can never appear and the model never mis-triggers on init.
//
// Same clock domain as psram_buf_ctrl (clk_32m). psram_buf_ctrl gates
// sck = sck_en & clk_32m and drives/samples on clk_32m edges; this model is
// clocked on clk_32m too and tracks the transaction by counting cycles from the
// ce_n falling edge, so there is no asynchronous sck sampling. `sck` is left
// unconnected here (only needed for a real chip).
//
// Storage: MEM_BYTES (power of two) bytes. psram_buf_ctrl uses a circular
// region whose span (max delay distance N×8 + replay packet) is far smaller than
// the 8 MB address space, so the address is simply masked to MEM_BYTES. Default
// 64 KB covers SF up to 12 (delay 32 KB) with margin and is cheap in BRAM.

`default_nettype none
module psram_model #(
    parameter ADDR_BITS = 16,                 // 2^16 = 64 KB
    // Cycles to wait after the controller releases the bus (sio_oe→0) before the
    // model launches read data, so the first data nibble is stable at the
    // controller's first sio_in sampling edge. Tuned in simulation against
    // psram_buf_ctrl's 6-dummy-cycle read timing.
    parameter RD_LAUNCH_SKIP = 3   // validated in tb_psram_model cosim (0 errors)
) (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire        ce_n,        // from psram_buf_ctrl
    input  wire [3:0]  sio_out,     // controller → model (valid when sio_oe=1)
    input  wire [3:0]  sio_oe,      // 1 = controller driving, 0 = model drives
    output reg  [3:0]  sio_in       // model → controller (read data)
);
    localparam MEM_BYTES = (1 << ADDR_BITS);

    // Byte-wide memory (BRAM-inferable).
    reg [7:0] mem [0:MEM_BYTES-1];

    // Transaction tracking.
    reg        active;          // ce_n low (a transaction in progress)
    reg [7:0]  cmd;             // assembled command byte
    reg [22:0] addr;            // assembled 23-bit address (masked on access)
    reg [5:0]  nib;             // nibble index since ce_n fell
    reg        is_write;
    reg        is_read;
    reg        oe_released;     // saw sio_oe go to 0 during a read
    reg [5:0]  rd_skip;         // countdown after bus release before driving data
    reg [3:0]  rd_started;      // read-data nibble index once launched (0 = not yet)
    reg [3:0]  wr_hi;           // high-nibble stash for writes

    wire [ADDR_BITS-1:0] amask = addr[ADDR_BITS-1:0];

    integer i;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            active      <= 1'b0;
            cmd         <= 8'h0;
            addr        <= 23'h0;
            nib         <= 6'd0;
            is_write    <= 1'b0;
            is_read     <= 1'b0;
            oe_released <= 1'b0;
            rd_skip     <= 6'd0;
            rd_started  <= 4'd0;
            wr_hi       <= 4'h0;
            sio_in      <= 4'h0;
        end else begin
            if (ce_n) begin
                // Idle / between transactions.
                active      <= 1'b0;
                nib         <= 6'd0;
                is_write    <= 1'b0;
                is_read     <= 1'b0;
                oe_released <= 1'b0;
                rd_started  <= 4'd0;
            end else begin
                // ce_n low — a transaction is active.
                active <= 1'b1;
                nib    <= nib + 6'd1;

                // ---- Command + address assembly (first 8 nibbles) ----
                if (nib == 6'd0) cmd[7:4] <= sio_out;
                if (nib == 6'd1) begin
                    cmd[3:0] <= sio_out;
                    is_write <= ({cmd[7:4], sio_out} == 8'h02);
                    is_read  <= ({cmd[7:4], sio_out} == 8'hEB);
                end
                // address nibbles 2..7 (MSN first)
                if (nib >= 6'd2 && nib <= 6'd7)
                    addr <= {addr[18:0], sio_out};

                // ---- WRITE: data nibbles from nib==8 onward ----
                // Each byte = two nibbles; high nibble first. Write on the low
                // nibble of each pair, incrementing the address per byte.
                if (is_write && nib >= 6'd8) begin
                    if (nib[0] == 1'b0) begin
                        // high nibble cycle: stash
                        wr_hi <= sio_out;
                    end else begin
                        mem[(amask + ((nib - 6'd9) >> 1)) % MEM_BYTES] <= {wr_hi, sio_out};
                    end
                end

                // ---- READ: wait for bus release, then drive data ----
                if (is_read) begin
                    if (sio_oe == 4'h0) begin
                        if (!oe_released) begin
                            oe_released <= 1'b1;
                            rd_skip     <= RD_LAUNCH_SKIP[5:0];
                        end else if (rd_skip != 6'd0) begin
                            rd_skip <= rd_skip - 6'd1;
                        end else begin
                            // Launch read data, high nibble then low nibble per byte.
                            sio_in     <= rd_started[0] ?
                                          mem[(amask + (rd_started >> 1)) % MEM_BYTES][3:0] :
                                          mem[(amask + (rd_started >> 1)) % MEM_BYTES][7:4];
                            rd_started <= rd_started + 4'd1;
                        end
                    end
                end
            end
        end
    end

endmodule
`default_nettype wire

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
    parameter RD_LAUNCH_SKIP = 5,
    // Open Risks #72 (2026-09-14): minimum whole clk_32m cycles that must
    // elapse between the model launching its last valid read-data nibble
    // and CE# rising, modelling (in cycle-count terms, not real ns -- see
    // the CE_HOLD_CYCLES block below for why) a real chip's finite
    // output-hold-time-after-CE# requirement. The model previously had NO
    // such requirement at all (see the block's own header comment), which
    // is why every simulation using it was structurally blind to the
    // same-cycle CE#-deassert/final-nibble-capture pattern static RTL
    // review found in psram_buf_ctrl.v's three read state machines. Set to
    // 0 to restore the old (unenforced) behaviour.
    parameter CE_HOLD_CYCLES = 1
) (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire        ce_n,        // from psram_buf_ctrl
    input  wire [3:0]  sio_out,     // controller → model (valid when sio_oe=1)
    input  wire [3:0]  sio_oe,      // 1 = controller driving, 0 = model drives
    output reg  [3:0]  sio_in,      // model → controller (read data)
    input  wire        sck,         // real gated PSRAM clock
    input  wire        sck_en       // raw (non-clock-gated) SCK enable -- see
                                     // the 2026-09-14 fix comment below for why
                                     // the main transaction logic gates on this
                                     // instead of `sck`
);
    // Nibble-addressed memory: every QPI access moves exactly one 4-bit nibble,
    // so a single full-word read/write per cycle keeps this a clean, inferable
    // simple-dual-port BRAM (byte-addressed sub-field reads do not infer).
    localparam NADDR = ADDR_BITS + 1;          // nibble-address width
    reg [3:0] mem [0:(1<<NADDR)-1];

    // sio_in has no reset (see the dedicated BRAM-inferable block below) — its
    // FPGA power-up value comes from this initial block, which Vivado
    // synthesizes as the flop's INIT value rather than reset logic. Xilinx
    // 7-series BRAM output registers don't support async reset; mixing one
    // into the same process as the mem[] array (as the control FSM below
    // does for everything else) prevented BRAM inference entirely — Vivado
    // fell back to trying 524288 individual flip-flops and failed.
    initial sio_in = 4'h0;

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

    // 2026-09-14 fix: `sck` (as wired from the testbench) is a live
    // `sck_en_q & clk` signal derived combinationally from the exact same
    // clock this model's own main always block triggers on -- a
    // self-referential gated-clock race (the same class of hazard as the
    // real-hardware `ps_sck` aliasing found in Open Risks #72's ILA
    // captures this session, but here causing a simulator race: Icarus was
    // observed to never see `sck` go high in this block, so `active` never
    // asserted and writes/reads silently never touched `mem[]`). A first
    // attempt to fix this by capturing `sck` on the opposite (negedge)
    // clock edge was itself wrong: `clk` is deterministically 0 at its own
    // negedge, so `sck_en_q & clk` sampled there is *always* 0, not merely
    // racy. The real fix needs the raw enable, not the clock-gated pin --
    // `sck_en` (new port, see the port list) is wired by the testbench to
    // trouper_top's internal `psram_sck_en_q` register (a plain registered
    // value, not clock-derived, so race-free against this model's own
    // posedge clk_32m sampling). The original `sck` port is kept for any
    // guardrail/monitor that needs the true gated-clock level.

    wire [ADDR_BITS-1:0] amask = addr[ADDR_BITS-1:0];

    // Nibble addresses: byte address × 2 + nibble-within-transaction. Width
    // NADDR so the carry-out gives the (power-of-two) circular wrap for free.
    wire [NADDR-1:0] wr_naddr = ({amask, 1'b0}) + (nib - 6'd8);
    wire [NADDR-1:0] rd_naddr = ({amask, 1'b0}) + rd_started;

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
        end else begin
            if (ce_n) begin
                // Idle / between transactions.
                active      <= 1'b0;
                nib         <= 6'd0;
                is_write    <= 1'b0;
                is_read     <= 1'b0;
                oe_released <= 1'b0;
                rd_started  <= 4'd0;
            end else if (sck_en) begin
                // Only advance on a forwarded-SCK rising edge; CE# can remain
                // low while SCK is stopped for write termination.
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

                // ---- READ: wait for bus release, then drive one nibble/cycle ----
                if (is_read) begin
                    if (sio_oe == 4'h0) begin
                        if (!oe_released) begin
                            oe_released <= 1'b1;
                            rd_skip     <= RD_LAUNCH_SKIP[5:0];
                        end else if (rd_skip != 6'd0) begin
                            rd_skip <= rd_skip - 6'd1;
                        end else begin
                            rd_started <= rd_started + 4'd1;
                        end
                    end
                end
            end
        end
    end

    // ---- Dedicated BRAM-inferable memory access: no reset, no other logic
    //      mixed in (see the initial block above for sio_in's power-up value).
    wire wr_en = sck_en && is_write && (nib >= 6'd8);
    wire rd_en = sck_en && is_read && (sio_oe == 4'h0) && oe_released && (rd_skip == 6'd0);

    // ---- CE# hold-time enforcement (Open Risks #72, 2026-09-14) ----------
    // A separate always block (own registers, no shared drivers with either
    // block above) tracking whole clk_32m cycles since the last valid read
    // nibble was launched onto sio_in via rd_en. If CE# rises (ce_n high)
    // while fewer than CE_HOLD_CYCLES have elapsed since that launch, the
    // transaction is flagged and, from the following cycle, sio_in is
    // forced to X -- modelling the real chip's output going invalid before
    // the controller could safely have captured it. This is a cycle-count
    // stand-in for a true real-time (ns) hold-time model, not the real
    // datasheet tCPH/output-disable figure -- it tests whether the RTL's
    // DISCRETE state-machine sequencing provides at least one full cycle of
    // margin (which the proposed RTL fix would add), not whether that
    // margin is enough in real nanoseconds. Set CE_HOLD_CYCLES=0 to restore
    // the old, unenforced behaviour.
    reg [7:0] cyc_since_rd;
    reg       hold_violation;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            cyc_since_rd   <= 8'd0;
            hold_violation <= 1'b0;
        end else if (ce_n) begin
            if (active && is_read && oe_released &&
                (cyc_since_rd < CE_HOLD_CYCLES[7:0])) begin
                hold_violation <= 1'b1;
                // synthesis translate_off
                $display("%0t %m: PSRAM_MODEL CE_HOLD_CYCLES VIOLATION -- ce_n rose %0d cycle(s) after the last read-data nibble launch (need >= %0d). Modelling as a corrupted read.",
                          $time, cyc_since_rd, CE_HOLD_CYCLES);
                // synthesis translate_on
            end
            cyc_since_rd <= 8'd0;
        end else if (rd_en) begin
            hold_violation <= 1'b0;
            cyc_since_rd   <= 8'd0;
        end else if (active) begin
            hold_violation <= 1'b0;
            cyc_since_rd   <= cyc_since_rd + 8'd1;
        end
    end

    always @(posedge clk_32m) begin
        if (wr_en) mem[wr_naddr] <= sio_out;
        if (hold_violation)      sio_in <= 4'bxxxx;
        else if (rd_en)          sio_in <= mem[rd_naddr];
    end

endmodule
`default_nettype wire

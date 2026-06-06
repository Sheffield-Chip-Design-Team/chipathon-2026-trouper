// irq_ctrl.v
// Interrupt controller: collects sticky IRQ sources, routes to PicoRV32 and IRQ pad.
// Mirrors IRQ_STATUS (0x32) / IRQ_CLEAR (0x33) in the register bank.
// All sources are in the 32 MHz domain — no CDC required.
// GF180MCU, 3.3V, 32 MHz single clock domain

module irq_ctrl (
    input  wire       clk_32m,
    input  wire       rst_n,

    // Interrupt sources (level; latch rising edge into sticky bits)
    input  wire       corr_lock,        // [0] preamble detected
    input  wire       training_done,    // [1] training accumulation complete
    input  wire       W_missed_packet,  // [2] W not committed before packet end
    input  wire       packet_done,      // [3] FSM returned to IDLE
    input  wire       noise_ready,      // [4] noise-window accumulation complete
    input  wire       tx_prep,          // [5] host requests TX prep
    input  wire       tx_done,          // [6] host signals TX complete

    // IRQ output (level-high; drives PicoRV32 IRQ and TCK_IRQ pad when JTAG_EN=0)
    output wire       irq_out,

    // AHB-Lite slave port (from ahb_lite_bus slave 2)
    input  wire [7:0] s_addr,
    input  wire [7:0] s_wdata,
    input  wire       s_we,
    input  wire       s_re,
    output reg  [7:0] s_rdata,
    output wire       s_ready           // always 1 (single-cycle response)
);

    assign s_ready = 1'b1;

    // Sticky interrupt status register
    // [0]=corr_lock [1]=training_done [2]=W_missed_packet [3]=packet_done
    // [4]=noise_ready [5]=tx_prep    [6]=tx_done
    reg [6:0] irq_status;

    // Previous-cycle source levels for rising-edge detection
    reg [6:0] src_prev;
    wire [6:0] src = {tx_done, tx_prep, noise_ready, packet_done,
                      W_missed_packet, training_done, corr_lock};

    assign irq_out = |irq_status;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            irq_status <= 7'd0;
            src_prev   <= 7'd0;
            s_rdata    <= 8'd0;
        end else begin
            src_prev <= src;

            // Set sticky bits on rising edge of each source
            irq_status <= irq_status | (src & ~src_prev);

            // Write-1-to-clear via AHB-Lite (addr 0x01 = IRQ_CLEAR offset)
            if (s_we && s_addr == 8'h01)
                irq_status <= (irq_status | (src & ~src_prev)) & ~s_wdata[6:0];

            // Read (addr 0x00 = IRQ_STATUS offset, any other addr returns 0)
            if (s_re)
                s_rdata <= (s_addr == 8'h00) ? {1'b0, irq_status} : 8'h00;
        end
    end

endmodule

// ahb_lite_bus.v
// Single-master AHB-Lite interconnect: PicoRV32 → 4 peripheral slaves
// Peripheral base: 0x10000–0x103FF
//   0x10000–0x100FF  Slave 0: register bank
//   0x10100–0x101FF  Slave 1: SPI master
//   0x10200–0x102FF  Slave 2: IRQ controller
//   0x10300–0x103FF  Slave 3: JTAG/SWD TAP
// Data bus: 32-bit (PicoRV32 native); registers are byte-granularity internally.
// GF180MCU, 3.3V, 32 MHz single clock domain

module ahb_lite_bus (
    input  wire        HCLK,
    input  wire        HRESETn,

    // AHB-Lite master port (from PicoRV32 wrapper)
    input  wire [31:0] HADDR,
    input  wire [1:0]  HTRANS,    // 00=IDLE, 10=NONSEQ, 11=SEQ
    input  wire        HWRITE,
    input  wire [2:0]  HSIZE,
    input  wire [2:0]  HBURST,
    input  wire [31:0] HWDATA,
    output reg  [31:0] HRDATA,
    output wire        HREADY,
    output wire        HRESP,     // always 0 (OKAY) — no error responses

    // Slave 0: register bank (addr[7:0], byte data)
    output reg  [7:0]  s0_addr,
    output reg  [7:0]  s0_wdata,
    output reg         s0_we,
    output reg         s0_re,
    input  wire [7:0]  s0_rdata,
    input  wire        s0_ready,  // 1 = ready (0 = insert wait)

    // Slave 1: SPI master (addr[7:0], byte data)
    output reg  [7:0]  s1_addr,
    output reg  [7:0]  s1_wdata,
    output reg         s1_we,
    output reg         s1_re,
    input  wire [7:0]  s1_rdata,
    input  wire        s1_ready,

    // Slave 2: IRQ controller (addr[7:0], byte data)
    output reg  [7:0]  s2_addr,
    output reg  [7:0]  s2_wdata,
    output reg         s2_we,
    output reg         s2_re,
    input  wire [7:0]  s2_rdata,
    input  wire        s2_ready,

    // Slave 3: JTAG/SWD TAP (addr[7:0], byte data)
    output reg  [7:0]  s3_addr,
    output reg  [7:0]  s3_wdata,
    output reg         s3_we,
    output reg         s3_re,
    input  wire [7:0]  s3_rdata,
    input  wire        s3_ready
);

    // AHB-Lite HTRANS encoding
    localparam HTRANS_IDLE   = 2'b00;
    localparam HTRANS_NONSEQ = 2'b10;
    localparam HTRANS_SEQ    = 2'b11;

    // Peripheral address window: 0x10000–0x103FF
    localparam PERIPH_BASE = 32'h10000;
    localparam PERIPH_TOP  = 32'h103FF;

    // HRESP always OKAY
    assign HRESP = 1'b0;

    // -----------------------------------------------------------------------
    // Address phase pipeline register
    // -----------------------------------------------------------------------
    reg [31:0] addr_lat;
    reg        write_lat;
    reg        valid_lat;   // latched transfer is valid (HTRANS was NONSEQ/SEQ)
    reg [1:0]  sel_lat;     // latched slave select

    wire in_periph = (HADDR >= PERIPH_BASE) && (HADDR <= PERIPH_TOP);
    wire [1:0] slave_sel = HADDR[9:8];   // within 0x10000 base: [9:8] pick slave
    wire xfer_active = (HTRANS == HTRANS_NONSEQ || HTRANS == HTRANS_SEQ);

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_lat  <= 32'd0;
            write_lat <= 1'b0;
            valid_lat <= 1'b0;
            sel_lat   <= 2'd0;
        end else if (HREADY) begin
            addr_lat  <= HADDR;
            write_lat <= HWRITE;
            valid_lat <= xfer_active && in_periph;
            sel_lat   <= slave_sel;
        end
    end

    // -----------------------------------------------------------------------
    // Data phase: drive slave strobes and mux read data
    // -----------------------------------------------------------------------
    wire [7:0] addr_byte = addr_lat[7:0];   // byte address within slave
    wire [7:0] wbyte     = HWDATA[7:0];     // PicoRV32 drives byte in [7:0] for byte ops

    // Active slave ready
    wire sel_ready = (sel_lat == 2'd0) ? s0_ready :
                     (sel_lat == 2'd1) ? s1_ready :
                     (sel_lat == 2'd2) ? s2_ready :
                                         s3_ready;

    assign HREADY = !valid_lat | sel_ready;

    // Drive slave ports
    always @(*) begin
        // Defaults
        s0_addr = addr_byte; s0_wdata = wbyte; s0_we = 1'b0; s0_re = 1'b0;
        s1_addr = addr_byte; s1_wdata = wbyte; s1_we = 1'b0; s1_re = 1'b0;
        s2_addr = addr_byte; s2_wdata = wbyte; s2_we = 1'b0; s2_re = 1'b0;
        s3_addr = addr_byte; s3_wdata = wbyte; s3_we = 1'b0; s3_re = 1'b0;

        if (valid_lat) begin
            case (sel_lat)
                2'd0: begin s0_we = write_lat; s0_re = !write_lat; end
                2'd1: begin s1_we = write_lat; s1_re = !write_lat; end
                2'd2: begin s2_we = write_lat; s2_re = !write_lat; end
                2'd3: begin s3_we = write_lat; s3_re = !write_lat; end
            endcase
        end
    end

    // Read data mux
    always @(*) begin
        case (sel_lat)
            2'd0: HRDATA = {24'h0, s0_rdata};
            2'd1: HRDATA = {24'h0, s1_rdata};
            2'd2: HRDATA = {24'h0, s2_rdata};
            2'd3: HRDATA = {24'h0, s3_rdata};
            default: HRDATA = 32'h0;
        endcase
    end

endmodule

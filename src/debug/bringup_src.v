// bringup_src.v
// Deterministic bring-up sample source (BRINGUP_SRC).
//
// Injects a known 500 kS/s complex sample stream at the RE-MODULATOR input so
// sd_remod can be proven on first silicon without a working frontend,
// Schmidl-Cox acquisition, PSRAM replay path, or combiner.  See
// planning/foundational-block-bringup-plan.md.
//
// INSERTION POINT: sd_remod input (trouper_top.v stage 9).  This was moved from
// the combiner input after the coverage work showed that point bought nothing.
// The argument for injecting at the combiner had been that one generator would
// then prove both blocks -- bypass is a bit-exact passthrough, and MRC mode
// would additionally exercise the MAC, the acc >>> (8 - pgs) shift and
// saturation.  The MRC half is unreachable:
//   trouper_top.v  W_valid <= 1 on W_valid_set, else 0 while !packet_active
//   trouper_top.v  bringup_en_q = ctrl[0] && rx_hold && !packet_active
// W_valid is held only DURING a packet and the armed source requires there to
// be none, so W_valid survives at most one clock after the W_valid_set pulse,
// and mrc_combiner latches use_mrc_r only at a burst start -- one clock in 64.
// That left the bypass passthrough as the entire combiner surface on offer: a
// wire.  Injecting after the combiner proves the same thing with a 3-point mux
// instead of a 9-point one (4 branches x 2 rails + valid), and isolates the
// re-modulator properly -- a bad 1-bit stream now implicates sd_remod alone,
// where before it implicated sd_remod OR the bypass path with no way to tell
// which from the pads.
//
// The generator takes ABSOLUTE priority at that mux, ahead of both
// psram_silence and REMOD_BACKOFF_SHIFT; the reasoning is at the mux itself.
// The amplitude clamp below is what makes skipping the backoff safe.
//
// Safety: `en` is qualified upstream by rx_hold && !packet_active, and reset
// selects the normal path (en=0 => sel=0).  The generator owns its own valid
// cadence because the whole point is to run with the IQ pads dead.
//
// GF180MCU, 3.3V, 32 MHz IQ_CLK domain.

`timescale 1ns/100ps

module bringup_src #(
    // Output sample cadence in 32 MHz clocks.  R=64 matches the decimator's
    // 500 kS/s output rate, so downstream pacing is unchanged.
    parameter integer DECIM = 64
) (
    input  wire               clk,
    input  wire               rst_n,

    // Qualified enable.  Must already include rx_hold && !packet_active.
    input  wire               en,
    // 0 = zero, 1 = signed DC, 2 = repeating complex tone (fs/4), 3 = PRBS.
    input  wire [1:0]         mode,
    // Sample amplitude, clamped to +/-64 (AMPL_MAX) before use.
    input  wire signed [7:0]  ampl,

    output reg  signed [7:0]  src_i,
    output reg  signed [7:0]  src_q,
    output reg                src_valid
);

    localparam [1:0] MODE_ZERO = 2'd0,
                     MODE_DC   = 2'd1,
                     MODE_TONE = 2'd2,
                     MODE_PRBS = 2'd3;

    // Bound the commanded amplitude.  The re-modulator's 3rd-order NTF goes
    // permanently unstable on wrap-around, so its input must stay below
    // -3 dBFS; +/-64 of a signed-8 full scale is -6 dBFS with margin.
    // The magnitude is taken in NINE bits, deliberately.  In eight, -8'sd128
    // negates to itself, so ampl = 0x80 stays negative, the (mag > AMPL_MAX)
    // compare is false, and the clamp is bypassed at exactly the input that
    // most needs it -- full negative scale straight into the re-modulator.
    // Caught by test_amplitude_is_clamped; do not narrow this back to 8 bits.
    localparam signed [7:0] AMPL_MAX = 8'sd64;
    wire signed [8:0] ampl_ext = {ampl[7], ampl};
    wire signed [8:0] ampl_mag = ampl_ext[8] ? -ampl_ext : ampl_ext;
    wire              ampl_ovf = (ampl_mag > 9'sd64);
    wire signed [7:0] a_pos    = ampl_ovf ?  AMPL_MAX : ampl_mag[7:0];
    wire signed [7:0] a_neg    = -a_pos;

    // ---- cadence -----------------------------------------------------------
    localparam integer CW = (DECIM <= 2) ? 1 : $clog2(DECIM);
    reg [CW-1:0] div;
    wire         tick = (div == DECIM[CW-1:0] - 1'b1);

    always @(posedge clk) begin
        if (!rst_n)   div <= {CW{1'b0}};
        else if (!en) div <= {CW{1'b0}};
        else          div <= tick ? {CW{1'b0}} : div + 1'b1;
    end

    // ---- fs/4 quadrature tone ----------------------------------------------
    // Four-phase rotation: (A,0), (0,A), (-A,0), (0,-A).  A complex exponential
    // at fs/4 = 125 kHz with no multiplier and no coefficient table; I leads Q
    // by one phase, so an I/Q swap or a sign inversion on either rail is
    // directly visible in the externally reconstructed spectrum.
    reg [1:0] phase;
    always @(posedge clk) begin
        if (!rst_n)        phase <= 2'd0;
        else if (!en)      phase <= 2'd0;
        else if (tick)     phase <= phase + 1'b1;
    end

    reg signed [7:0] tone_i, tone_q;
    always @* begin
        case (phase)
            2'd0: begin tone_i = a_pos; tone_q = 8'sd0; end
            2'd1: begin tone_i = 8'sd0; tone_q = a_pos; end
            2'd2: begin tone_i = a_neg; tone_q = 8'sd0; end
            2'd3: begin tone_i = 8'sd0; tone_q = a_neg; end
        endcase
    end

    // ---- PRBS --------------------------------------------------------------
    // Galois LFSR x^9 + x^5 + 1. NOT maximal-length from this seed/tap
    // combination: simulating the exact recurrence below from seed 9'h1FF
    // returns to the seed after 255 steps, not the 511 a true period-2^9-1
    // sequence would give (found 2026-09-04; the tap/seed pair was never
    // re-checked after being written). Long-run switching stress only either
    // way: a failed PRBS transfer is hard to diagnose and does not establish
    // modulation fidelity, so DC and tone remain the primary diagnostics.
    reg [8:0] lfsr;
    wire      lfsr_fb = lfsr[0];
    always @(posedge clk) begin
        if (!rst_n)     lfsr <= 9'h1FF;
        else if (!en)   lfsr <= 9'h1FF;      // deterministic restart
        else if (tick)  lfsr <= {lfsr_fb, lfsr[8:5] ^ {4{lfsr_fb}}, lfsr[4:1]};
    end

    // Map to a bounded signed sample: sign from the LFSR, magnitude fixed at
    // the clamped amplitude, so the PRBS stream cannot exceed the same bound
    // the DC and tone modes respect.
    wire signed [7:0] prbs_i = lfsr[0] ? a_pos : a_neg;
    wire signed [7:0] prbs_q = lfsr[4] ? a_pos : a_neg;

    // ---- output register ---------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            src_i     <= 8'sd0;
            src_q     <= 8'sd0;
            src_valid <= 1'b0;
        end else if (!en) begin
            src_i     <= 8'sd0;
            src_q     <= 8'sd0;
            src_valid <= 1'b0;
        end else begin
            src_valid <= tick;
            if (tick) begin
                case (mode)
                    // Sign of the commanded amplitude carries through: DC
                    // mode's density is documented as BRINGUP_AMPL / 127
                    // (Register Map 0x10-0x11), a signed formula, and the
                    // board bring-up procedure compares the captured density
                    // against that signed reference.
                    MODE_DC:   begin src_i <= ampl_ext[8] ? a_neg : a_pos;
                                     src_q <= ampl_ext[8] ? a_neg : a_pos; end
                    MODE_TONE: begin src_i <= tone_i; src_q <= tone_q; end
                    MODE_PRBS: begin src_i <= prbs_i; src_q <= prbs_q; end
                    default:   begin src_i <= 8'sd0;  src_q <= 8'sd0;  end
                endcase
            end
        end
    end

`ifdef FORMAL
    // Properties live in formal/bringup_src_formal.sv, instantiated directly
    // (not `bind` -- silently dropped by this yosys version, same as the other
    // checkers in formal/).  The three inline assertions this file used to
    // carry were never run: there was no .sby and no harness, so they read as
    // coverage while proving nothing.  Do not move properties back inline.
    bringup_src_formal #(.DECIM(DECIM), .CW(CW)) u_bringup_formal (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .mode      (mode),
        .ampl      (ampl),
        .div       (div),
        .src_i     (src_i),
        .src_q     (src_q),
        .src_valid (src_valid)
    );
`endif

endmodule

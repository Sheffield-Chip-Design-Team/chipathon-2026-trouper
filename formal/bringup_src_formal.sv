// bringup_src_formal.sv
// Formal checker for bringup_src.v (BRINGUP_SRC deterministic bring-up source).
//
// The module already carried three `ifdef FORMAL assertions when it was
// written, but nothing in formal/ ever ran them -- there was no .sby and no
// harness, so they were dead code that looked like coverage. That is the
// vacuous-pass shape this directory exists to avoid, so they are moved here
// and given real properties around them.
//
// Same yosys formal-subset conventions as the other checkers here: no SVA
// property/endproperty, no |->/|=>, no `bind` (silently dropped by this yosys
// version). Properties are plain registered "previous value" compares followed
// by a procedural assert inside an always block. Instantiated directly inside
// bringup_src.v under `ifdef FORMAL, exactly like u_psram_formal / u_pcfsm_formal.
//
// Single-clock: the generator lives entirely in the 32 MHz IQ_CLK domain, so
// this is a plain `prep`/k-induction target, unlike the multiclock spi_slave
// checker.
//
// Property groups:
//   A. Amplitude bound -- the emitted sample never leaves +/-AMPL_MAX, for ANY
//      commanded `ampl`. This is the one property with silicon consequences:
//      sd_remod's 3rd-order NTF goes PERMANENTLY unstable on input wrap-around
//      (SX1257 6.2.3), and the source now drives sd_remod directly, ahead of
//      REMOD_BACKOFF_SHIFT, so nothing downstream can rescue an out-of-range
//      sample. Proved over all 256 values of `ampl` rather than the handful a
//      directed test can enumerate -- notably 8'h80, where an 8-bit magnitude
//      would negate to itself and bypass the clamp entirely.
//   B. Disabled means silent -- no valid, and a zeroed output, under reset or
//      !en. The mux upstream selects the normal path from the same `en`, so a
//      generator that emitted while disabled could only corrupt the receiver.
//   C. Cadence -- src_valid is never two clocks running, and cannot assert
//      before DECIM-1 clocks of enabled time have elapsed. The 500 kS/s rate
//      is what sd_remod's OSR=64 NTF is synthesised for.

module bringup_src_formal #(
    parameter integer DECIM = 64,
    parameter integer CW    = 6
) (
    input wire               clk,
    input wire               rst_n,
    input wire               en,
    input wire [1:0]         mode,
    input wire signed [7:0]  ampl,
    input wire [CW-1:0]      div,
    input wire signed [7:0]  src_i,
    input wire signed [7:0]  src_q,
    input wire               src_valid
);

    localparam signed [8:0] AMPL_MAX = 9'sd64;

    // Same reset modelling as the other checkers here: without it the engine
    // starts from an arbitrary state in which the divider and output register
    // hold junk, and every invariant below fails at step 0 for no design reason.
    initial assume (!rst_n);

    reg past_valid;
    initial past_valid = 1'b0;
    always @(posedge clk) past_valid <= 1'b1;

    reg               valid_q;
    reg               en_q;
    reg               rst_n_q;
    reg [CW-1:0]      div_q;
    reg [1:0]         mode_q;
    initial valid_q = 1'b0;
    initial en_q    = 1'b0;
    initial rst_n_q = 1'b0;
    initial div_q   = {CW{1'b0}};
    initial mode_q  = 2'd0;
    always @(posedge clk) begin
        valid_q <= src_valid;
        en_q    <= en;
        rst_n_q <= rst_n;
        div_q   <= div;
        mode_q  <= mode;
    end

    // ---- A. amplitude bound, for every commanded ampl ----------------------
    always @(posedge clk)
        if (past_valid && rst_n && src_valid) begin
            assert ($signed(src_i) <=  AMPL_MAX);
            assert ($signed(src_i) >= -AMPL_MAX);
            assert ($signed(src_q) <=  AMPL_MAX);
            assert ($signed(src_q) >= -AMPL_MAX);
        end

    // The output register holds between ticks, so the bound must hold whenever
    // the generator is enabled -- not only on the tick that wrote it.
    always @(posedge clk)
        if (past_valid && rst_n && en) begin
            assert ($signed(src_i) <=  AMPL_MAX);
            assert ($signed(src_i) >= -AMPL_MAX);
            assert ($signed(src_q) <=  AMPL_MAX);
            assert ($signed(src_q) >= -AMPL_MAX);
        end

    // ---- B. disabled means silent ------------------------------------------
    // src_valid is REGISTERED (bringup_src.v:139/141), so the correct property
    // is about the PREVIOUS cycle's en/rst_n, not this one's. The version that
    // used to sit inline in bringup_src.v --
    //     if (!rst_n || !en) assert (src_valid == 1'b0);
    // -- is false in the very cycle en falls, because src_valid still carries
    // the decision made while en was high. It never fired only because nothing
    // ever ran it: an unrun assertion is not a weak check, it is an unchecked
    // claim, and this one happened to be wrong. Caught the first time this
    // harness was executed (SGE job 5429).
    always @(posedge clk)
        if (past_valid && (!rst_n_q || !en_q)) assert (src_valid == 1'b0);

    always @(posedge clk)
        if (past_valid && rst_n && !en_q && !en) begin
            assert (src_i == 8'sd0);
            assert (src_q == 8'sd0);
        end

    // Zero mode emits nothing but zero, whatever the amplitude.
    //
    // Qualified on mode_q, not mode: the output register is written on the
    // tick using the mode present AT that edge, so a sample accompanying
    // src_valid reflects the previous cycle's mode. `mode` is a free input to
    // this module (it comes from BRINGUP_CTRL), so induction is free to flip it
    // in the step between the write and the check -- which is exactly what it
    // did. The design consequence is worth stating plainly: a mode change takes
    // effect at the NEXT tick, not the current one.
    always @(posedge clk)
        if (past_valid && rst_n && src_valid && mode_q == 2'd0) begin
            assert (src_i == 8'sd0);
            assert (src_q == 8'sd0);
        end

    // ---- C. cadence ---------------------------------------------------------
    // Never two valids back to back: the 500 kS/s rate is structural.
    always @(posedge clk)
        if (past_valid && rst_n) assert (!(src_valid && valid_q));

    // The divider advances by exactly one per enabled clock and wraps only on
    // the tick, so the period is exactly DECIM and cannot alias to a shorter
    // one. Stated as a step relation rather than as a range bound: with
    // DECIM a power of two, CW = $clog2(DECIM) and `DECIM[CW-1:0]` truncates to
    // 0, so the obvious `assert (div < DECIM[CW-1:0])` reads `div < 0` and is
    // unsatisfiable -- a bound that looks like a check and proves nothing.
    always @(posedge clk)
        if (past_valid && rst_n_q && rst_n && en_q && en) begin
            if (div_q == DECIM[CW-1:0] - 1'b1) assert (div == {CW{1'b0}});
            else                               assert (div == div_q + 1'b1);
        end

    // A valid is always accompanied by the divider having just wrapped.
    always @(posedge clk)
        if (past_valid && rst_n && src_valid) assert (div == {CW{1'b0}});

endmodule

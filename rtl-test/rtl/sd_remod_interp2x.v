// Experimental 2x half-band interpolator in front of the deployed sd_remod.
//
// External interface remains int8 complex IQ at 500 kS/s (in_valid once per
// 64 clk_32m cycles).  Internally this block emits a filtered 1 MS/s stream
// (one sample every 32 clocks) into sd_remod.  Reducing the final zero-order
// hold from 64 to 32 clocks changes its 125 kHz response from -0.912 dB to
// -0.224 dB; the half-band response leaves about -0.18 dB net droop.
//
// The coefficients are the existing sd_decimator_poly HB1 coefficients used
// in reverse as an interpolator:
//   [19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19] / 1024
// Interpolation requires a gain of two after zero insertion.  Polyphase form
// therefore gives:
//   even phase = (19*(x[n]+x[n-5]) - 73*(x[n-1]+x[n-4])
//                 + 312*(x[n-2]+x[n-3])) / 512
//   odd phase  = x[n-2]
// The odd phase is just a delayed copy.  The even-phase arithmetic is fully
// serialized across I and Q.  One 9-bit pair adder and one 20-bit accumulator
// consume the ten signed power-of-two terms for I, then the same ten terms for
// Q.  This takes 20 of the 64 clocks available per input pair.  There are no
// inferred general multipliers in the interpolator.
//
// This is an rtl-test experiment, not production src/ RTL.

`timescale 1ns/1ps
`default_nettype none

module sd_remod_interp2x (
    input  wire              clk_32m,
    input  wire              rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire              in_valid,
    input  wire              en,
    output wire              out_i,
    output wire              out_q
);

    reg signed [7:0] zi0, zi1, zi2, zi3, zi4, zi_tail;
    reg signed [7:0] zq0, zq1, zq2, zq3, zq4, zq_tail;

    reg              mac_busy;
    reg              mac_q;
    reg        [3:0] term_step;
    reg signed [19:0] mac_acc;

    // Select one symmetric input pair.  Histories are shifted before the MAC
    // starts, so *_tail preserves x[n-5].
    reg signed [7:0] pair_a;
    reg signed [7:0] pair_b;
    always @(*) begin
        pair_a = 8'sd0;
        pair_b = 8'sd0;
        if (!mac_q) begin
            if (term_step < 4'd3) begin
                pair_a = zi0; pair_b = zi_tail;
            end else if (term_step < 4'd6) begin
                pair_a = zi1; pair_b = zi4;
            end else begin
                pair_a = zi2; pair_b = zi3;
            end
        end else begin
            if (term_step < 4'd3) begin
                pair_a = zq0; pair_b = zq_tail;
            end else if (term_step < 4'd6) begin
                pair_a = zq1; pair_b = zq4;
            end else begin
                pair_a = zq2; pair_b = zq3;
            end
        end
    end

    wire signed [8:0] pair_sum = $signed({pair_a[7], pair_a})
                               + $signed({pair_b[7], pair_b});
    wire signed [19:0] pair_ext = {{11{pair_sum[8]}}, pair_sum};

    // 19=16+2+1, 73=64+8+1, 312=256+32+16+8.  Accumulating
    // one shifted term per clock turns all three constant products into one
    // shared adder/subtractor.  The initial +256 implements round-to-nearest
    // before the final divide by 512.
    reg signed [19:0] term_value;
    reg               term_subtract;
    always @(*) begin
        term_value = pair_ext;
        term_subtract = 1'b0;
        case (term_step)
            4'd0: term_value = pair_ext <<< 4;
            4'd1: term_value = pair_ext <<< 1;
            4'd2: term_value = pair_ext;
            4'd3: begin term_value = pair_ext <<< 6; term_subtract = 1'b1; end
            4'd4: begin term_value = pair_ext <<< 3; term_subtract = 1'b1; end
            4'd5: begin term_value = pair_ext;       term_subtract = 1'b1; end
            4'd6: term_value = pair_ext <<< 8;
            4'd7: term_value = pair_ext <<< 5;
            4'd8: term_value = pair_ext <<< 4;
            4'd9: term_value = pair_ext <<< 3;
            default: term_value = 20'sd0;
        endcase
    end

    wire signed [19:0] acc_next = term_subtract
                                  ? mac_acc - term_value
                                  : mac_acc + term_value;

    function signed [7:0] sat8;
        input signed [19:0] v;
        begin
            if      (v > 20'sd127)  sat8 = 8'sd127;
            else if (v < -20'sd128) sat8 = -8'sd128;
            else                    sat8 = v[7:0];
        end
    endfunction

    reg signed [7:0] interp_i, interp_q;
    reg              interp_valid;
    reg              odd_pending;
    reg        [5:0] half_count;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            zi0 <= 0; zi1 <= 0; zi2 <= 0; zi3 <= 0; zi4 <= 0; zi_tail <= 0;
            zq0 <= 0; zq1 <= 0; zq2 <= 0; zq3 <= 0; zq4 <= 0; zq_tail <= 0;
            interp_i <= 0;
            interp_q <= 0;
            interp_valid <= 1'b0;
            mac_busy <= 1'b0;
            mac_q <= 1'b0;
            term_step <= 0;
            mac_acc <= 0;
            odd_pending <= 1'b0;
            half_count <= 0;
        end else if (!en) begin
            zi0 <= 0; zi1 <= 0; zi2 <= 0; zi3 <= 0; zi4 <= 0; zi_tail <= 0;
            zq0 <= 0; zq1 <= 0; zq2 <= 0; zq3 <= 0; zq4 <= 0; zq_tail <= 0;
            interp_i <= 0;
            interp_q <= 0;
            interp_valid <= 1'b0;
            mac_busy <= 1'b0;
            mac_q <= 1'b0;
            term_step <= 0;
            mac_acc <= 0;
            odd_pending <= 1'b0;
            half_count <= 0;
        end else begin
            interp_valid <= 1'b0;

            if (in_valid) begin
                zi_tail <= zi4;
                zi4 <= zi3; zi3 <= zi2; zi2 <= zi1; zi1 <= zi0; zi0 <= in_i;
                zq_tail <= zq4;
                zq4 <= zq3; zq3 <= zq2; zq2 <= zq1; zq1 <= zq0; zq0 <= in_q;

                mac_busy <= 1'b1;
                mac_q <= 1'b0;
                term_step <= 0;
                mac_acc <= 20'sd256;
            end else if (mac_busy) begin
                if (term_step == 4'd9) begin
                    if (!mac_q) begin
                        interp_i <= sat8(acc_next >>> 9);
                        mac_q <= 1'b1;
                        term_step <= 0;
                        mac_acc <= 20'sd256;
                    end else begin
                        interp_q <= sat8(acc_next >>> 9);
                        interp_valid <= 1'b1;
                        mac_busy <= 1'b0;
                        mac_q <= 1'b0;
                        term_step <= 0;
                        mac_acc <= 0;
                        odd_pending <= 1'b1;
                        half_count <= 6'd32;
                    end
                end else begin
                    mac_acc <= acc_next;
                    term_step <= term_step + 1'b1;
                end
            end else if (odd_pending) begin
                if (half_count == 6'd1) begin
                    // Centre-tap phase: 2*(512/1024) = 1, so this is an
                    // exact delayed input copy with no arithmetic.
                    interp_i <= zi2;
                    interp_q <= zq2;
                    interp_valid <= 1'b1;
                    odd_pending <= 1'b0;
                    half_count <= 0;
                end else begin
                    half_count <= half_count - 1'b1;
                end
            end
        end
    end

    sd_remod u_remod (
        .clk_32m  (clk_32m),
        .rst_n    (rst_n),
        .in_i     (interp_i),
        .in_q     (interp_q),
        .in_valid (interp_valid),
        .en       (en),
        .out_i    (out_i),
        .out_q    (out_q)
    );

endmodule

`default_nettype wire

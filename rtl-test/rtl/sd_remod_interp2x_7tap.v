// Experimental compact 2x interpolator in front of sd_remod.
//
// This is the area-oriented alternative to sd_remod_interp2x.v.  It uses the
// centred seven-tap response
//
//     [-4, 0, 19, 32, 19, 0, -4] / 64
//
// and its 2x polyphase form:
//
//   even = (19*(x[n-1] + x[n-2]) - 4*(x[n] + x[n-3])) / 32
//   odd  = x[n-1]
//
// The even phase is serialized across I and Q.  Since 19=16+2+1 and 4 is a
// power of two, one shared pair adder and one 14-bit accumulator consume four
// shifted terms per rail (eight clocks total).  The input cadence provides 64
// clocks, so the two output phases remain exactly 32 clocks apart.  There are
// no general multipliers.
//
// This is an rtl-test comparison candidate, not production src/ RTL.

`timescale 1ns/1ps
`default_nettype none

module sd_remod_interp2x_7tap (
    input  wire              clk_32m,
    input  wire              rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire              in_valid,
    input  wire              en,
    output wire              out_i,
    output wire              out_q
);

    reg signed [7:0] zi0, zi1, zi2, zi3;
    reg signed [7:0] zq0, zq1, zq2, zq3;

    reg               mac_busy;
    reg               mac_q;
    reg         [1:0] term_step;
    reg signed [13:0] mac_acc;

    reg signed [7:0] pair_a;
    reg signed [7:0] pair_b;
    always @(*) begin
        if (!mac_q) begin
            if (term_step == 2'd0) begin
                pair_a = zi0;
                pair_b = zi3;
            end else begin
                pair_a = zi1;
                pair_b = zi2;
            end
        end else begin
            if (term_step == 2'd0) begin
                pair_a = zq0;
                pair_b = zq3;
            end else begin
                pair_a = zq1;
                pair_b = zq2;
            end
        end
    end

    wire signed [8:0] pair_sum = $signed({pair_a[7], pair_a})
                               + $signed({pair_b[7], pair_b});
    wire signed [13:0] pair_ext = {{5{pair_sum[8]}}, pair_sum};

    reg signed [13:0] term_value;
    reg               term_subtract;
    always @(*) begin
        term_value = pair_ext;
        term_subtract = 1'b0;
        case (term_step)
            2'd0: begin
                term_value = pair_ext <<< 2;  // -4 * outer pair
                term_subtract = 1'b1;
            end
            2'd1: term_value = pair_ext <<< 4; // 16 * inner pair
            2'd2: term_value = pair_ext <<< 1; //  2 * inner pair
            2'd3: term_value = pair_ext;       //  1 * inner pair
        endcase
    end

    wire signed [13:0] acc_next = term_subtract
                                  ? mac_acc - term_value
                                  : mac_acc + term_value;

    function signed [7:0] sat8;
        input signed [13:0] v;
        begin
            if      (v > 14'sd127)  sat8 = 8'sd127;
            else if (v < -14'sd128) sat8 = -8'sd128;
            else                    sat8 = v[7:0];
        end
    endfunction

    reg signed [7:0] interp_i, interp_q;
    reg              interp_valid;
    reg              odd_pending;
    reg        [5:0] half_count;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            zi0 <= 0; zi1 <= 0; zi2 <= 0; zi3 <= 0;
            zq0 <= 0; zq1 <= 0; zq2 <= 0; zq3 <= 0;
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
            zi0 <= 0; zi1 <= 0; zi2 <= 0; zi3 <= 0;
            zq0 <= 0; zq1 <= 0; zq2 <= 0; zq3 <= 0;
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
                zi3 <= zi2; zi2 <= zi1; zi1 <= zi0; zi0 <= in_i;
                zq3 <= zq2; zq2 <= zq1; zq1 <= zq0; zq0 <= in_q;

                mac_busy <= 1'b1;
                mac_q <= 1'b0;
                term_step <= 0;
                mac_acc <= 14'sd16; // round-to-nearest before divide by 32
            end else if (mac_busy) begin
                if (term_step == 2'd3) begin
                    if (!mac_q) begin
                        interp_i <= sat8(acc_next >>> 5);
                        mac_q <= 1'b1;
                        term_step <= 0;
                        mac_acc <= 14'sd16;
                    end else begin
                        interp_q <= sat8(acc_next >>> 5);
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
                    interp_i <= zi1;
                    interp_q <= zq1;
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

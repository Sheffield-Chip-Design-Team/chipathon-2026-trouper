// noise_est.v
// Per-branch noise power estimator for NW-MRC weight scaling.
//
// Accumulates Σ(|I_k| + |Q_k|) per branch while sc_lock=0 (inter-packet idle).
// Manhattan norm avoids multipliers; only the ratio across branches matters.
//
// At sc_lock rising edge: snapshot → noise_snap[k], then clear accumulators.
// 24-bit accumulator, 8-bit output (acc[23:16]).
//   Overflow point: 2^24 / 254 ≈ 66k samples = 530 ms at 125 kHz.
//   Firmware sees 0–255 per branch; 48 dB ratio range is ample for co-located
//   or short-distributed antenna arrays.
//
// Firmware reads 0x40–0x43 (1 byte per branch × 4) after sc_lock.
// NW-MRC: w_k = conj(Z_k) / noise_snap[k], then normalise to 8-bit W range.
// GF180MCU, 3.3V, 16 MHz clock domain.

module noise_est (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire        sc_lock,
    input  wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3,
    input  wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3,
    output reg  [7:0]  noise_snap_0, noise_snap_1,
    output reg  [7:0]  noise_snap_2, noise_snap_3
);

    reg sc_lock_r;
    wire sc_lock_rise = sc_lock && !sc_lock_r;
    reg [23:0] acc [0:3];

    // |x| ≈ bitwise flip for negative (off by 1 LSB — irrelevant for ratios)
    wire [7:0] abs_i [0:3];
    wire [7:0] abs_q [0:3];
    assign abs_i[0] = dcr_i0[7] ? ~dcr_i0 : dcr_i0;
    assign abs_i[1] = dcr_i1[7] ? ~dcr_i1 : dcr_i1;
    assign abs_i[2] = dcr_i2[7] ? ~dcr_i2 : dcr_i2;
    assign abs_i[3] = dcr_i3[7] ? ~dcr_i3 : dcr_i3;
    assign abs_q[0] = dcr_q0[7] ? ~dcr_q0 : dcr_q0;
    assign abs_q[1] = dcr_q1[7] ? ~dcr_q1 : dcr_q1;
    assign abs_q[2] = dcr_q2[7] ? ~dcr_q2 : dcr_q2;
    assign abs_q[3] = dcr_q3[7] ? ~dcr_q3 : dcr_q3;

    // Manhattan norm: |I_k| + |Q_k|, max 254, 9-bit result
    wire [8:0] man [0:3];
    assign man[0] = {1'b0, abs_i[0]} + {1'b0, abs_q[0]};
    assign man[1] = {1'b0, abs_i[1]} + {1'b0, abs_q[1]};
    assign man[2] = {1'b0, abs_i[2]} + {1'b0, abs_q[2]};
    assign man[3] = {1'b0, abs_i[3]} + {1'b0, abs_q[3]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_lock_r    <= 1'b0;
            noise_snap_0 <= 8'h0; noise_snap_1 <= 8'h0;
            noise_snap_2 <= 8'h0; noise_snap_3 <= 8'h0;
            acc[0] <= 24'h0; acc[1] <= 24'h0;
            acc[2] <= 24'h0; acc[3] <= 24'h0;
        end else begin
            sc_lock_r <= sc_lock;

            if (sc_lock_rise) begin
                noise_snap_0 <= acc[0][23:16];
                noise_snap_1 <= acc[1][23:16];
                noise_snap_2 <= acc[2][23:16];
                noise_snap_3 <= acc[3][23:16];
                acc[0] <= 24'h0; acc[1] <= 24'h0;
                acc[2] <= 24'h0; acc[3] <= 24'h0;
            end else if (!sc_lock && iq_valid) begin
                acc[0] <= acc[0] + {15'h0, man[0]};
                acc[1] <= acc[1] + {15'h0, man[1]};
                acc[2] <= acc[2] + {15'h0, man[2]};
                acc[3] <= acc[3] + {15'h0, man[3]};
            end
        end
    end

endmodule

module uart_tx_pattern (
    input  wire clk100mhz,
    input  wire ext_resetn,
    output wire uart_txd,
    output wire led0
);
    localparam integer CLK_HZ   = 100_000_000;
    localparam integer BAUD     = 115_200;
    localparam integer BAUD_DIV = CLK_HZ / BAUD;

    reg [31:0] baud_ctr = 0;
    reg        baud_tick = 1'b0;

    reg [25:0] led_ctr = 0;
    reg        led_reg = 1'b0;

    reg [3:0]  bit_idx = 4'd0;
    reg [9:0]  shift_reg = 10'h3ff;
    reg [7:0]  message [0:5];
    reg [2:0]  msg_idx = 3'd0;
    reg        txd_reg = 1'b1;

    initial begin
        message[0] = 8'h55;
        message[1] = 8'haa;
        message[2] = 8'h0d;
        message[3] = 8'h0a;
        message[4] = 8'h43; // C
        message[5] = 8'h0a;
    end

    always @(posedge clk100mhz) begin
        if (!ext_resetn) begin
            baud_ctr  <= 0;
            baud_tick <= 1'b0;
            led_ctr   <= 0;
            led_reg   <= 1'b0;
            bit_idx   <= 4'd0;
            shift_reg <= 10'h3ff;
            msg_idx   <= 3'd0;
            txd_reg   <= 1'b1;
        end else begin
            if (baud_ctr == BAUD_DIV - 1) begin
                baud_ctr  <= 0;
                baud_tick <= 1'b1;
            end else begin
                baud_ctr  <= baud_ctr + 1;
                baud_tick <= 1'b0;
            end

            if (led_ctr == 26'd49_999_999) begin
                led_ctr <= 0;
                led_reg <= ~led_reg;
            end else begin
                led_ctr <= led_ctr + 1;
            end

            if (baud_tick) begin
                if (bit_idx == 0) begin
                    shift_reg <= {1'b1, message[msg_idx], 1'b0};
                    bit_idx   <= 4'd10;
                    if (msg_idx == 3'd5) begin
                        msg_idx <= 3'd0;
                    end else begin
                        msg_idx <= msg_idx + 1'b1;
                    end
                end else begin
                    txd_reg   <= shift_reg[0];
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    bit_idx   <= bit_idx - 1'b1;
                end
            end

            if (!baud_tick && bit_idx == 0) begin
                txd_reg <= 1'b1;
            end
        end
    end

    assign uart_txd = txd_reg;
    assign led0 = led_reg;
endmodule

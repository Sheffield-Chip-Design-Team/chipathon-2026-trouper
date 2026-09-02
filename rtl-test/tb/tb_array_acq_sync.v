`timescale 1ns/1ps
`default_nettype none

module tb_array_acq_sync;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg array_sync_en = 1'b1;
    reg local_lock_pulse = 1'b0;
    reg local_lock_level = 1'b0;
    reg packet_active = 1'b0;
    reg packet_done = 1'b0;
    reg rx_hold = 1'b0;
    reg acq_n_async = 1'b1;
    wire drive_oe, peer_lock_pulse;

    array_acq_sync dut (
        .clk(clk), .rst_n(rst_n), .array_sync_en(array_sync_en),
        .local_lock_pulse(local_lock_pulse), .local_lock_level(local_lock_level),
        .packet_active(packet_active), .packet_done(packet_done), .rx_hold(rx_hold),
        .acq_n_async(acq_n_async), .drive_oe(drive_oe),
        .peer_lock_pulse(peer_lock_pulse)
    );

    always #5 clk = ~clk;

    task tick;
        begin @(posedge clk); #1; end
    endtask

    initial begin
        repeat (2) tick;
        rst_n = 1'b1;
        repeat (4) tick; // synchronise released-high and arm the peer edge detector

        // A local qualified lock pulls the emulated open-drain wire low.
        local_lock_pulse = 1'b1;
        tick;
        local_lock_pulse = 1'b0;
        if (!drive_oe) $fatal(1, "local lock did not assert OE");

        // Packet completion releases the wire.
        packet_done = 1'b1;
        tick;
        packet_done = 1'b0;
        if (drive_oe) $fatal(1, "packet completion did not release OE");

        repeat (3) tick;
        // A fresh peer low is accepted after the two-flop synchroniser.
        acq_n_async = 1'b0;
        repeat (3) tick;
        if (!peer_lock_pulse) $fatal(1, "peer request did not produce a pulse");
        tick;
        if (peer_lock_pulse) $fatal(1, "peer request pulse was not one cycle");
        if (drive_oe) $fatal(1, "peer request must not originate a second drive");

        // An active packet must ignore a subsequent peer event.
        acq_n_async = 1'b1;
        repeat (3) tick;
        packet_active = 1'b1;
        acq_n_async = 1'b0;
        repeat (3) tick;
        if (peer_lock_pulse) $fatal(1, "peer request accepted during active packet");

        $display("PASS tb_array_acq_sync");
        $finish;
    end
endmodule

`default_nettype wire

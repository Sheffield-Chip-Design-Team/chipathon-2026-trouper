// Smoke test for the foundry gf180mcu_fd_io__bi_t Verilog model.
// Run with cocotb/io_cell_controls/Makefile inside chipathon26.
`default_nettype none

module tb_gf180_io_control;
    reg CS, SL, IE, OE, PU, PD, A, PDRV0, PDRV1;
    reg ext_oe, ext_a;
    tri PAD;
    wire Y;

    assign PAD = ext_oe ? ext_a : 1'bz;

    gf180mcu_fd_io__bi_t u_pad (
        .CS(CS), .SL(SL), .IE(IE), .OE(OE), .PU(PU), .PD(PD), .A(A),
        .PDRV0(PDRV0), .PDRV1(PDRV1), .PAD(PAD), .Y(Y),
        .DVDD(), .DVSS(), .VDD(), .VSS()
    );

    initial begin
        CS = 1'b0; SL = 1'b0; PU = 1'b0; PD = 1'b0;
        PDRV0 = 1'b1; PDRV1 = 1'b1;
        IE = 1'b0; OE = 1'b0; A = 1'b0; ext_oe = 1'b0; ext_a = 1'b0;

        // Legal output mode: only the ASIC drives PAD.
        #3; OE = 1'b1; A = 1'b1;
        #3; if (PAD !== 1'b1 || Y !== 1'b0) $fatal(1, "legal output mode failed");

        // Legal input mode: external source drives PAD and receiver sees it.
        OE = 1'b0; IE = 1'b1; ext_oe = 1'b1; ext_a = 1'b0;
        #3; if (Y !== 1'b0) $fatal(1, "input low mode failed");
        ext_a = 1'b1;
        #3; if (Y !== 1'b1) $fatal(1, "input high mode failed");

        // The DUT integration must never enter IE=OE=1.
        if (IE && OE) $fatal(1, "uncharacterized IE=OE=1 mode requested");
        $display("PASS: gf180mcu_fd_io__bi_t legal modes");
        $finish;
    end
endmodule
`default_nettype wire

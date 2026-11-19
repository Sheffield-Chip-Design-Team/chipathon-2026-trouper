// Legal-mode smoke test for the four foundry IO cells the A40 padring uses:
//   gf180mcu_fd_io__bi_t    (11x: REMOD, PSRAM_CE_N/SIO, SPI_MISO, IRQ, ARRAY_ACQ_N, DBG0)
//   gf180mcu_fd_io__bi_24t  (1x : PSRAM_SCK, fixed 24 mA -- no PDRV)
//   gf180mcu_fd_io__in_c    (9x : IQ_DATA_{I,Q}_0..3, IQ_CLK)
//   gf180mcu_fd_io__in_s    (4x : RESETB, HOST_CS, SPI_SCK, SPI_MOSI -- Schmitt)
//
// Plain iverilog bench (no cocotb); pass/fail is the vvp exit code.  The model
// is supplied by cocotb/io_cell_controls/Makefile from the pinned chipathon26
// PDK -- it is intentionally not copied into this repository.
//
// Checked:
//   * legal OUTPUT mode (bi_t/bi_24t): OE=1 -> PAD follows A, receiver Y off
//   * legal INPUT  mode (all four)   : an external source on PAD -> Y follows
//   * the uncharacterized IE=OE=1 state is never requested (bi_t/bi_24t)
//   * bi_t {PDRV1,PDRV0} codes 00..11 are functionally transparent (the digital
//     model carries no drive-strength behaviour -- that, slew and Schmitt
//     hysteresis are SPICE-tier, see planning/pad-cell-signoff-plan.md)
//   * PU/PD pull direction *if the model implements it*: an unmodelled pull
//     leaves Y at x/z and is reported as NOTE, not FAIL.
`default_nettype none

module tb_gf180_io_control;

    // Shared stimulus for whichever cell is under test.
    reg CS, SL, IE, OE, A, PDRV0, PDRV1, PU, PD;
    reg ext_oe, ext_a;          // external world driving PAD
    integer i;
    integer errors = 0;

    task expect_eq(input got, input exp, input [8*64:1] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s : got %b want %b", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // Pull-device check: PASS on a match, NOTE (not FAIL) if the model leaves
    // Y undriven -- the digital cell need not model the weak pull at all.
    task check_pull(input got, input exp, input [8*64:1] what);
        begin
            if (got === 1'bx || got === 1'bz)
                $display("NOTE: %0s : Y=%b -- pull not behaviourally modelled (SPICE-tier)", what, got);
            else if (got !== exp) begin
                $display("FAIL: %0s : Y=%b want %b", what, got, exp);
                errors = errors + 1;
            end
            else
                $display("ok  : %0s : Y=%b", what, got);
        end
    endtask

    // ---------------- cell instances (one external driver each) ----------------
    tri  PAD_bt;   wire Y_bt;
    tri  PAD_b24;  wire Y_b24;
    tri  PAD_ic;   wire Y_ic;
    tri  PAD_is;   wire Y_is;
    assign PAD_bt  = ext_oe ? ext_a : 1'bz;
    assign PAD_b24 = ext_oe ? ext_a : 1'bz;
    assign PAD_ic  = ext_oe ? ext_a : 1'bz;
    assign PAD_is  = ext_oe ? ext_a : 1'bz;

    gf180mcu_fd_io__bi_t u_bt (
        .CS(CS), .SL(SL), .IE(IE), .OE(OE), .PU(PU), .PD(PD), .A(A),
        .PDRV0(PDRV0), .PDRV1(PDRV1), .PAD(PAD_bt), .Y(Y_bt),
        .DVDD(), .DVSS(), .VDD(), .VSS()
    );
    gf180mcu_fd_io__bi_24t u_b24 (
        .CS(CS), .SL(SL), .IE(IE), .OE(OE), .PU(PU), .PD(PD), .A(A),
        .PAD(PAD_b24), .Y(Y_b24),
        .DVDD(), .DVSS(), .VDD(), .VSS()
    );
    gf180mcu_fd_io__in_c u_ic (
        .PU(PU), .PD(PD), .Y(Y_ic), .PAD(PAD_ic),
        .DVDD(), .DVSS(), .VDD(), .VSS()
    );
    gf180mcu_fd_io__in_s u_is (
        .PU(PU), .PD(PD), .Y(Y_is), .PAD(PAD_is),
        .DVDD(), .DVSS(), .VDD(), .VSS()
    );

    // ------------------------------- sequence --------------------------------
    task drive_defaults;
        begin
            CS = 1'b0; SL = 1'b0; IE = 1'b0; OE = 1'b0; A = 1'b0;
            PDRV0 = 1'b1; PDRV1 = 1'b1; PU = 1'b0; PD = 1'b0;
            ext_oe = 1'b0; ext_a = 1'b0;
        end
    endtask

    initial begin
        drive_defaults;
        #3;

        // ===================== gf180mcu_fd_io__bi_t =====================
        // Legal output mode: only the ASIC drives PAD.
        OE = 1'b1; IE = 1'b0; ext_oe = 1'b0;
        A = 1'b1; #3; expect_eq(PAD_bt, 1'b1, "bi_t output A=1 -> PAD");
                       expect_eq(Y_bt,  1'b0, "bi_t Y low while output-only");
        A = 1'b0; #3; expect_eq(PAD_bt, 1'b0, "bi_t output A=0 -> PAD");

        // Drive-strength codes must not change the logic function.
        for (i = 0; i < 4; i = i + 1) begin
            {PDRV1, PDRV0} = i[1:0];
            A = 1'b1; #3; expect_eq(PAD_bt, 1'b1, "bi_t PAD follows A over PDRV sweep");
            A = 1'b0; #3; expect_eq(PAD_bt, 1'b0, "bi_t PAD follows A over PDRV sweep");
        end
        {PDRV1, PDRV0} = 2'b11;

        if (IE && OE) $fatal(1, "bench requested uncharacterized IE=OE=1 on bi_t");

        // Legal input mode: external source drives PAD, receiver follows.
        OE = 1'b0; IE = 1'b1; ext_oe = 1'b1;
        ext_a = 1'b0; #3; expect_eq(Y_bt, 1'b0, "bi_t input low");
        ext_a = 1'b1; #3; expect_eq(Y_bt, 1'b1, "bi_t input high");

        // Pull devices (tolerated if unmodelled).
        ext_oe = 1'b0;
        PU = 1'b1; PD = 1'b0; #3; check_pull(Y_bt, 1'b1, "bi_t PU pulls high");
        PU = 1'b0; PD = 1'b1; #3; check_pull(Y_bt, 1'b0, "bi_t PD pulls low");
        drive_defaults; #3;

        // ==================== gf180mcu_fd_io__bi_24t ====================
        // Same contract as bi_t but fixed 24 mA drive -- the cell has no PDRV.
        OE = 1'b1; IE = 1'b0; ext_oe = 1'b0;
        A = 1'b1; #3; expect_eq(PAD_b24, 1'b1, "bi_24t output A=1 -> PAD");
                       expect_eq(Y_b24,  1'b0, "bi_24t Y low while output-only");
        A = 1'b0; #3; expect_eq(PAD_b24, 1'b0, "bi_24t output A=0 -> PAD");

        if (IE && OE) $fatal(1, "bench requested uncharacterized IE=OE=1 on bi_24t");

        OE = 1'b0; IE = 1'b1; ext_oe = 1'b1;
        ext_a = 1'b0; #3; expect_eq(Y_b24, 1'b0, "bi_24t input low");
        ext_a = 1'b1; #3; expect_eq(Y_b24, 1'b1, "bi_24t input high");

        ext_oe = 1'b0;
        PU = 1'b1; PD = 1'b0; #3; check_pull(Y_b24, 1'b1, "bi_24t PU pulls high");
        PU = 1'b0; PD = 1'b1; #3; check_pull(Y_b24, 1'b0, "bi_24t PD pulls low");
        drive_defaults; #3;

        // ===================== gf180mcu_fd_io__in_c =====================
        // Pure CMOS input: PAD -> Y, plus PU/PD.  No Schmitt, no output path.
        ext_oe = 1'b1;
        ext_a = 1'b0; #3; expect_eq(Y_ic, 1'b0, "in_c input low");
        ext_a = 1'b1; #3; expect_eq(Y_ic, 1'b1, "in_c input high");
        ext_oe = 1'b0;
        PU = 1'b1; PD = 1'b0; #3; check_pull(Y_ic, 1'b1, "in_c PU pulls high");
        PU = 1'b0; PD = 1'b1; #3; check_pull(Y_ic, 1'b0, "in_c PD pulls low");
        drive_defaults; #3;

        // ===================== gf180mcu_fd_io__in_s =====================
        // Schmitt input: same digital interface as in_c.  The hysteresis band
        // itself is not in the digital model -- logical pass-through only.
        ext_oe = 1'b1;
        ext_a = 1'b0; #3; expect_eq(Y_is, 1'b0, "in_s input low");
        ext_a = 1'b1; #3; expect_eq(Y_is, 1'b1, "in_s input high");
        ext_oe = 1'b0;
        PU = 1'b1; PD = 1'b0; #3; check_pull(Y_is, 1'b1, "in_s PU pulls high");
        PU = 1'b0; PD = 1'b1; #3; check_pull(Y_is, 1'b0, "in_s PD pulls low");
        drive_defaults; #3;

        // ------------------------------- verdict -------------------------------
        if (errors != 0)
            $fatal(1, "gf180 IO-cell smoke test: %0d failure(s)", errors);
        $display("PASS: gf180mcu_fd_io legal modes (bi_t, bi_24t, in_c, in_s)");
        $finish;
    end

endmodule
`default_nettype wire

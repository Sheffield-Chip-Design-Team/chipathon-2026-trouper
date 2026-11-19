# Error-feedback re-modulator investigation — 2026-09-09

## Outcome

A second-order, leaky error-feedback (EF2) re-modulator is a credible smaller
alternative to the current fourth-order CIFF core. In an equal-flow GF180
standalone synthesis it is 42.4% smaller by mapped cell area and has 4.43 ns
less negative SS worst slack. At top level it reduces synthesized area by 2.46%
and post-route standard-cell area by 1.40%. Its measured in-band fidelity is
close to the current core and it passes the existing SQNR thresholds. A denser
LoRa receiver-proxy sweep, however, finds a small systematic EF2 disadvantage,
concentrated mainly in SF7 and residual-CFO cases.

The top-level timing result is mixed. EF2 reduces SS setup TNS by 31.2% and the
setup violation count by 25.9%, but its single worst SS path is 1.63 ns worse.
EF2's worst path runs from `timing_ref[2]` to `u_tacc.acc_end[31]` in the
receive/control path, not through its arithmetic. Production's worst path is
the `u_remod.u_remod.q_q` feedback path. EF2 removes that production bottleneck,
but the resulting whole-design placement/routing perturbation exposes an even
worse unrelated path. EF2 is therefore an area win, but not a demonstrated
top-level WNS win.

This is an isolated experiment in `rtl-test/rtl/sd_remod_ef2.v`; production
`src/remod/sd_remod.v` and the requirements in the chip specification are not
changed by this investigation.

## Architecture

The existing serialized 2x, 11-tap interpolator is retained, but its output is
widened from signed 8 bits to signed 9 bits. This removes the hidden sat8
nonlinearity: the even-phase FIR has approximately 1.578 L1 gain and can reach
about +/-202 for arbitrary int8 input sequences (about +/-141 over the specified
strictly-below-90-count input envelope).

Each I/Q rail uses a two-state error-feedback quantizer:

```
v[n] = x[n] - 1.75 e[n-1] + 0.75 e[n-2]
y[n] = sign(v[n]) * 127
e[n] = y[n] - v[n]
```

The corresponding NTF is `(1-z^-1)(1-0.75z^-1)`. Both coefficients use only
shifts and additions. Error states are signed 14-bit values with saturation,
so arithmetic cannot silently wrap.

An exact double-zero second-order NTF, `(1-z^-1)^2`, was rejected: bit-true
testing found growing states on legal period-3 and random sequences. Exact
third- and fourth-order binomial error-feedback forms were still less robust.

## Fidelity results

The authoritative `cocotb/tests/test_remod_sqnr.py` suite was run through the
EF2 RTL wrapper. Both tests passed.

| Input | EF2 SQNR | RMS error | Recovered gain |
|---|---:|---:|---:|
| 64 counts, 20 kHz | 45.43 dB | 0.3435 LSB | 1.0027 |
| 64 counts, 60 kHz | 44.90 dB | 0.3603 LSB | 0.9891 |
| 40 counts, 40 kHz | 39.16 dB | 0.4383 LSB | 0.9943 |
| 85 counts, 40 kHz | 46.78 dB | 0.3871 LSB | 0.9940 |

The amplitude-transition test also passed with 46.78 dB tail SQNR and longest
identical-bit runs of 7 clocks on I and 6 clocks on Q.

## Tested range and stability

`rtl-test/tb/remod_ef2/test_remod_ef2_range.py` directly observes the widened
interpolator and all four EF states. It passed step, alternating, period-3,
fixed-seed uniformly random, and representative DC inputs, all within the
specified integer range -89 through +89.

Across that suite:

- maximum interpolator magnitude: 140 counts;
- maximum EF-state magnitude: 2,220 counts versus an 8,191 positive rail;
- state saturation events: zero;
- maximum identical-bit run: 49 clocks.

This is a tested envelope, not a formal proof over every possible infinite
sequence. Promotion should be conditional on either a bounded-state proof or
substantially longer constrained-random/adversarial testing. Full int8 input
(-128 through +127) is deliberately outside TRPR-RMD-004 and is not claimed.

## SX1302 receive-path compatibility

Area, generic SQNR, and reconstructed RMS error are necessary but are not by
themselves sufficient to promote EF2. The downstream device is an SX1302
receive input, not a generic ideal decimator.

The local SX1302 Rev. 1.2 datasheet defines a direct receive interface from the
SX1250/55/57 family using separate I(t) and Q(t) bit streams and the shared
32 MHz system clock. The SX1257 Rev. 1.2 datasheet further states that its
normal receive outputs come from fifth-order continuous-time sigma-delta ADCs:
one bit per I/Q channel at 32 or 36 MSamples/s, supporting 13-bit resolution
after external decimation over at most 500 kHz bandwidth.

EF2 preserves the electrical/data contract that Trouper controls: separate
1-bit I/Q, 32 MSamples/s, common clock, unchanged pin mapping and polarity.
Its spectral contract is not yet demonstrated. EF2 has a leaky second-order
NTF, while the normal SX1257 source presented to the SX1302 is fifth order.
The current 250 kHz brick-wall reconstruction is a useful fidelity test, but it
is not a model of the SX1302's undisclosed receive filters, channelizers, RSSI
path, packet detectors, or LoRa demodulators.

No SX1302 hardware is available for this project, so promotion cannot be made
conditional on a bench A/B test. The strongest available substitute is a
system-level simulation gate, with direct-device compatibility retained as a
documented residual integration risk rather than presented as proven.

Promotion therefore additionally requires:

- integrated noise and discrete-tone characterization across the actual
  Trouper scope, 125 and 250 kHz LoRa bandwidths, including STF gain/phase;
- comparison with both the production remodulator and a representative
  fifth-order SX1257-style stream, without fitting away gain or delay;
- LoRa detection/demodulation sweeps across SF7-SF12 x BW125/250, amplitude,
  AWGN, and CFO, comparing symbol/packet error curves against production;
- explicit acknowledgement that the proprietary SX1302 channelizer, packet
  detector, reported SNR, and RSSI paths remain unmodelled. A future hardware
  test would retire this risk, but its present unavailability is not a blocker
  if the simulation gate passes with margin.

### Initial LoRa receiver-proxy comparison

`rtl-test/tb/remod_compare/test_remod_lora_compare.py` drives identical LoRa
samples through production CIFF4 and EF2 RTL, then reconstructs each 1-bit
stream through the repository's bit-true CIC3/HB1/HB2 decimator and LoRa
demodulator. The comparison does not fit gain or phase; it removes only the
fixed causal receive-filter delay. Both variants measured the same seven-sample
delay.

All 12 clean combinations in the supported SF7-SF12 x BW125/250 scope decoded
without error for both variants. Four deterministic AWGN+CFO stress points also
produced identical symbol-error counts:

| Mode | SNR | CFO | Production | EF2 |
|---|---:|---:|---:|---:|
| SF7/BW250 | -16 dB | +0.20 bin | 8/12 | 8/12 |
| SF7/BW125 | -19 dB | -0.20 bin | 7/12 | 7/12 |
| SF12/BW250 | -28 dB | +0.20 bin | 2/3 | 2/3 |
| SF12/BW125 | -31 dB | -0.20 bin | 1/3 | 1/3 |

The cocotb run passed both tests. These sparse, deliberately difficult points
are useful evidence that EF2 does not introduce an obvious LoRa penalty. They
are not packet-error curves and do not prove equivalence to the proprietary
SX1302 receive chain. They motivated the denser simulation-only gate below.

### Dense paired LoRa curves

SGE job 5752 completed three concurrent RTL curve profiles over representative
SF7, SF9, and SF12 endpoints at both 125 and 250 kHz. Every point uses identical
symbols and normalized AWGN for production and EF2. The normalized noise vector
is also reused across adjacent points in a mode, reducing curve-to-curve Monte
Carlo wiggle. Sample counts are 96 symbols per SF7 point, 24 per SF9 point, and
12 per SF12 point. Those unequal counts bound RTL runtime but make SF12 crossing
estimates visibly coarser.

- SNR: 42 points, seven per mode, 2 dB spacing, fixed +0.20-bin CFO;
- CFO: 42 points, -0.45 to +0.45 bin, at the mode transition SNR + 4 dB;
- amplitude/headroom: 54 points, 12 to 76 total-RMS input counts, constant SNR
  and zero CFO.

The raw CSVs are under `reports/remod_lora_curves_20260909/`; the combined plot
is `reports/sd_remod_ef2_lora_curves_20260909.png`.

| Profile | Points tied by total errors | Points EF2 worse | Points production worse | Production errors | EF2 errors |
|---|---:|---:|---:|---:|---:|
| SNR | 32/42 | 10/42 | 0/42 | 997 | 1,011 |
| CFO | 27/42 | 15/42 | 0/42 | 402 | 430 |
| Amplitude | 44/54 | 9/54 | 1/54 | 114 | 126 |

Across all 6,072 point-symbol observations, production made 1,513 errors and
EF2 made 1,567, a difference of 54 decisions or 0.89 percentage points. The
paired breakdown is more revealing: there are 56 observations where production
alone is correct and only two where EF2 alone is correct. These observations
are correlated across curve points, so they must not be treated as 6,072
independent Bernoulli trials or assigned an aggregate p-value.

The strongest individual separation is SF7/BW250 at -0.30-bin CFO: production
has 19/96 errors and EF2 has 24/96, with five production-only successes and no
EF2-only successes. The uncorrected exact paired test is p=0.0625; no individual
point crosses p<0.05, and multiple comparisons would weaken that evidence
further. Nevertheless, the one-sided pattern over many points is consistent
enough that the present data should not be described as an exact tie.

Linear interpolation of the coarse SNR curves gives the following apparent 50%
SER crossings. Positive delta means EF2 requires more input SNR:

| Mode | Production | EF2 | Apparent EF2 penalty |
|---|---:|---:|---:|
| SF7/BW250 | -15.000 dB | -14.917 dB | 0.083 dB |
| SF7/BW125 | -17.867 dB | -17.759 dB | 0.108 dB |
| SF9/BW250 | -20.356 dB | -20.200 dB | 0.156 dB |
| SF9/BW125 | -22.467 dB | -22.371 dB | 0.095 dB |
| SF12/BW250 | -28.333 dB | -27.500 dB | 0.833 dB |
| SF12/BW125 | -31.500 dB | -31.500 dB | 0.000 dB |

The four well-populated SF7/SF9 curves suggest roughly a 0.1-0.16 dB loss. The
0.83 dB SF12/BW250 value is based on only 12 symbols per point and one coarse
transition interval; it is not precise enough to book as a link-budget loss.
All 138 points retain the same seven-sample production/EF2 receive-filter delay.
The amplitude penalty appears only at SF7; SF9 and SF12 amplitude curves are
exact production/EF2 ties over the tested 12-76-count range.

The dense curves therefore reject strict behavioral equivalence for this EF2
revision while showing that the penalty is small. Before accepting a relaxed
system requirement, rerun the identified SF7 CFO and SF12/BW250 transition
points with larger independent symbol sets, or retune the EF2 leakage
coefficient and repeat these same curves.

### Proposed requirement treatment if EF2 is promoted

The current requirements should be relaxed only where they prescribe an
implementation rather than a system-visible result:

- revise TRPR-RMD-001 from a mandatory fourth-order CIFF architecture to an
  implementation-independent 32 MSample/s, 1-bit I/Q receive-stream contract;
- harmonize TRPR-RMD-004 and TRPR-RMD-006 to the realizable integer input set
  -89 through +89 (`abs(input) < 90`), removing the current boundary ambiguity;
- retain TRPR-RMD-005 (>40 dB SQNR at -6 dBFS), TRPR-RMD-007 (<1 LSB RMS), and
  the output-dither limit initially, because EF2 already passes them. Numerical
  relaxation should occur only if the SF7-SF12 x BW125/250 system sweep shows a
  quantified reason and an acceptable symbol/packet-error penalty.

This keeps the specification tied to what Trouper and the downstream receiver
need, while allowing a smaller internal DSM topology. It avoids claiming an
SX1257-equivalent fifth-order/13-bit ADC, which is unnecessary for an int8
Trouper signal path and cannot be demonstrated without the receiver hardware.

## Equal-flow synthesis and timing

Both alternatives were synthesized with Yosys/ABC against the GF180 MCU 7T5V0
TT library using `abc -D 31250`. OpenSTA used the SS/125 C/3.00 V library and a
31.25 ns register-to-register clock. This is a pre-layout comparison, not P&R
signoff.

| Variant | Cells | Mapped area | SS WNS | SS TNS |
|---|---:|---:|---:|---:|
| Production interpolator + CIFF4 | 3,124 | 78,834.02 um^2 | -17.07 ns | -399.20 ns |
| Experimental interpolator + EF2 | 1,759 | 45,438.44 um^2 | -12.64 ns | -496.74 ns |

EF2 reduces cells by 43.7%, mapped area by 42.4%, and improves the worst path by
4.43 ns. Its aggregate TNS is 97.54 ns worse, so timing is not uniformly better,
and neither variant meets 31.25 ns at this pessimistic SS corner.

## Equal-config top-level P&R

Full LibreLane runs used the self-declared canonical
`src/config/trouper_top_minff_rcx.json`: the same 1,675 x 1,110 um A40
floorplan, 65% target density, libraries, SDC, routing rules, and signoff flow.
The EF2 run changed only the production re-modulator sources to
`sd_remod_ef2.v` plus a module-name compatibility wrapper. Production was job
5746 and EF2 was job 5747.

| Final metric | Production | EF2 | EF2 change |
|---|---:|---:|---:|
| Synthesized cells | 38,141 | 37,102 | -1,039 (-2.72%) |
| Synthesized mapped area | 1,073,110.35 um^2 | 1,046,677.95 um^2 | -2.46% |
| Post-route standard cells | 51,890 | 50,945 | -945 (-1.82%) |
| Post-route standard-cell area | 1,257,310 um^2 | 1,239,760 um^2 | -1.40% |
| Detailed-route wire length | 2,395,098 um | 2,360,035 um | -1.46% |
| SS/125 C/3.00 V setup WNS | -12.899 ns | -14.528 ns | -1.628 ns worse |
| SS setup TNS | -1,175.066 ns | -808.279 ns | 366.787 ns (31.2%) better |
| SS setup violations | 197 | 146 | -51 (-25.9%) |
| Hold violations, all corners | 0 | 0 | equal |
| Detailed-route DRC | 0 | 0 | equal |
| Magic DRC | 0 | 0 | equal |
| LVS errors | 0 | 0 | equal |
| XOR differences | 0 | 0 | equal |
| Antenna violations | 0 | 0 | equal |

Both runs have zero setup violations at nominal TT and fast FF and both miss
the slow-corner setup target. EF2's nominal reported positive slack is 2.892 ns
versus 3.150 ns for production. Vectorless total-power estimates were 0.2980 W
for EF2 and 0.2917 W for production; this 2.2% increase is not an activity-based
power conclusion and should not be used as a promotion criterion without a
common realistic SAIF/VCD.

The P&R result supports the proposed mechanism only in aggregate: fewer cells
and less wire reduce TNS and violation count. It disproves the stronger claim
that smaller size alone necessarily improves the top-level worst path. The
production critical path is inside its re-modulator; EF2 eliminates it, but its
run's new critical path is an unrelated `timing_ref` to TACC path and is worse.

## Recommendation

Do not promote this exact EF2 revision yet. It meets the no-additional-area goal
in both isolated synthesis and equal-config full P&R, but the dense curves show
a small, systematic receiver-proxy penalty rather than equivalence. Because the
whole-chip saving is only 1.40% post-route area and worst-path timing did not
improve, silently relaxing system performance is not justified by the present
trade.

EF2 remains the leading redesign starting point. The next efficient step is to
retune its leaky pole around 0.75 and rerun the same CSV-producing curves, with a
larger targeted confirmation at SF7/-0.30-bin CFO and the SF12/BW250 SNR
transition. Promotion would then require an explicit decision that the measured
sensitivity/CFO delta is within the system link budget, plus the longer
stability and `en`/reset tests. SX1302 compatibility remains a residual risk:
this receiver proxy cannot establish equivalence to Semtech's undisclosed
channelizer and demodulator internals.

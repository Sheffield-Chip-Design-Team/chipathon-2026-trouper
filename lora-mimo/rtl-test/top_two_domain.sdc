# top_two_domain.sdc — top-level timing constraints for the two-clock architecture
#
# clk_32m domain : decimator (CIC), sigma-delta remodulator, SX1302 SPI
# clk_16m domain : mrc_combiner, weight_gen, training_accum, FFT, PicoRV32
#                  generated internally by a /2 toggle FF from clk_32m
#
# CDC crossings have trivial timing (data valid rates << either clock),
# but are still constrained via set_max_delay to bound the analysis.

# Primary clock: 32 MHz input
create_clock -name clk_32m -period 31.25 [get_ports clk_32m]

# Generated clock: clk_16m is clk_32m divided by 2.
# The /2 FF output net should match the actual net name in the synthesised netlist.
create_generated_clock -name clk_16m \
    -source [get_ports clk_32m] \
    -divide_by 2 \
    [get_nets clk_16m]

# Clock uncertainty
set_clock_uncertainty 0.25 [get_clocks clk_32m]
set_clock_uncertainty 0.25 [get_clocks clk_16m]

# I/O delays — clk_32m domain (decimator inputs, remod output, SPI)
set_input_delay  2.0 -clock clk_32m [get_ports {sigma_delta_i* sigma_delta_q* spi_*}]
set_output_delay 2.0 -clock clk_32m [get_ports {remod_out* spi_miso}]

# I/O delays — clk_16m domain (weight bus, combined output, control)
set_input_delay  2.0 -clock clk_16m [get_ports {W_re* W_im* W_valid x_valid mode bypass_ant}]
set_output_delay 2.0 -clock clk_16m [get_ports {y_i y_q y_valid}]

# CDC: clk_32m -> clk_16m (decimator output -> DSP input)
# Data valid rate is 125 kS/s; one sample every 256 clk_32m cycles.
# Bound to one clk_16m period — more than sufficient.
set_max_delay 62.5 -from [get_clocks clk_32m] -to [get_clocks clk_16m] -datapath_only

# CDC: clk_16m -> clk_32m (DSP output -> remod input)
# Data valid rate is 125 kS/s; one sample every 128 clk_16m cycles.
# Bound to one clk_32m period.
set_max_delay 31.25 -from [get_clocks clk_16m] -to [get_clocks clk_32m] -datapath_only

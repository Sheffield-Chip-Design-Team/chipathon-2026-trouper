# Prevent CTS from buffering SPI_SCK — it has low fanout and a clkbuf_12
# causes DRT-0073 in congested areas near the SRAM macros.
set_dont_touch [get_nets {SPI_SCK}]

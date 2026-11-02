# Post-Silicon Test Plan

1. Continue to test [RF front-end board](https://gitlab.com/m0rtal/miso_frontend) with FPGA until silicon is back. Aim to prove PSRAM interface and SX1257 IQ data interface is working.

2. Extend the RF front-end board to include the GF180 test chip. Confirm the layout of the packaged chip-on-board when designing this board.

3. When chip arrives, perform initial bring up. This includes:
    - Test communication with SPI slave
    - Test QSPI interface between ASIC and PSRAM
    - Test single-channel reception of SX1257 RFIC

4.  Once confident with functionality, proceed to characterisation tests. These include:
    - Conductance tests of the 4 receivers using power splitter to apply the same LoRa signal to all receivers.
    - Use attenuators and co-axial cables of different lengths to emulate channel phase and amplitude imbalances in order to test the MRC concept.
    - Test over-the-air tests using a transmitter LoRa node. Compare improvements with a single receiver to see how close to the 6dB SNR improvement can be achieved.

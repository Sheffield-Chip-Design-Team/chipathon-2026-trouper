"""Six direct combiner -> 1-bit remodulator transfer-function cases."""
import math
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_NS = 31.25
OSR = 64

async def reset(dut):
    dut.rst_n.value = 0; dut.x_valid.value = 0; dut.x_i.value = 0; dut.x_q.value = 0
    dut.w_re.value = 127; dut.w_im.value = 0; dut.pgs.value = 1; dut.mode.value = 0
    await ClockCycles(dut.clk, 5); dut.rst_n.value = 1; await ClockCycles(dut.clk, 2)

async def run_tone(dut, amp, pgs, mode=0, n=96):
    await reset(dut); dut.pgs.value = pgs; dut.mode.value = mode
    got_i=[]; got_q=[]; exp_i=[]; exp_q=[]
    for k in range(n):
        i=round(amp*math.sin(2*math.pi*k/32)); q=round(amp*math.cos(2*math.pi*k/32))
        dut.x_i.value=i & 255; dut.x_q.value=q & 255; dut.x_valid.value=1
        await RisingEdge(dut.clk); dut.x_valid.value=0
        for _ in range(42):
            await RisingEdge(dut.clk)
            if int(dut.y_valid.value): break
        assert int(dut.y_valid.value), 'combiner did not finish'
        yi=int(dut.y_i.value.to_signed()); yq=int(dut.y_q.value.to_signed())
        # y_valid and y_i/q update on this edge; sd_remod consumes them on the
        # following edge, so do not include the preceding held sample.
        await RisingEdge(dut.clk)
        si=sq=0
        for _ in range(OSR):
            await RisingEdge(dut.clk); si += 1 if int(dut.out_i.value) else -1; sq += 1 if int(dut.out_q.value) else -1
        got_i.append(si*127/OSR); got_q.append(sq*127/OSR); exp_i.append(yi); exp_q.append(yq)
    # Ignore reset/filter transient; fitted correlation catches gain/phase/sign errors.
    for actual, expected in ((got_i[12:], exp_i[12:]), (got_q[12:], exp_q[12:])):
        best = 0.0
        for lag in range(-4, 5):
            a = actual[max(0, lag):len(actual) + min(0, lag)]
            e = expected[max(0, -lag):len(expected) - max(0, lag)]
            dot=sum(x*y for x,y in zip(a,e)); norm=math.sqrt(sum(x*x for x in a)*sum(y*y for y in e))
            best=max(best, dot/norm if norm else 0.0)
        assert best > 0.80, f'transfer correlation {best:.3f}'

@cocotb.test()
async def test_bypass_identity_tone(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start()); await run_tone(dut, 64, 1, mode=1)

@cocotb.test()
async def test_unity_mrc_low(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start()); await run_tone(dut, 16, 1)

@cocotb.test()
async def test_unity_mrc_nominal(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start()); await run_tone(dut, 64, 1)

@cocotb.test()
async def test_unity_mrc_boundary(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start()); await run_tone(dut, 90, 1)

@cocotb.test()
async def test_unity_mrc_guarded(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start()); await run_tone(dut, 64, 0)

@cocotb.test()
async def test_unity_mrc_signed_iq(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start()); await run_tone(dut, 64, 1)

import numpy as np

def quantize(x: np.ndarray, bits: int, signed: bool = True, round_mode: str = 'floor') -> np.ndarray:
    """
    Bit-true quantization with saturation.
    
    Parameters
    ----------
    x          : input array (floating point)
    bits       : number of bits
    signed     : if true, uses 2's complement range
    round_mode : 'floor', 'ceil', or 'round'
    """
    if signed:
        low, high = -(2**(bits-1)), 2**(bits-1) - 1
    else:
        low, high = 0, 2**bits - 1
        
    if round_mode == 'floor':
        x_q = np.floor(x)
    elif round_mode == 'ceil':
        x_q = np.ceil(x)
    else: # round to nearest
        x_q = np.round(x)
        
    return np.clip(x_q, low, high)

def quantize_q1_15(x: np.ndarray) -> np.ndarray:
    """
    Quantize to signed 16-bit Q1.15 format.
    """
    # Scale x by 2^15, quantize to 16 bits, then scale back
    val = quantize(x * (2**15), 16, signed=True, round_mode='round')
    return val / (2**15)

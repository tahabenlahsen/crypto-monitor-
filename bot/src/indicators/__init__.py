"""Indicator library for the XAUUSD bot.

A broad, deliberately diverse toolkit: classic trend/momentum indicators plus
several that retail traders routinely overlook (Supertrend, Ichimoku, Fisher
Transform, TSI, VWAP, Keltner squeeze, Aroon, CMF, MFI, Parabolic SAR).
"""
from .core import crossover, crossunder, rma, true_range
from .trend import (
    adx,
    aroon,
    ema,
    hma,
    ichimoku,
    macd,
    parabolic_sar,
    sma,
    supertrend,
    wma,
)
from .momentum import (
    cci,
    fisher_transform,
    mfi,
    roc,
    rsi,
    stochastic,
    tsi,
    williams_r,
)
from .volatility import (
    atr,
    bollinger,
    donchian,
    historical_volatility,
    keltner,
    squeeze,
)
from .volume import accum_dist, cmf, obv, vwap

__all__ = [
    # core
    "crossover", "crossunder", "rma", "true_range",
    # trend
    "sma", "ema", "wma", "hma", "macd", "adx", "supertrend",
    "ichimoku", "parabolic_sar", "aroon",
    # momentum
    "rsi", "stochastic", "cci", "williams_r", "mfi", "roc", "tsi", "fisher_transform",
    # volatility
    "atr", "bollinger", "keltner", "donchian", "squeeze", "historical_volatility",
    # volume
    "obv", "vwap", "cmf", "accum_dist",
]

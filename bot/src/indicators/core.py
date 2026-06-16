"""Core indicator helpers shared across the indicator modules.

Everything is implemented in pure pandas/numpy so the library installs cleanly
on any platform (no TA-Lib / C-extension build step required).
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def true_range(high: pd.Series, low: pd.Series, close: pd.Series) -> pd.Series:
    """Wilder's True Range."""
    prev_close = close.shift(1)
    ranges = pd.concat(
        [
            high - low,
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    )
    return ranges.max(axis=1)


def rma(series: pd.Series, period: int) -> pd.Series:
    """Wilder's smoothing (a.k.a. RMA / SMMA).

    Equivalent to an EWM with alpha = 1/period. Used by RSI, ATR and ADX.
    """
    return series.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()


def crossover(a: pd.Series, b: pd.Series) -> pd.Series:
    """True on the bar where ``a`` crosses above ``b``."""
    return (a > b) & (a.shift(1) <= b.shift(1))


def crossunder(a: pd.Series, b: pd.Series) -> pd.Series:
    """True on the bar where ``a`` crosses below ``b``."""
    return (a < b) & (a.shift(1) >= b.shift(1))


def clamp(series: pd.Series, lower: float, upper: float) -> pd.Series:
    return series.clip(lower=lower, upper=upper)


__all__ = ["true_range", "rma", "crossover", "crossunder", "clamp"]

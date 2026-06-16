"""Volume-flow indicators.

For XAUUSD via MetaTrader 5 these operate on tick-volume (number of price
changes), which is a reliable proxy for real activity in FX/metals."""
from __future__ import annotations

import numpy as np
import pandas as pd


def obv(close: pd.Series, volume: pd.Series) -> pd.Series:
    """On-Balance Volume."""
    direction = np.sign(close.diff()).fillna(0.0)
    return (direction * volume).cumsum()


def vwap(high: pd.Series, low: pd.Series, close: pd.Series, volume: pd.Series, period: int = 20) -> pd.Series:
    """Rolling Volume-Weighted Average Price - the level institutions watch and
    most retail traders ignore."""
    tp = (high + low + close) / 3.0
    pv = (tp * volume).rolling(period).sum()
    vol = volume.rolling(period).sum().replace(0, np.nan)
    return pv / vol


def cmf(
    high: pd.Series, low: pd.Series, close: pd.Series, volume: pd.Series, period: int = 20
) -> pd.Series:
    """Chaikin Money Flow - measures buying vs selling pressure."""
    rng = (high - low).replace(0, np.nan)
    mf_mult = ((close - low) - (high - close)) / rng
    mf_vol = mf_mult * volume
    return mf_vol.rolling(period).sum() / volume.rolling(period).sum().replace(0, np.nan)


def accum_dist(high: pd.Series, low: pd.Series, close: pd.Series, volume: pd.Series) -> pd.Series:
    """Accumulation / Distribution line."""
    rng = (high - low).replace(0, np.nan)
    mf_mult = ((close - low) - (high - close)) / rng
    return (mf_mult * volume).cumsum()


__all__ = ["obv", "vwap", "cmf", "accum_dist"]

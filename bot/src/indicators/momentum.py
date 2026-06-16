"""Momentum / oscillator indicators.

Beyond RSI and Stochastic this includes CCI, Williams %R, the Money Flow Index,
the True Strength Index and the Fisher Transform - all powerful and commonly
ignored by retail traders.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .core import clamp, rma
from .trend import ema


def rsi(series: pd.Series, period: int = 14) -> pd.Series:
    """Wilder's Relative Strength Index."""
    delta = series.diff()
    gain = rma(delta.clip(lower=0), period)
    loss = rma(-delta.clip(upper=0), period)
    rs = gain / loss.replace(0, np.nan)
    out = 100 - (100 / (1 + rs))
    return out.fillna(100)


def stochastic(
    high: pd.Series, low: pd.Series, close: pd.Series, k: int = 14, d: int = 3, smooth: int = 3
) -> pd.DataFrame:
    lowest = low.rolling(k).min()
    highest = high.rolling(k).max()
    raw_k = 100 * (close - lowest) / (highest - lowest).replace(0, np.nan)
    k_line = raw_k.rolling(smooth).mean()
    d_line = k_line.rolling(d).mean()
    return pd.DataFrame({"k": k_line, "d": d_line})


def cci(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 20) -> pd.Series:
    """Commodity Channel Index - despite the name, excellent for gold."""
    tp = (high + low + close) / 3.0
    ma = tp.rolling(period).mean()
    mad = tp.rolling(period).apply(lambda x: np.abs(x - x.mean()).mean(), raw=True)
    return (tp - ma) / (0.015 * mad.replace(0, np.nan))


def williams_r(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14) -> pd.Series:
    highest = high.rolling(period).max()
    lowest = low.rolling(period).min()
    return -100 * (highest - close) / (highest - lowest).replace(0, np.nan)


def mfi(
    high: pd.Series, low: pd.Series, close: pd.Series, volume: pd.Series, period: int = 14
) -> pd.Series:
    """Money Flow Index - a volume-weighted RSI. Underused but very effective."""
    tp = (high + low + close) / 3.0
    raw_flow = tp * volume
    pos = raw_flow.where(tp > tp.shift(1), 0.0)
    neg = raw_flow.where(tp < tp.shift(1), 0.0)
    pos_sum = pos.rolling(period).sum()
    neg_sum = neg.rolling(period).sum()
    ratio = pos_sum / neg_sum.replace(0, np.nan)
    return 100 - (100 / (1 + ratio))


def roc(series: pd.Series, period: int = 12) -> pd.Series:
    return 100 * (series - series.shift(period)) / series.shift(period)


def tsi(series: pd.Series, long: int = 25, short: int = 13) -> pd.Series:
    """True Strength Index - double-smoothed momentum, far cleaner than RSI."""
    momentum = series.diff()
    double = ema(ema(momentum, long), short)
    double_abs = ema(ema(momentum.abs(), long), short)
    return 100 * double / double_abs.replace(0, np.nan)


def fisher_transform(high: pd.Series, low: pd.Series, period: int = 10) -> pd.DataFrame:
    """Fisher Transform - sharpens turning points by gaussianising price.

    One of the most underrated reversal indicators available.
    """
    med = (high + low) / 2.0
    min_l = med.rolling(period).min()
    max_h = med.rolling(period).max()
    rng = (max_h - min_l).replace(0, np.nan)
    raw = (2 * (med - min_l) / rng - 1).to_numpy()

    n = len(raw)
    value = np.zeros(n)
    fish = np.zeros(n)
    for i in range(1, n):
        if np.isnan(raw[i]):
            continue
        value[i] = 0.33 * 2 * raw[i] + 0.67 * value[i - 1]
        value[i] = min(max(value[i], -0.999), 0.999)
        fish[i] = 0.5 * np.log((1 + value[i]) / (1 - value[i])) + 0.5 * fish[i - 1]

    fisher = pd.Series(fish, index=high.index)
    return pd.DataFrame({"fisher": fisher, "trigger": fisher.shift(1)})


__all__ = [
    "rsi", "stochastic", "cci", "williams_r", "mfi", "roc", "tsi", "fisher_transform",
]

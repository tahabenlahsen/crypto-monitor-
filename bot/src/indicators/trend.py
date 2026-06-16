"""Trend & direction indicators.

Includes the popular ones (EMA/SMA/MACD/ADX) plus several that retail traders
frequently overlook: Supertrend, Ichimoku, Parabolic SAR, Aroon and the Hull
Moving Average.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .core import rma, true_range


def sma(series: pd.Series, period: int) -> pd.Series:
    return series.rolling(period, min_periods=period).mean()


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False, min_periods=period).mean()


def wma(series: pd.Series, period: int) -> pd.Series:
    weights = np.arange(1, period + 1, dtype=float)
    return series.rolling(period).apply(
        lambda x: np.dot(x, weights) / weights.sum(), raw=True
    )


def hma(series: pd.Series, period: int) -> pd.Series:
    """Hull Moving Average - smoother and far less laggy than a plain MA."""
    half = max(int(period / 2), 1)
    sqrt_p = max(int(np.sqrt(period)), 1)
    return wma(2 * wma(series, half) - wma(series, period), sqrt_p)


def macd(
    series: pd.Series, fast: int = 12, slow: int = 26, signal: int = 9
) -> pd.DataFrame:
    macd_line = ema(series, fast) - ema(series, slow)
    signal_line = macd_line.ewm(span=signal, adjust=False).mean()
    hist = macd_line - signal_line
    return pd.DataFrame({"macd": macd_line, "signal": signal_line, "hist": hist})


def adx(
    high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14
) -> pd.DataFrame:
    """Average Directional Index with +DI / -DI."""
    up_move = high.diff()
    down_move = -low.diff()

    plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
    plus_dm = pd.Series(plus_dm, index=high.index)
    minus_dm = pd.Series(minus_dm, index=high.index)

    atr = rma(true_range(high, low, close), period)
    plus_di = 100 * rma(plus_dm, period) / atr
    minus_di = 100 * rma(minus_dm, period) / atr

    dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
    adx_line = rma(dx, period)
    return pd.DataFrame({"adx": adx_line, "plus_di": plus_di, "minus_di": minus_di})


def supertrend(
    high: pd.Series, low: pd.Series, close: pd.Series, period: int = 10, multiplier: float = 3.0
) -> pd.DataFrame:
    """Supertrend - an excellent, underused trailing trend filter.

    Returns the trend line and a direction column (+1 bullish, -1 bearish).
    """
    atr = rma(true_range(high, low, close), period)
    hl2 = (high + low) / 2.0
    upper = hl2 + multiplier * atr
    lower = hl2 - multiplier * atr

    upper = upper.to_numpy()
    lower = lower.to_numpy()
    close_arr = close.to_numpy()
    n = len(close_arr)

    final_upper = np.full(n, np.nan)
    final_lower = np.full(n, np.nan)
    trend = np.ones(n)

    for i in range(n):
        if i == 0 or np.isnan(upper[i]):
            final_upper[i] = upper[i]
            final_lower[i] = lower[i]
            continue
        final_upper[i] = (
            upper[i]
            if (upper[i] < final_upper[i - 1] or close_arr[i - 1] > final_upper[i - 1])
            else final_upper[i - 1]
        )
        final_lower[i] = (
            lower[i]
            if (lower[i] > final_lower[i - 1] or close_arr[i - 1] < final_lower[i - 1])
            else final_lower[i - 1]
        )
        if close_arr[i] > final_upper[i - 1]:
            trend[i] = 1
        elif close_arr[i] < final_lower[i - 1]:
            trend[i] = -1
        else:
            trend[i] = trend[i - 1]

    line = np.where(trend == 1, final_lower, final_upper)
    return pd.DataFrame(
        {"supertrend": line, "direction": trend}, index=close.index
    )


def ichimoku(
    high: pd.Series,
    low: pd.Series,
    close: pd.Series,
    tenkan: int = 9,
    kijun: int = 26,
    senkou_b: int = 52,
) -> pd.DataFrame:
    """Ichimoku Kinko Hyo - a full trend system most people never use properly."""
    conv = (high.rolling(tenkan).max() + low.rolling(tenkan).min()) / 2
    base = (high.rolling(kijun).max() + low.rolling(kijun).min()) / 2
    span_a = ((conv + base) / 2).shift(kijun)
    span_b = ((high.rolling(senkou_b).max() + low.rolling(senkou_b).min()) / 2).shift(kijun)
    chikou = close.shift(-kijun)
    return pd.DataFrame(
        {
            "tenkan": conv,
            "kijun": base,
            "senkou_a": span_a,
            "senkou_b": span_b,
            "chikou": chikou,
        }
    )


def parabolic_sar(
    high: pd.Series, low: pd.Series, step: float = 0.02, max_step: float = 0.2
) -> pd.Series:
    """Parabolic SAR (stop-and-reverse) trailing stop indicator."""
    high_arr = high.to_numpy()
    low_arr = low.to_numpy()
    n = len(high_arr)
    sar = np.full(n, np.nan)
    if n == 0:
        return pd.Series(sar, index=high.index)

    bull = True
    af = step
    ep = high_arr[0]
    sar[0] = low_arr[0]

    for i in range(1, n):
        prev_sar = sar[i - 1]
        if bull:
            sar[i] = prev_sar + af * (ep - prev_sar)
            sar[i] = min(sar[i], low_arr[i - 1], low_arr[max(i - 2, 0)])
            if high_arr[i] > ep:
                ep = high_arr[i]
                af = min(af + step, max_step)
            if low_arr[i] < sar[i]:
                bull = False
                sar[i] = ep
                ep = low_arr[i]
                af = step
        else:
            sar[i] = prev_sar + af * (ep - prev_sar)
            sar[i] = max(sar[i], high_arr[i - 1], high_arr[max(i - 2, 0)])
            if low_arr[i] < ep:
                ep = low_arr[i]
                af = min(af + step, max_step)
            if high_arr[i] > sar[i]:
                bull = True
                sar[i] = ep
                ep = high_arr[i]
                af = step

    return pd.Series(sar, index=high.index)


def aroon(high: pd.Series, low: pd.Series, period: int = 25) -> pd.DataFrame:
    """Aroon - measures how recently highs/lows occurred; great for spotting
    the *start* of trends, which lagging MAs miss."""
    def _since_high(x: np.ndarray) -> float:
        return (period - (np.argmax(x))) / period * 100

    def _since_low(x: np.ndarray) -> float:
        return (period - (np.argmin(x))) / period * 100

    up = high.rolling(period + 1).apply(_since_high, raw=True)
    down = low.rolling(period + 1).apply(_since_low, raw=True)
    return pd.DataFrame({"aroon_up": up, "aroon_down": down, "aroon_osc": up - down})


__all__ = [
    "sma", "ema", "wma", "hma", "macd", "adx",
    "supertrend", "ichimoku", "parabolic_sar", "aroon",
]

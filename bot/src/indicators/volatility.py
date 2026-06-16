"""Volatility & channel indicators - the backbone of position sizing and
breakout detection."""
from __future__ import annotations

import numpy as np
import pandas as pd

from .core import rma, true_range
from .trend import ema


def atr(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14) -> pd.Series:
    """Average True Range (Wilder). Drives every stop-loss in the bot."""
    return rma(true_range(high, low, close), period)


def bollinger(series: pd.Series, period: int = 20, mult: float = 2.0) -> pd.DataFrame:
    mid = series.rolling(period).mean()
    std = series.rolling(period).std(ddof=0)
    upper = mid + mult * std
    lower = mid - mult * std
    width = (upper - lower) / mid.replace(0, np.nan)
    pct_b = (series - lower) / (upper - lower).replace(0, np.nan)
    return pd.DataFrame(
        {"mid": mid, "upper": upper, "lower": lower, "bandwidth": width, "pct_b": pct_b}
    )


def keltner(
    high: pd.Series, low: pd.Series, close: pd.Series, period: int = 20, mult: float = 2.0
) -> pd.DataFrame:
    """Keltner Channels - ATR-based bands; pairs with Bollinger to detect
    'squeezes' (low-volatility coils that precede big gold moves)."""
    mid = ema(close, period)
    rng = atr(high, low, close, period)
    return pd.DataFrame(
        {"mid": mid, "upper": mid + mult * rng, "lower": mid - mult * rng}
    )


def donchian(high: pd.Series, low: pd.Series, period: int = 20) -> pd.DataFrame:
    upper = high.rolling(period).max()
    lower = low.rolling(period).min()
    return pd.DataFrame({"upper": upper, "lower": lower, "mid": (upper + lower) / 2})


def squeeze(
    high: pd.Series, low: pd.Series, close: pd.Series, period: int = 20
) -> pd.Series:
    """True when Bollinger Bands are inside Keltner Channels (volatility squeeze)."""
    bb = bollinger(close, period)
    kc = keltner(high, low, close, period)
    return (bb["lower"] > kc["lower"]) & (bb["upper"] < kc["upper"])


def historical_volatility(close: pd.Series, period: int = 20) -> pd.Series:
    log_ret = np.log(close / close.shift(1))
    return log_ret.rolling(period).std(ddof=0) * np.sqrt(252)


__all__ = [
    "atr", "bollinger", "keltner", "donchian", "squeeze", "historical_volatility",
]

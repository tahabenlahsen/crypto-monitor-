"""Trend-following strategy: ride sustained directional moves.

Combines an EMA regime, the ADX trend-strength filter, MACD histogram and the
Supertrend trailing filter. It only fires when the market is genuinely trending
(ADX above threshold), which keeps it out of choppy ranges."""
from __future__ import annotations

import pandas as pd

from .. import indicators as ind
from .base import FLAT, LONG, SHORT, Signal, Strategy, finite, last


class TrendFollowingStrategy(Strategy):
    name = "trend_following"
    min_bars = 120

    def __init__(self, fast: int = 20, slow: int = 50, adx_min: float = 20.0):
        self.fast = fast
        self.slow = slow
        self.adx_min = adx_min

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        close = df["close"]
        ema_fast = last(ind.ema(close, self.fast))
        ema_slow = last(ind.ema(close, self.slow))
        adx_df = ind.adx(df["high"], df["low"], close)
        adx_v = last(adx_df["adx"])
        hist = last(ind.macd(close)["hist"])
        st = ind.supertrend(df["high"], df["low"], close)
        st_dir = last(st["direction"])

        if not finite(ema_fast, ema_slow, adx_v, hist, st_dir):
            return Signal()

        if adx_v < self.adx_min:
            return Signal(FLAT, 0.0, f"ADX {adx_v:.0f} < {self.adx_min:.0f} (no trend)")

        bull = [ema_fast > ema_slow, hist > 0, st_dir > 0]
        bear = [ema_fast < ema_slow, hist < 0, st_dir < 0]

        # Trend strength scales confidence: ADX 20->0.0 weight, 50+->1.0 weight.
        strength = min(max((adx_v - self.adx_min) / 30.0, 0.0), 1.0)

        if all(bull):
            return Signal(LONG, 0.5 + 0.5 * strength,
                          f"Uptrend: EMA{self.fast}>EMA{self.slow}, MACD+, Supertrend up, ADX {adx_v:.0f}")
        if all(bear):
            return Signal(SHORT, 0.5 + 0.5 * strength,
                          f"Downtrend: EMA{self.fast}<EMA{self.slow}, MACD-, Supertrend down, ADX {adx_v:.0f}")

        # Partial agreement -> weaker signal in the majority direction.
        score = sum(bull) - sum(bear)
        if score >= 2:
            return Signal(LONG, 0.3 * strength + 0.2, "Partial uptrend agreement")
        if score <= -2:
            return Signal(SHORT, 0.3 * strength + 0.2, "Partial downtrend agreement")
        return Signal(FLAT, 0.0, "Mixed trend signals")

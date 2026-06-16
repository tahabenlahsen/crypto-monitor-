"""Ichimoku strategy: a complete trend system in one indicator.

Signals require price to be on the correct side of the Kumo (cloud) *and* a
Tenkan/Kijun cross in the same direction - a high-quality, slower confirmation
that complements the faster strategies in the ensemble."""
from __future__ import annotations

import pandas as pd

from .. import indicators as ind
from .base import FLAT, LONG, SHORT, Signal, Strategy, finite, last


class IchimokuStrategy(Strategy):
    name = "ichimoku"
    min_bars = 120

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        close = df["close"]
        ich = ind.ichimoku(df["high"], df["low"], close)
        price = last(close)
        tenkan = last(ich["tenkan"])
        kijun = last(ich["kijun"])
        span_a = last(ich["senkou_a"])
        span_b = last(ich["senkou_b"])

        if not finite(price, tenkan, kijun, span_a, span_b):
            return Signal()

        cloud_top = max(span_a, span_b)
        cloud_bot = min(span_a, span_b)

        above_cloud = price > cloud_top
        below_cloud = price < cloud_bot
        cloud_bull = span_a > span_b  # green cloud

        if above_cloud and tenkan > kijun:
            conf = 0.7 + (0.3 if cloud_bull else 0.0)
            return Signal(LONG, conf, "Price above bullish Kumo, Tenkan>Kijun")
        if below_cloud and tenkan < kijun:
            conf = 0.7 + (0.3 if not cloud_bull else 0.0)
            return Signal(SHORT, conf, "Price below bearish Kumo, Tenkan<Kijun")
        return Signal(FLAT, 0.0, "Price inside/against cloud")

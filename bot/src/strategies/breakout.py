"""Breakout strategy: catch volatility expansions out of consolidation.

Watches for a Bollinger-in-Keltner 'squeeze' releasing, confirmed by a Donchian
channel break and money-flow (CMF) in the breakout direction."""
from __future__ import annotations

import pandas as pd

from .. import indicators as ind
from .base import FLAT, LONG, SHORT, Signal, Strategy, finite, last


class BreakoutStrategy(Strategy):
    name = "breakout"
    min_bars = 80

    def __init__(self, channel: int = 20):
        self.channel = channel

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        close = df["close"]
        high, low = df["high"], df["low"]
        vol = df["volume"]

        dc = ind.donchian(high, low, self.channel)
        # Use the channel formed by *prior* bars so the current break is real.
        upper = last(dc["upper"].shift(1))
        lower = last(dc["lower"].shift(1))
        price = last(close)
        cmf_v = last(ind.cmf(high, low, close, vol))
        sq = ind.squeeze(high, low, close)
        # A squeeze that has just released gives the cleanest breakouts.
        recently_squeezed = bool(sq.iloc[-6:-1].any()) if len(sq) > 6 else False

        if not finite(upper, lower, price, cmf_v):
            return Signal()

        base_conf = 0.6 if recently_squeezed else 0.4

        if price > upper and cmf_v > 0:
            return Signal(LONG, base_conf + 0.2 * min(cmf_v * 5, 1.0),
                          f"Breakout above {upper:.2f} with positive money-flow")
        if price < lower and cmf_v < 0:
            return Signal(SHORT, base_conf + 0.2 * min(-cmf_v * 5, 1.0),
                          f"Breakdown below {lower:.2f} with negative money-flow")
        return Signal(FLAT, 0.0, "Inside channel / no breakout")

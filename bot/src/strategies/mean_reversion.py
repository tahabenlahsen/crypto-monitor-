"""Mean-reversion strategy: fade stretched moves back to the mean.

Uses RSI, Bollinger %b, Stochastic and Williams %R. It deliberately stands down
when ADX shows a strong trend, because fading a trend is how accounts die."""
from __future__ import annotations

import pandas as pd

from .. import indicators as ind
from .base import FLAT, LONG, SHORT, Signal, Strategy, finite, last


class MeanReversionStrategy(Strategy):
    name = "mean_reversion"
    min_bars = 60

    def __init__(self, rsi_low: float = 30, rsi_high: float = 70, adx_max: float = 25.0):
        self.rsi_low = rsi_low
        self.rsi_high = rsi_high
        self.adx_max = adx_max

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        close = df["close"]
        high, low = df["high"], df["low"]

        adx_v = last(ind.adx(high, low, close)["adx"])
        rsi_v = last(ind.rsi(close))
        pct_b = last(ind.bollinger(close)["pct_b"])
        stoch_k = last(ind.stochastic(high, low, close)["k"])
        wr = last(ind.williams_r(high, low, close))

        if not finite(adx_v, rsi_v, pct_b, stoch_k, wr):
            return Signal()

        # Only mean-revert in non-trending conditions.
        if adx_v > self.adx_max:
            return Signal(FLAT, 0.0, f"ADX {adx_v:.0f} too trendy for mean-reversion")

        long_votes = [rsi_v < self.rsi_low, pct_b < 0.05, stoch_k < 20, wr < -80]
        short_votes = [rsi_v > self.rsi_high, pct_b > 0.95, stoch_k > 80, wr > -20]

        n_long, n_short = sum(long_votes), sum(short_votes)

        if n_long >= 2 and n_long > n_short:
            return Signal(LONG, min(0.25 * n_long, 1.0),
                          f"Oversold: RSI {rsi_v:.0f}, %b {pct_b:.2f}, Stoch {stoch_k:.0f}")
        if n_short >= 2 and n_short > n_long:
            return Signal(SHORT, min(0.25 * n_short, 1.0),
                          f"Overbought: RSI {rsi_v:.0f}, %b {pct_b:.2f}, Stoch {stoch_k:.0f}")
        return Signal(FLAT, 0.0, "No mean-reversion extreme")

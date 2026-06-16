"""Momentum strategy: trade acceleration, not just direction.

Blends the MACD line/signal relationship, the True Strength Index (double-
smoothed momentum) and rate-of-change, with an RSI-50 directional bias."""
from __future__ import annotations

import pandas as pd

from .. import indicators as ind
from .base import FLAT, LONG, SHORT, Signal, Strategy, finite, last


class MomentumStrategy(Strategy):
    name = "momentum"
    min_bars = 80

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        close = df["close"]
        macd_df = ind.macd(close)
        macd_line = last(macd_df["macd"])
        signal_line = last(macd_df["signal"])
        tsi_series = ind.tsi(close)
        tsi_v = last(tsi_series)
        tsi_prev = last(tsi_series.iloc[:-1]) if len(tsi_series) > 1 else float("nan")
        roc_v = last(ind.roc(close))
        rsi_v = last(ind.rsi(close))

        if not finite(macd_line, signal_line, tsi_v, tsi_prev, roc_v, rsi_v):
            return Signal()

        tsi_rising = tsi_v > tsi_prev
        long_votes = [macd_line > signal_line, tsi_v > 0 and tsi_rising, roc_v > 0, rsi_v > 50]
        short_votes = [macd_line < signal_line, tsi_v < 0 and not tsi_rising, roc_v < 0, rsi_v < 50]

        n_long, n_short = sum(long_votes), sum(short_votes)
        if n_long >= 3:
            return Signal(LONG, min(0.25 * n_long, 1.0),
                          f"Momentum up: MACD+, TSI {tsi_v:.1f} rising, ROC {roc_v:.2f}")
        if n_short >= 3:
            return Signal(SHORT, min(0.25 * n_short, 1.0),
                          f"Momentum down: MACD-, TSI {tsi_v:.1f} falling, ROC {roc_v:.2f}")
        return Signal(FLAT, 0.0, "No clear momentum")

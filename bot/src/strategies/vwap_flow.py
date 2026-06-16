"""VWAP + money-flow strategy: trade with the institutional bid.

Most retail traders ignore VWAP entirely. This strategy aligns with it: long
when price holds above the rolling VWAP with positive Chaikin Money Flow and a
rising On-Balance-Volume, and the mirror image for shorts."""
from __future__ import annotations

import pandas as pd

from .. import indicators as ind
from .base import FLAT, LONG, SHORT, Signal, Strategy, finite, last


class VwapFlowStrategy(Strategy):
    name = "vwap_flow"
    min_bars = 60

    def __init__(self, period: int = 20):
        self.period = period

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        close = df["close"]
        high, low, vol = df["high"], df["low"], df["volume"]

        vwap_v = last(ind.vwap(high, low, close, vol, self.period))
        price = last(close)
        cmf_v = last(ind.cmf(high, low, close, vol))
        obv_series = ind.obv(close, vol)
        obv_now = last(obv_series)
        obv_past = last(obv_series.iloc[:-self.period]) if len(obv_series) > self.period else float("nan")

        if not finite(vwap_v, price, cmf_v, obv_now, obv_past):
            return Signal()

        obv_rising = obv_now > obv_past
        long_votes = [price > vwap_v, cmf_v > 0, obv_rising]
        short_votes = [price < vwap_v, cmf_v < 0, not obv_rising]

        n_long, n_short = sum(long_votes), sum(short_votes)
        if n_long == 3:
            return Signal(LONG, 0.5 + min(cmf_v, 0.5),
                          f"Above VWAP {vwap_v:.2f}, CMF {cmf_v:+.2f}, OBV rising")
        if n_short == 3:
            return Signal(SHORT, 0.5 + min(-cmf_v, 0.5),
                          f"Below VWAP {vwap_v:.2f}, CMF {cmf_v:+.2f}, OBV falling")
        return Signal(FLAT, 0.0, "No VWAP/flow alignment")

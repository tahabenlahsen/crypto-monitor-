"""Ensemble: combine many strategies into one robust decision.

Each member strategy votes with ``direction * confidence``, weighted by its
configured importance. The bot only acts when the *net* conviction clears a
threshold AND a minimum number of strategies agree - so a single noisy strategy
can never drag the account into a bad trade. This is what makes the bot 'rely on
a lot of indicators' rather than betting everything on one signal."""
from __future__ import annotations

from typing import List, Tuple

import pandas as pd

from .base import FLAT, LONG, SHORT, Signal, Strategy


class Ensemble(Strategy):
    name = "ensemble"

    def __init__(
        self,
        members: List[Tuple[Strategy, float]],
        threshold: float = 0.25,
        min_agree: int = 2,
    ):
        if not members:
            raise ValueError("Ensemble needs at least one member strategy")
        self.members = members
        self.threshold = threshold
        self.min_agree = min_agree
        self.min_bars = max(s.min_bars for s, _ in members)
        self.total_weight = sum(w for _, w in members) or 1.0

    def generate(self, df: pd.DataFrame) -> Signal:
        if self._guard(df):
            return Signal()

        net = 0.0
        long_count = 0
        short_count = 0
        contributors: dict = {}

        for strat, weight in self.members:
            sig = strat.generate(df)
            contrib = weight * sig.direction * sig.confidence
            net += contrib
            if sig.direction == LONG and sig.confidence > 0:
                long_count += 1
            elif sig.direction == SHORT and sig.confidence > 0:
                short_count += 1
            if sig.is_actionable:
                contributors[strat.name] = {
                    "dir": sig.direction,
                    "conf": round(sig.confidence, 2),
                    "reason": sig.reason,
                }

        score = net / self.total_weight  # roughly in [-1, 1]

        if score >= self.threshold and long_count >= self.min_agree and long_count > short_count:
            return Signal(LONG, min(abs(score), 1.0),
                          f"Ensemble LONG: {long_count} strategies agree (score {score:+.2f})",
                          contributors)
        if score <= -self.threshold and short_count >= self.min_agree and short_count > long_count:
            return Signal(SHORT, min(abs(score), 1.0),
                          f"Ensemble SHORT: {short_count} strategies agree (score {score:+.2f})",
                          contributors)
        return Signal(FLAT, 0.0,
                      f"No consensus (score {score:+.2f}, {long_count}L/{short_count}S)",
                      contributors)


def build_default_ensemble(weights: dict | None = None) -> Ensemble:
    """Construct the standard six-strategy ensemble used by the bot."""
    from .breakout import BreakoutStrategy
    from .ichimoku_strategy import IchimokuStrategy
    from .mean_reversion import MeanReversionStrategy
    from .momentum import MomentumStrategy
    from .trend_following import TrendFollowingStrategy
    from .vwap_flow import VwapFlowStrategy

    weights = weights or {}
    members: List[Tuple[Strategy, float]] = [
        (TrendFollowingStrategy(), weights.get("trend_following", 1.3)),
        (MomentumStrategy(), weights.get("momentum", 1.0)),
        (IchimokuStrategy(), weights.get("ichimoku", 1.1)),
        (BreakoutStrategy(), weights.get("breakout", 1.0)),
        (MeanReversionStrategy(), weights.get("mean_reversion", 0.8)),
        (VwapFlowStrategy(), weights.get("vwap_flow", 0.9)),
    ]
    return Ensemble(
        members,
        threshold=weights.get("threshold", 0.25),
        min_agree=int(weights.get("min_agree", 2)),
    )

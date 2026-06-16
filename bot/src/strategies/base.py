"""Strategy framework: the Signal value object and the Strategy base class.

Every strategy looks at a DataFrame of completed OHLCV bars and returns a single
Signal for the most recent bar. Strategies never place orders themselves - that
is the job of the risk manager and broker - which keeps them easy to test.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

LONG = 1
SHORT = -1
FLAT = 0


@dataclass
class Signal:
    """A trading intent for the current bar.

    direction:  +1 long, -1 short, 0 flat
    confidence: 0.0 - 1.0, how strongly the strategy believes in the direction
    reason:     human-readable explanation (shown in logs)
    """

    direction: int = FLAT
    confidence: float = 0.0
    reason: str = ""
    contributors: dict = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.direction = int(np.sign(self.direction))
        self.confidence = float(min(max(self.confidence, 0.0), 1.0))
        if self.direction == FLAT:
            self.confidence = 0.0

    @property
    def is_actionable(self) -> bool:
        return self.direction != FLAT and self.confidence > 0.0


def last(series: pd.Series) -> float:
    """Return the most recent finite value of a series, or NaN."""
    s = series.dropna()
    return float(s.iloc[-1]) if len(s) else float("nan")


def finite(*values: float) -> bool:
    return all(np.isfinite(v) for v in values)


class Strategy(ABC):
    """Base class for all strategies."""

    name: str = "strategy"
    min_bars: int = 60

    @abstractmethod
    def generate(self, df: pd.DataFrame) -> Signal:
        """Return a Signal for the last row of ``df`` (OHLCV, lowercase cols)."""

    def _guard(self, df: pd.DataFrame) -> bool:
        """Return True when there is not enough clean data to act."""
        return df is None or len(df) < self.min_bars

"""Broker abstraction.

The rest of the bot talks only to this interface, so the exact same engine,
strategies and risk manager run against the paper simulator or a live
MetaTrader 5 account with no code changes."""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import List, Optional

import pandas as pd


@dataclass
class Tick:
    time: datetime
    bid: float
    ask: float
    point: float = 0.01

    @property
    def mid(self) -> float:
        return (self.bid + self.ask) / 2.0

    @property
    def spread_points(self) -> float:
        return (self.ask - self.bid) / self.point


@dataclass
class Position:
    ticket: int
    symbol: str
    direction: int          # +1 long, -1 short
    volume: float
    entry_price: float
    sl: float
    tp: float
    open_time: datetime
    comment: str = ""


@dataclass
class OrderResult:
    ok: bool
    position: Optional[Position] = None
    message: str = ""


class Broker(ABC):
    symbol: str
    point: float
    contract_size: float

    @abstractmethod
    def equity(self) -> float: ...

    @abstractmethod
    def balance(self) -> float: ...

    @abstractmethod
    def last_tick(self) -> Tick: ...

    @abstractmethod
    def candles(self, count: int) -> pd.DataFrame:
        """Return the most recent ``count`` completed bars as a DataFrame with
        columns: open, high, low, close, volume (lowercase), time-indexed."""

    @abstractmethod
    def positions(self) -> List[Position]: ...

    @abstractmethod
    def open(self, direction: int, volume: float, sl: float, tp: float, comment: str = "") -> OrderResult: ...

    @abstractmethod
    def modify(self, ticket: int, sl: float, tp: float) -> bool: ...

    @abstractmethod
    def close(self, ticket: int) -> bool: ...

"""Paper-trading broker: a bar-driven account simulator.

It powers both the offline backtester and the live *paper* mode (real prices,
fake money). Fills include spread and commission, and stop-loss / take-profit
are checked intrabar against each bar's high/low so results are realistic
rather than optimistic."""
from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Optional

import pandas as pd

from .base import Broker, OrderResult, Position, Tick


class PaperBroker(Broker):
    def __init__(
        self,
        symbol: str = "XAUUSD",
        point: float = 0.01,
        contract_size: float = 100.0,
        starting_balance: float = 10_000.0,
        spread_points: float = 20.0,
        commission_per_lot: float = 0.0,
        history: Optional[pd.DataFrame] = None,
    ):
        self.symbol = symbol
        self.point = point
        self.contract_size = contract_size
        self._balance = starting_balance
        self.spread_points = spread_points
        self.commission_per_lot = commission_per_lot

        self._positions: Dict[int, Position] = {}
        self._next_ticket = 1
        self._time: Optional[datetime] = None
        self._bar: Optional[pd.Series] = None
        self._history = history if history is not None else pd.DataFrame()
        self.closed_trades: List[dict] = []
        self.equity_curve: List[tuple] = []

    # --- price plumbing ---------------------------------------------------
    @property
    def half_spread(self) -> float:
        return (self.spread_points * self.point) / 2.0

    def set_bar(self, time: datetime, bar: pd.Series, history: Optional[pd.DataFrame] = None) -> None:
        """Advance the simulated clock to a new completed bar."""
        self._time = time
        self._bar = bar
        if history is not None:
            self._history = history
        self._process_open_positions(bar)
        self.equity_curve.append((time, self.equity()))

    def last_tick(self) -> Tick:
        price = float(self._bar["close"]) if self._bar is not None else 0.0
        return Tick(self._time, price - self.half_spread, price + self.half_spread, self.point)

    def candles(self, count: int) -> pd.DataFrame:
        return self._history.tail(count).copy()

    # --- account ----------------------------------------------------------
    def balance(self) -> float:
        return self._balance

    def equity(self) -> float:
        tick = self.last_tick()
        floating = 0.0
        for p in self._positions.values():
            exit_price = tick.bid if p.direction > 0 else tick.ask
            floating += (exit_price - p.entry_price) * p.direction * p.volume * self.contract_size
        return self._balance + floating

    def positions(self) -> List[Position]:
        return list(self._positions.values())

    # --- orders -----------------------------------------------------------
    def open(self, direction: int, volume: float, sl: float, tp: float, comment: str = "") -> OrderResult:
        if volume <= 0:
            return OrderResult(False, message="Volume must be positive")
        tick = self.last_tick()
        entry = tick.ask if direction > 0 else tick.bid
        pos = Position(
            ticket=self._next_ticket,
            symbol=self.symbol,
            direction=int(direction),
            volume=volume,
            entry_price=entry,
            sl=sl,
            tp=tp,
            open_time=self._time,
            comment=comment,
        )
        self._positions[pos.ticket] = pos
        self._next_ticket += 1
        self._balance -= self.commission_per_lot * volume
        return OrderResult(True, pos, "filled")

    def modify(self, ticket: int, sl: float, tp: float) -> bool:
        pos = self._positions.get(ticket)
        if not pos:
            return False
        pos.sl, pos.tp = sl, tp
        return True

    def close(self, ticket: int, price: Optional[float] = None) -> bool:
        pos = self._positions.get(ticket)
        if not pos:
            return False
        tick = self.last_tick()
        if price is None:
            price = tick.bid if pos.direction > 0 else tick.ask
        self._realize(pos, price, self._time)
        del self._positions[ticket]
        return True

    # --- internal ---------------------------------------------------------
    def _realize(self, pos: Position, exit_price: float, when) -> None:
        pnl = (exit_price - pos.entry_price) * pos.direction * pos.volume * self.contract_size
        pnl -= self.commission_per_lot * pos.volume
        self._balance += pnl
        self.closed_trades.append(
            {
                "ticket": pos.ticket,
                "direction": pos.direction,
                "volume": pos.volume,
                "entry": pos.entry_price,
                "exit": exit_price,
                "pnl": pnl,
                "open_time": pos.open_time,
                "close_time": when,
                "comment": pos.comment,
            }
        )

    def _process_open_positions(self, bar: pd.Series) -> None:
        """Check SL/TP against the new bar. If both are touched, assume the
        stop hit first (the conservative, pessimistic assumption)."""
        high, low = float(bar["high"]), float(bar["low"])
        for ticket in list(self._positions.keys()):
            pos = self._positions[ticket]
            if pos.direction > 0:
                if pos.sl and low <= pos.sl:
                    self.close(ticket, pos.sl)
                elif pos.tp and high >= pos.tp:
                    self.close(ticket, pos.tp)
            else:
                if pos.sl and high >= pos.sl:
                    self.close(ticket, pos.sl)
                elif pos.tp and low <= pos.tp:
                    self.close(ticket, pos.tp)

"""Risk management - the most important part of any trading bot.

A profitable strategy with bad risk control still blows up; a mediocre strategy
with great risk control survives. This module enforces, on every single bar:

  * fixed-fractional position sizing from an ATR stop distance
  * ATR-based stop-loss / take-profit brackets
  * a hard daily-loss kill switch
  * a maximum-drawdown halt that stops all new trades
  * a cap on concurrent positions
  * a spread filter (don't trade when the broker spread is abnormal)
  * a trading-session filter (only trade liquid gold hours)
  * a minimum-confidence gate
  * trailing stops to lock in open profit
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, time
from typing import List, Tuple


@dataclass
class RiskParams:
    risk_per_trade: float = 0.01          # fraction of equity risked per trade
    sl_atr_mult: float = 2.0              # stop distance = ATR * this
    tp_atr_mult: float = 3.0              # target distance = ATR * this (1.5 R:R)
    trail_atr_mult: float = 2.0           # trailing-stop distance in ATR
    use_trailing: bool = True
    max_daily_loss: float = 0.05          # halt new trades after -5% on the day
    max_drawdown: float = 0.20            # halt entirely after -20% from peak
    max_open_positions: int = 1
    max_spread_points: float = 50.0       # reject trades when spread is wider
    min_confidence: float = 0.20          # ignore weak ensemble signals
    contract_size: float = 100.0          # XAUUSD: 1.00 lot = 100 oz ($1 move = $100)
    point: float = 0.01                   # smallest price increment for XAUUSD
    volume_step: float = 0.01
    min_volume: float = 0.01
    max_volume: float = 50.0
    # Allowed UTC trading windows (London + NY liquidity). Empty = 24h.
    sessions: List[Tuple[int, int]] = field(default_factory=lambda: [(7, 21)])


@dataclass
class RiskDecision:
    ok: bool
    reason: str = ""


class RiskManager:
    def __init__(self, params: RiskParams, starting_equity: float):
        self.p = params
        self.start_equity = starting_equity
        self.peak_equity = starting_equity
        self.daily_anchor = starting_equity
        self._day = None
        self.halted = False

    # --- equity / drawdown bookkeeping -----------------------------------
    def observe(self, now: datetime, equity: float) -> None:
        """Call once per bar to keep drawdown / daily anchors current."""
        day = now.date()
        if self._day != day:
            self._day = day
            self.daily_anchor = equity
        self.peak_equity = max(self.peak_equity, equity)
        if self.drawdown_pct(equity) >= self.p.max_drawdown:
            self.halted = True

    def drawdown_pct(self, equity: float) -> float:
        if self.peak_equity <= 0:
            return 0.0
        return max(0.0, (self.peak_equity - equity) / self.peak_equity)

    def daily_loss_pct(self, equity: float) -> float:
        if self.daily_anchor <= 0:
            return 0.0
        return max(0.0, (self.daily_anchor - equity) / self.daily_anchor)

    # --- gates ------------------------------------------------------------
    def in_session(self, now: datetime) -> bool:
        if not self.p.sessions:
            return True
        h = now.hour
        return any(start <= h < end for start, end in self.p.sessions)

    def can_open(
        self,
        now: datetime,
        equity: float,
        spread_points: float,
        open_positions: int,
        confidence: float,
    ) -> RiskDecision:
        if self.halted:
            return RiskDecision(False, "HALTED: max drawdown breached")
        if self.drawdown_pct(equity) >= self.p.max_drawdown:
            self.halted = True
            return RiskDecision(False, "HALTED: max drawdown breached")
        if self.daily_loss_pct(equity) >= self.p.max_daily_loss:
            return RiskDecision(False, f"Daily loss limit hit ({self.p.max_daily_loss:.0%})")
        if open_positions >= self.p.max_open_positions:
            return RiskDecision(False, "Max open positions reached")
        if confidence < self.p.min_confidence:
            return RiskDecision(False, f"Confidence {confidence:.2f} below {self.p.min_confidence:.2f}")
        if spread_points > self.p.max_spread_points:
            return RiskDecision(False, f"Spread {spread_points:.0f} pts too wide")
        if not self.in_session(now):
            return RiskDecision(False, f"Outside trading session (hour {now.hour} UTC)")
        return RiskDecision(True, "OK")

    # --- sizing & brackets ------------------------------------------------
    def position_size(self, equity: float, atr: float) -> float:
        """Fixed-fractional sizing: risk exactly ``risk_per_trade`` of equity
        if price travels from entry to the ATR-based stop."""
        if atr <= 0 or equity <= 0:
            return 0.0
        stop_distance = atr * self.p.sl_atr_mult           # price units
        risk_cash = equity * self.p.risk_per_trade
        loss_per_lot = stop_distance * self.p.contract_size
        if loss_per_lot <= 0:
            return 0.0
        lots = risk_cash / loss_per_lot
        # round down to the volume step, then clamp
        lots = math.floor(lots / self.p.volume_step) * self.p.volume_step
        lots = max(self.p.min_volume, min(lots, self.p.max_volume))
        return round(lots, 2)

    def bracket(self, direction: int, entry: float, atr: float) -> Tuple[float, float]:
        """Return (stop_loss, take_profit) prices for a new position."""
        sl_dist = atr * self.p.sl_atr_mult
        tp_dist = atr * self.p.tp_atr_mult
        if direction > 0:
            return entry - sl_dist, entry + tp_dist
        return entry + sl_dist, entry - tp_dist

    def update_trailing(self, direction: int, price: float, atr: float, current_sl: float) -> float:
        """Ratchet the stop in the trade's favour; never loosen it."""
        if not self.p.use_trailing or atr <= 0:
            return current_sl
        dist = atr * self.p.trail_atr_mult
        if direction > 0:
            return max(current_sl, price - dist)
        return min(current_sl, price + dist)

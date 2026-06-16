"""Live trading engine.

Broker-agnostic loop: on every newly *closed* bar it refreshes equity, trails
open stops, then asks the ensemble for a signal and (subject to the risk
manager) opens a position. Works against the paper broker or the live MT5
broker without changes.

Safety features:
  * ``dry_run`` logs intended orders without sending them.
  * the RiskManager gates every entry (drawdown, daily loss, session, spread...).
  * a clean shutdown closes nothing automatically - your stops stay on the broker.
"""
from __future__ import annotations

import logging
import time
from datetime import datetime
from typing import Optional

import numpy as np

from . import indicators as ind
from .brokers.base import Broker
from .risk import RiskManager, RiskParams
from .strategies import Strategy, build_default_ensemble

log = logging.getLogger("xauusd-bot")


class TradingEngine:
    def __init__(
        self,
        broker: Broker,
        strategy: Optional[Strategy] = None,
        risk_params: Optional[RiskParams] = None,
        history_bars: int = 400,
        poll_seconds: float = 5.0,
        dry_run: bool = False,
    ):
        self.broker = broker
        self.strategy = strategy or build_default_ensemble()
        self.risk_params = risk_params or RiskParams()
        self.rm = RiskManager(self.risk_params, broker.equity())
        self.history_bars = history_bars
        self.poll_seconds = poll_seconds
        self.dry_run = dry_run
        self._last_bar_time = None
        self._running = False

    def stop(self) -> None:
        self._running = False

    def run(self) -> None:
        self._running = True
        mode = "DRY-RUN (no orders sent)" if self.dry_run else "LIVE ORDERS"
        log.info("Engine started on %s | %s | strategy=%s",
                 self.broker.symbol, mode, self.strategy.name)
        while self._running:
            try:
                self._tick()
            except Exception:  # keep the loop alive; never crash on a transient error
                log.exception("Error in engine tick; continuing")
            time.sleep(self.poll_seconds)

    # ---------------------------------------------------------------------
    def _tick(self) -> None:
        df = self.broker.candles(self.history_bars)
        if df is None or len(df) < self.strategy.min_bars:
            return

        last_time = df.index[-1]
        if last_time == self._last_bar_time:
            return  # no new completed bar yet
        self._last_bar_time = last_time

        now = datetime.utcnow()
        equity = self.broker.equity()
        self.rm.observe(now, equity)

        atr_series = ind.atr(df["high"], df["low"], df["close"])
        atr_now = float(atr_series.iloc[-1]) if not np.isnan(atr_series.iloc[-1]) else 0.0
        price = float(df["close"].iloc[-1])

        self._manage_open_positions(price, atr_now)

        if atr_now <= 0:
            return

        positions = self.broker.positions()
        tick = self.broker.last_tick()
        gate = self.rm.can_open(now, equity, tick.spread_points, len(positions), confidence=1.0)
        if not gate.ok:
            log.info("[%s] No entry: %s | equity=%.2f", last_time, gate.reason, equity)
            return

        sig = self.strategy.generate(df)
        log.info("[%s] Signal dir=%+d conf=%.2f | %s", last_time, sig.direction, sig.confidence, sig.reason)
        if not sig.is_actionable or sig.confidence < self.risk_params.min_confidence:
            return

        volume = self.rm.position_size(equity, atr_now)
        if volume <= 0:
            log.warning("Computed volume is zero; skipping")
            return

        entry = tick.ask if sig.direction > 0 else tick.bid
        sl, tp = self.rm.bracket(sig.direction, entry, atr_now)
        side = "BUY" if sig.direction > 0 else "SELL"

        if self.dry_run:
            log.info("[DRY-RUN] Would %s %.2f lots @ %.2f  SL=%.2f TP=%.2f", side, volume, entry, sl, tp)
            return

        result = self.broker.open(sig.direction, volume, sl, tp, comment=self.strategy.name)
        if result.ok:
            log.info("OPENED %s %.2f lots @ %.2f  SL=%.2f TP=%.2f", side, volume, entry, sl, tp)
        else:
            log.error("Order rejected: %s", result.message)

    def _manage_open_positions(self, price: float, atr_now: float) -> None:
        for pos in self.broker.positions():
            new_sl = self.rm.update_trailing(pos.direction, price, atr_now, pos.sl)
            if abs(new_sl - pos.sl) > self.broker.point:
                if self.dry_run:
                    log.info("[DRY-RUN] Would trail SL of #%s -> %.2f", pos.ticket, new_sl)
                elif self.broker.modify(pos.ticket, new_sl, pos.tp):
                    log.info("Trailed SL of #%s -> %.2f", pos.ticket, new_sl)

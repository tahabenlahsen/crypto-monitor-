"""Event-driven backtester.

Walks the data one bar at a time, decides on the *close* of each completed bar,
fills at that close (plus spread), and only ever resolves stops/targets on
*later* bars - so there is no look-ahead bias. The same RiskManager and
Ensemble used live are used here, so a backtest exercises the real decision
path."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

import numpy as np
import pandas as pd

from . import indicators as ind
from .brokers.paper import PaperBroker
from .risk import RiskManager, RiskParams
from .strategies import Strategy, build_default_ensemble


@dataclass
class BacktestResult:
    starting_equity: float
    final_equity: float
    trades: List[dict] = field(default_factory=list)
    equity_curve: List[tuple] = field(default_factory=list)

    @property
    def total_return_pct(self) -> float:
        return (self.final_equity / self.starting_equity - 1.0) * 100.0

    @property
    def num_trades(self) -> int:
        return len(self.trades)

    @property
    def wins(self) -> List[dict]:
        return [t for t in self.trades if t["pnl"] > 0]

    @property
    def losses(self) -> List[dict]:
        return [t for t in self.trades if t["pnl"] <= 0]

    @property
    def win_rate(self) -> float:
        return 100.0 * len(self.wins) / self.num_trades if self.num_trades else 0.0

    @property
    def profit_factor(self) -> float:
        gross_win = sum(t["pnl"] for t in self.wins)
        gross_loss = -sum(t["pnl"] for t in self.losses)
        return gross_win / gross_loss if gross_loss > 0 else float("inf")

    @property
    def max_drawdown_pct(self) -> float:
        if not self.equity_curve:
            return 0.0
        eq = np.array([e for _, e in self.equity_curve], dtype=float)
        peak = np.maximum.accumulate(eq)
        dd = (peak - eq) / peak
        return float(np.max(dd) * 100.0)

    @property
    def sharpe(self) -> float:
        if len(self.equity_curve) < 3:
            return 0.0
        eq = pd.Series([e for _, e in self.equity_curve])
        rets = eq.pct_change().dropna()
        if rets.std(ddof=0) == 0:
            return 0.0
        # Annualised assuming ~96 fifteen-minute bars per day, 252 trading days.
        return float(rets.mean() / rets.std(ddof=0) * np.sqrt(96 * 252))

    def report(self) -> str:
        return (
            "\n===================  BACKTEST REPORT  ===================\n"
            f"  Starting equity : {self.starting_equity:>12,.2f}\n"
            f"  Final equity    : {self.final_equity:>12,.2f}\n"
            f"  Total return    : {self.total_return_pct:>11.2f}%\n"
            f"  Trades          : {self.num_trades:>12d}\n"
            f"  Win rate        : {self.win_rate:>11.2f}%\n"
            f"  Profit factor   : {self.profit_factor:>12.2f}\n"
            f"  Max drawdown    : {self.max_drawdown_pct:>11.2f}%\n"
            f"  Sharpe (annual) : {self.sharpe:>12.2f}\n"
            "=========================================================\n"
            "  Reminder: synthetic/backtest results do NOT guarantee\n"
            "  live performance. Always forward-test on a demo account.\n"
            "========================================================="
        )


class Backtester:
    def __init__(
        self,
        strategy: Optional[Strategy] = None,
        risk: Optional[RiskParams] = None,
        starting_balance: float = 10_000.0,
        spread_points: float = 20.0,
        commission_per_lot: float = 0.0,
    ):
        self.strategy = strategy or build_default_ensemble()
        self.risk_params = risk or RiskParams()
        self.starting_balance = starting_balance
        self.spread_points = spread_points
        self.commission_per_lot = commission_per_lot

    def run(self, df: pd.DataFrame) -> BacktestResult:
        broker = PaperBroker(
            starting_balance=self.starting_balance,
            spread_points=self.spread_points,
            commission_per_lot=self.commission_per_lot,
        )
        rm = RiskManager(self.risk_params, self.starting_balance)
        warmup = max(self.strategy.min_bars, 120)

        atr_series = ind.atr(df["high"], df["low"], df["close"])

        for i in range(len(df)):
            ts = df.index[i]
            bar = df.iloc[i]
            history = df.iloc[: i + 1]

            broker.set_bar(ts, bar, history)
            equity = broker.equity()
            rm.observe(ts.to_pydatetime(), equity)

            atr_now = float(atr_series.iloc[i]) if not np.isnan(atr_series.iloc[i]) else 0.0

            # Manage open positions: trail the stop.
            for pos in broker.positions():
                new_sl = rm.update_trailing(pos.direction, float(bar["close"]), atr_now, pos.sl)
                if new_sl != pos.sl:
                    broker.modify(pos.ticket, new_sl, pos.tp)

            if i < warmup or atr_now <= 0:
                continue

            # Only look for new entries when flat (max_open_positions handles the rest).
            decision = rm.can_open(
                ts.to_pydatetime(), equity,
                spread_points=self.spread_points,
                open_positions=len(broker.positions()),
                confidence=1.0,  # provisional; real confidence checked below
            )
            if not decision.ok:
                continue

            sig = self.strategy.generate(history)
            if not sig.is_actionable or sig.confidence < self.risk_params.min_confidence:
                continue

            volume = rm.position_size(equity, atr_now)
            if volume <= 0:
                continue
            entry = float(broker.last_tick().ask if sig.direction > 0 else broker.last_tick().bid)
            sl, tp = rm.bracket(sig.direction, entry, atr_now)
            broker.open(sig.direction, volume, sl, tp, comment=self.strategy.name)

        return BacktestResult(
            starting_equity=self.starting_balance,
            final_equity=broker.equity(),
            trades=broker.closed_trades,
            equity_curve=broker.equity_curve,
        )

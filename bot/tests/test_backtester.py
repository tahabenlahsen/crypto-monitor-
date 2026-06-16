"""End-to-end backtester & paper-broker tests."""
from datetime import datetime

import pandas as pd
import pytest

from src.backtester import Backtester
from src.brokers.paper import PaperBroker
from src.data import synthetic_ohlcv
from src.risk import RiskParams


def test_backtest_runs_end_to_end():
    df = synthetic_ohlcv(n=2000, seed=1)
    bt = Backtester(risk=RiskParams(sessions=[]))
    res = bt.run(df)
    assert res.num_trades >= 0
    assert len(res.equity_curve) == len(df)
    assert res.final_equity > 0
    # report should render without error
    assert "BACKTEST REPORT" in res.report()


def test_drawdown_never_wildly_exceeds_limit():
    # The halt is checked per-bar, so realised drawdown should stay close to the cap.
    df = synthetic_ohlcv(n=4000, seed=7)
    bt = Backtester(risk=RiskParams(max_drawdown=0.15, sessions=[]))
    res = bt.run(df)
    assert res.max_drawdown_pct <= 30.0  # generous headroom for intrabar gaps


def test_paper_broker_long_profit_and_loss():
    pb = PaperBroker(starting_balance=10_000.0, spread_points=0.0)
    # bar 1
    bar = pd.Series({"open": 2000.0, "high": 2000.0, "low": 2000.0, "close": 2000.0})
    pb.set_bar(datetime(2024, 1, 1, 0), bar)
    res = pb.open(direction=1, volume=1.0, sl=1990.0, tp=2010.0)
    assert res.ok
    # price rises to hit TP at 2010 -> +$1000 (1 lot * $10 * 100 contract)
    up = pd.Series({"open": 2005.0, "high": 2012.0, "low": 2004.0, "close": 2011.0})
    pb.set_bar(datetime(2024, 1, 1, 1), up)
    assert len(pb.positions()) == 0
    assert pb.balance() == pytest.approx(11_000.0, abs=1.0)


def test_paper_broker_stop_loss_hit():
    pb = PaperBroker(starting_balance=10_000.0, spread_points=0.0)
    bar = pd.Series({"open": 2000.0, "high": 2000.0, "low": 2000.0, "close": 2000.0})
    pb.set_bar(datetime(2024, 1, 1, 0), bar)
    pb.open(direction=1, volume=1.0, sl=1995.0, tp=2050.0)
    down = pd.Series({"open": 1999.0, "high": 2000.0, "low": 1994.0, "close": 1996.0})
    pb.set_bar(datetime(2024, 1, 1, 1), down)
    assert len(pb.positions()) == 0
    # loss = (1995-2000)*1*100 = -$500
    assert pb.balance() == pytest.approx(9_500.0, abs=1.0)


def test_paper_broker_equity_reflects_floating_pnl():
    pb = PaperBroker(starting_balance=10_000.0, spread_points=0.0)
    bar = pd.Series({"open": 2000.0, "high": 2000.0, "low": 2000.0, "close": 2000.0})
    pb.set_bar(datetime(2024, 1, 1, 0), bar)
    pb.open(direction=1, volume=1.0, sl=1900.0, tp=2100.0)
    move = pd.Series({"open": 2000.0, "high": 2005.0, "low": 1999.0, "close": 2003.0})
    pb.set_bar(datetime(2024, 1, 1, 1), move)
    # floating profit = (2003-2000)*100 = +$300
    assert pb.equity() == pytest.approx(10_300.0, abs=1.0)

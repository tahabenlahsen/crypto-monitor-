"""Risk manager tests - the safety system must be provably correct."""
from datetime import datetime

import pytest

from src.risk import RiskManager, RiskParams


def make_rm(**kw):
    return RiskManager(RiskParams(**kw), starting_equity=10_000.0)


def test_position_size_risks_expected_amount():
    # risk 1% of 10,000 = $100. Stop = ATR(2.0) * sl_mult(2.0) = 4.0 price units.
    # loss per lot = 4.0 * 100 (contract) = $400. lots = 100/400 = 0.25.
    rm = make_rm(risk_per_trade=0.01, sl_atr_mult=2.0)
    lots = rm.position_size(equity=10_000.0, atr=2.0)
    assert lots == pytest.approx(0.25, abs=0.01)


def test_position_size_zero_when_no_atr():
    rm = make_rm()
    assert rm.position_size(10_000.0, atr=0.0) == 0.0


def test_position_size_respects_min_max():
    rm = make_rm(risk_per_trade=0.01, max_volume=0.1)
    assert rm.position_size(10_000.0, atr=0.01) <= 0.1
    rm2 = make_rm(risk_per_trade=0.0000001, min_volume=0.01)
    assert rm2.position_size(10_000.0, atr=5.0) >= 0.01


def test_bracket_long_and_short():
    rm = make_rm(sl_atr_mult=2.0, tp_atr_mult=3.0)
    sl, tp = rm.bracket(1, entry=2000.0, atr=2.0)
    assert sl == pytest.approx(1996.0) and tp == pytest.approx(2006.0)
    sl, tp = rm.bracket(-1, entry=2000.0, atr=2.0)
    assert sl == pytest.approx(2004.0) and tp == pytest.approx(1994.0)


def test_daily_loss_blocks_new_trades():
    rm = make_rm(max_daily_loss=0.05)
    now = datetime(2024, 1, 1, 10)
    rm.observe(now, 10_000.0)
    # drop 6% on the day
    d = rm.can_open(now, equity=9_400.0, spread_points=10, open_positions=0, confidence=1.0)
    assert not d.ok and "Daily loss" in d.reason


def test_drawdown_halts_permanently():
    rm = make_rm(max_drawdown=0.20)
    now = datetime(2024, 1, 1, 10)
    rm.observe(now, 12_000.0)          # peak
    rm.observe(now, 9_000.0)           # -25% from peak -> halt
    assert rm.halted
    d = rm.can_open(now, 9_000.0, spread_points=10, open_positions=0, confidence=1.0)
    assert not d.ok and "HALTED" in d.reason


def test_session_filter():
    rm = make_rm(sessions=[(7, 21)])
    inside = datetime(2024, 1, 1, 10)
    outside = datetime(2024, 1, 1, 23)
    assert rm.in_session(inside)
    assert not rm.in_session(outside)
    d = rm.can_open(outside, 10_000.0, spread_points=10, open_positions=0, confidence=1.0)
    assert not d.ok and "session" in d.reason.lower()


def test_spread_and_confidence_gates():
    rm = make_rm(max_spread_points=50, min_confidence=0.3, sessions=[])
    now = datetime(2024, 1, 1, 10)
    assert not rm.can_open(now, 10_000.0, spread_points=80, open_positions=0, confidence=1.0).ok
    assert not rm.can_open(now, 10_000.0, spread_points=10, open_positions=0, confidence=0.1).ok
    assert rm.can_open(now, 10_000.0, spread_points=10, open_positions=0, confidence=0.9).ok


def test_max_open_positions():
    rm = make_rm(max_open_positions=1, sessions=[])
    now = datetime(2024, 1, 1, 10)
    assert not rm.can_open(now, 10_000.0, spread_points=10, open_positions=1, confidence=1.0).ok


def test_trailing_only_ratchets():
    rm = make_rm(trail_atr_mult=2.0, use_trailing=True)
    # long: new SL can only move up
    assert rm.update_trailing(1, price=2010.0, atr=2.0, current_sl=2000.0) == pytest.approx(2006.0)
    assert rm.update_trailing(1, price=2001.0, atr=2.0, current_sl=2005.0) == 2005.0  # never loosens
    # short: SL can only move down
    assert rm.update_trailing(-1, price=1990.0, atr=2.0, current_sl=2000.0) == pytest.approx(1994.0)

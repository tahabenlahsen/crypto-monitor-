"""Strategy & ensemble behaviour tests."""
import numpy as np
import pandas as pd
import pytest

from src.strategies import (
    FLAT,
    LONG,
    SHORT,
    BreakoutStrategy,
    IchimokuStrategy,
    MeanReversionStrategy,
    MomentumStrategy,
    Signal,
    TrendFollowingStrategy,
    VwapFlowStrategy,
    build_default_ensemble,
)

ALL_STRATS = [
    TrendFollowingStrategy, MeanReversionStrategy, BreakoutStrategy,
    MomentumStrategy, IchimokuStrategy, VwapFlowStrategy,
]


def make_df(trend=0.0, n=400, noise=0.4, seed=1):
    rng = np.random.default_rng(seed)
    close = pd.Series(1950 + np.cumsum(np.full(n, trend) + rng.standard_normal(n) * noise))
    high = close + np.abs(rng.standard_normal(n)) * 0.5
    low = close - np.abs(rng.standard_normal(n)) * 0.5
    op = close.shift(1).fillna(close.iloc[0])
    vol = pd.Series(1000 + np.arange(n) + rng.integers(0, 200, n))
    return pd.DataFrame({"open": op, "high": high, "low": low, "close": close, "volume": vol})


def test_signal_normalisation():
    s = Signal(direction=5, confidence=2.0)
    assert s.direction == 1 and s.confidence == 1.0
    flat = Signal(direction=0, confidence=0.9)
    assert flat.confidence == 0.0 and not flat.is_actionable


@pytest.mark.parametrize("cls", ALL_STRATS)
def test_strategy_returns_valid_signal(cls):
    sig = cls().generate(make_df(trend=0.5))
    assert isinstance(sig, Signal)
    assert sig.direction in (LONG, SHORT, FLAT)
    assert 0.0 <= sig.confidence <= 1.0


@pytest.mark.parametrize("cls", ALL_STRATS)
def test_strategy_flat_on_insufficient_data(cls):
    tiny = make_df(n=20)
    sig = cls().generate(tiny)
    assert sig.direction == FLAT


def test_ensemble_long_on_strong_uptrend():
    ens = build_default_ensemble()
    sig = ens.generate(make_df(trend=0.8, noise=0.3))
    assert sig.direction == LONG
    assert sig.confidence > 0


def test_ensemble_short_on_strong_downtrend():
    ens = build_default_ensemble()
    sig = ens.generate(make_df(trend=-0.8, noise=0.3))
    assert sig.direction == SHORT


def test_ensemble_requires_min_agreement():
    # With an impossibly high agreement requirement, it can never trade.
    ens = build_default_ensemble({"min_agree": 99})
    sig = ens.generate(make_df(trend=0.8))
    assert sig.direction == FLAT


def test_ensemble_contributors_recorded():
    ens = build_default_ensemble()
    sig = ens.generate(make_df(trend=0.8, noise=0.3))
    assert isinstance(sig.contributors, dict)
    for name, info in sig.contributors.items():
        assert set(info) >= {"dir", "conf", "reason"}

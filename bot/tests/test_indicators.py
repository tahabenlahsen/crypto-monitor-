"""Indicator correctness & sanity tests."""
import numpy as np
import pandas as pd
import pytest

from src import indicators as ind


@pytest.fixture
def ohlcv():
    rng = np.random.default_rng(0)
    n = 400
    close = pd.Series(2000 + np.cumsum(rng.standard_normal(n) * 2))
    high = close + np.abs(rng.standard_normal(n))
    low = close - np.abs(rng.standard_normal(n))
    vol = pd.Series(rng.integers(100, 1000, n).astype(float))
    return high, low, close, vol


def test_sma_known_values():
    s = pd.Series([1, 2, 3, 4, 5], dtype=float)
    out = ind.sma(s, 3)
    assert out.iloc[2] == pytest.approx(2.0)
    assert out.iloc[4] == pytest.approx(4.0)
    assert np.isnan(out.iloc[0])


def test_ema_converges_to_constant():
    s = pd.Series([5.0] * 50)
    assert ind.ema(s, 10).iloc[-1] == pytest.approx(5.0)


def test_rsi_bounds(ohlcv):
    _, _, close, _ = ohlcv
    r = ind.rsi(close, 14).dropna()
    assert r.between(0, 100).all()


def test_rsi_all_up_is_high():
    close = pd.Series(np.arange(1, 60, dtype=float))  # strictly increasing
    assert ind.rsi(close, 14).iloc[-1] > 99


def test_atr_positive(ohlcv):
    high, low, close, _ = ohlcv
    a = ind.atr(high, low, close).dropna()
    assert (a > 0).all()


def test_williams_r_range(ohlcv):
    high, low, close, _ = ohlcv
    wr = ind.williams_r(high, low, close).dropna()
    assert wr.between(-100, 0).all()


def test_stochastic_range(ohlcv):
    high, low, close, _ = ohlcv
    k = ind.stochastic(high, low, close)["k"].dropna()
    assert k.between(0, 100).all()


def test_supertrend_direction_values(ohlcv):
    high, low, close, _ = ohlcv
    d = ind.supertrend(high, low, close)["direction"].dropna().unique()
    assert set(d).issubset({-1.0, 1.0})


def test_bollinger_ordering(ohlcv):
    _, _, close, _ = ohlcv
    bb = ind.bollinger(close).dropna()
    assert (bb["upper"] >= bb["mid"]).all()
    assert (bb["mid"] >= bb["lower"]).all()


def test_macd_hist_is_difference(ohlcv):
    _, _, close, _ = ohlcv
    m = ind.macd(close).dropna()
    assert np.allclose((m["macd"] - m["signal"]).to_numpy(), m["hist"].to_numpy())


def test_indicators_produce_values(ohlcv):
    """Every indicator must return at least some finite values (no all-NaN)."""
    high, low, close, vol = ohlcv
    calls = {
        "ichimoku": lambda: ind.ichimoku(high, low, close),
        "aroon": lambda: ind.aroon(high, low),
        "parabolic_sar": lambda: ind.parabolic_sar(high, low),
        "fisher_transform": lambda: ind.fisher_transform(high, low),
        "cci": lambda: ind.cci(high, low, close),
        "mfi": lambda: ind.mfi(high, low, close, vol),
        "tsi": lambda: ind.tsi(close),
        "keltner": lambda: ind.keltner(high, low, close),
        "donchian": lambda: ind.donchian(high, low),
        "vwap": lambda: ind.vwap(high, low, close, vol),
        "cmf": lambda: ind.cmf(high, low, close, vol),
        "obv": lambda: ind.obv(close, vol),
        "hma": lambda: ind.hma(close, 16),
        "squeeze": lambda: ind.squeeze(high, low, close),
    }
    for name, fn in calls.items():
        out = fn()
        remaining = out.dropna(how="all") if hasattr(out, "dropna") else out
        assert len(remaining) > 0, f"{name} produced all-NaN"

"""Data feed helpers: load OHLCV from CSV, or generate realistic synthetic gold
data so the bot can be backtested with zero external dependencies."""
from __future__ import annotations

from datetime import datetime, timedelta

import numpy as np
import pandas as pd

_REQUIRED = ["open", "high", "low", "close", "volume"]


def load_csv(path: str) -> pd.DataFrame:
    """Load an OHLCV CSV. Tolerant of common column names / casing."""
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    rename = {
        "date": "time", "datetime": "time", "timestamp": "time",
        "vol": "volume", "tick_volume": "volume", "tickvol": "volume",
    }
    df = df.rename(columns=rename)
    if "time" in df.columns:
        df["time"] = pd.to_datetime(df["time"])
        df = df.set_index("time").sort_index()
    if "volume" not in df.columns:
        df["volume"] = 1.0
    missing = [c for c in _REQUIRED if c not in df.columns]
    if missing:
        raise ValueError(f"CSV missing required columns: {missing}")
    return df[_REQUIRED].astype(float)


def synthetic_ohlcv(
    n: int = 5000,
    start_price: float = 1950.0,
    timeframe_minutes: int = 15,
    seed: int = 42,
) -> pd.DataFrame:
    """Generate believable XAUUSD-like bars with alternating trend/range regimes.

    This is for development and testing only - synthetic results say nothing
    about live performance. Always validate on real broker data.
    """
    rng = np.random.default_rng(seed)
    prices = np.empty(n)
    prices[0] = start_price

    # Build a sequence of regimes (trend up / trend down / range).
    drift = 0.0
    vol = 0.6
    regime_left = 0
    for i in range(1, n):
        if regime_left <= 0:
            regime_left = rng.integers(120, 480)
            kind = rng.choice(["up", "down", "range"], p=[0.35, 0.30, 0.35])
            drift = {"up": 0.05, "down": -0.05, "range": 0.0}[kind]
            vol = rng.uniform(0.4, 1.1)
        regime_left -= 1
        shock = rng.normal(drift, vol)
        prices[i] = max(1.0, prices[i - 1] + shock)

    close = pd.Series(prices)
    spread = np.abs(rng.normal(0, vol, n)) + 0.2
    high = close + spread * rng.uniform(0.2, 1.0, n)
    low = close - spread * rng.uniform(0.2, 1.0, n)
    open_ = close.shift(1).fillna(close.iloc[0])
    high = np.maximum.reduce([high.to_numpy(), open_.to_numpy(), close.to_numpy()])
    low = np.minimum.reduce([low.to_numpy(), open_.to_numpy(), close.to_numpy()])
    volume = rng.integers(200, 2000, n).astype(float)

    start = datetime(2023, 1, 2, 0, 0)
    index = [start + timedelta(minutes=timeframe_minutes * i) for i in range(n)]
    return pd.DataFrame(
        {"open": open_.to_numpy(), "high": high, "low": low, "close": close.to_numpy(), "volume": volume},
        index=pd.DatetimeIndex(index, name="time"),
    )

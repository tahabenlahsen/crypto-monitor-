#!/usr/bin/env python3
"""Backtest entry point (runs anywhere - no broker needed).

    python backtest.py                          # synthetic gold data
    python backtest.py --csv data/XAUUSD_M15.csv  # your own OHLCV export
    python backtest.py --bars 10000 --balance 5000 --risk 0.005
"""
from __future__ import annotations

import argparse

from src.backtester import Backtester
from src.config import load_config
from src.data import load_csv, synthetic_ohlcv


def main() -> int:
    parser = argparse.ArgumentParser(description="Backtest the XAUUSD bot")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--csv", default=None, help="path to an OHLCV CSV; omit to use synthetic data")
    parser.add_argument("--bars", type=int, default=6000, help="synthetic bars to generate")
    parser.add_argument("--balance", type=float, default=None)
    parser.add_argument("--risk", type=float, default=None, help="override risk-per-trade fraction")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    cfg = load_config(args.config)
    if args.balance is not None:
        cfg.starting_balance = args.balance
    if args.risk is not None:
        cfg.risk.risk_per_trade = args.risk

    if args.csv:
        df = load_csv(args.csv)
        print(f"Loaded {len(df):,} bars from {args.csv}")
    else:
        df = synthetic_ohlcv(n=args.bars, seed=args.seed)
        print(f"Generated {len(df):,} synthetic bars (seed={args.seed}).")
        print("NOTE: synthetic data has no real edge - use --csv with real broker data for meaningful results.")

    bt = Backtester(
        strategy=cfg.build_strategy(),
        risk=cfg.risk,
        starting_balance=cfg.starting_balance,
        spread_points=cfg.spread_points,
        commission_per_lot=cfg.commission_per_lot,
    )
    result = bt.run(df)
    print(result.report())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Live / demo trading entry point (MetaTrader 5).

    python run.py --config config.yaml            # trade per config
    python run.py --config config.yaml --dry-run  # connect + log signals, send NO orders

SAFETY: start with a DEMO account and --dry-run. Read the README first.
"""
from __future__ import annotations

import argparse
import logging
import signal
import sys

from src.config import load_config, mt5_credentials
from src.engine import TradingEngine


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler("bot.log")],
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="XAUUSD multi-strategy trading bot")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--dry-run", action="store_true", help="compute and log signals but never send orders")
    args = parser.parse_args()

    setup_logging()
    log = logging.getLogger("xauusd-bot")
    cfg = load_config(args.config)
    dry_run = args.dry_run or cfg.dry_run

    if cfg.mode != "mt5":
        log.error(
            "run.py performs LIVE/DEMO trading via MetaTrader 5 and needs mode: mt5 "
            "in your config (MT5 supplies the live data). For risk-free simulation on "
            "historical data, use:  python backtest.py"
        )
        return 2

    from src.brokers import get_mt5_broker

    creds = mt5_credentials()
    log.info("Connecting to MetaTrader 5 (server=%s, login=%s)...", creds.get("server"), creds.get("login"))
    try:
        broker = get_mt5_broker(
            symbol=cfg.symbol,
            timeframe=cfg.timeframe,
            login=creds["login"],
            password=creds["password"],
            server=creds["server"],
            terminal_path=cfg.terminal_path,
        )
    except RuntimeError as exc:
        log.error("Could not connect to MetaTrader 5: %s", exc)
        log.error("Check that: (1) you are on Windows with the MT5 terminal installed and "
                  "running, (2) `pip install MetaTrader5` succeeded, (3) your .env "
                  "MT5_LOGIN/MT5_PASSWORD/MT5_SERVER are correct.")
        return 1
    log.info("Connected. Balance=%.2f Equity=%.2f", broker.balance(), broker.equity())

    engine = TradingEngine(
        broker=broker,
        strategy=cfg.build_strategy(),
        risk_params=cfg.risk,
        history_bars=cfg.history_bars,
        poll_seconds=cfg.poll_seconds,
        dry_run=dry_run,
    )

    def handle_sigint(signum, frame):
        log.info("Shutdown requested. Stopping engine (open positions keep their broker-side SL/TP).")
        engine.stop()

    signal.signal(signal.SIGINT, handle_sigint)
    signal.signal(signal.SIGTERM, handle_sigint)

    engine.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

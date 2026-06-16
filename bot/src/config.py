"""Configuration loading.

Non-secret settings live in a YAML file; secrets (MT5 login/password/server)
come from environment variables / a .env file that is never committed."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

import yaml

from .risk import RiskParams
from .strategies import build_default_ensemble


@dataclass
class AppConfig:
    mode: str = "paper"            # "paper" | "mt5"
    symbol: str = "XAUUSD"
    timeframe: str = "M15"
    starting_balance: float = 10_000.0
    spread_points: float = 20.0
    commission_per_lot: float = 0.0
    poll_seconds: float = 5.0
    history_bars: int = 400
    dry_run: bool = False
    terminal_path: Optional[str] = None
    risk: RiskParams = None
    strategy_cfg: dict = None

    def build_strategy(self):
        return build_default_ensemble(self.strategy_cfg or {})


def _load_env() -> None:
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except ImportError:
        pass


def load_config(path: str = "config.yaml") -> AppConfig:
    _load_env()
    data = {}
    if os.path.exists(path):
        with open(path, "r") as fh:
            data = yaml.safe_load(fh) or {}

    risk_data = data.get("risk", {}) or {}
    sessions = risk_data.get("sessions")
    if sessions is not None:
        sessions = [tuple(s) for s in sessions]
    risk = RiskParams(
        **{k: v for k, v in risk_data.items() if k != "sessions"},
        **({"sessions": sessions} if sessions is not None else {}),
    )

    strat = data.get("strategy", {}) or {}
    weights = strat.get("weights", {}) or {}
    weights = {
        **weights,
        "threshold": strat.get("threshold", 0.25),
        "min_agree": strat.get("min_agree", 2),
    }

    return AppConfig(
        mode=data.get("mode", "paper"),
        symbol=data.get("symbol", "XAUUSD"),
        timeframe=data.get("timeframe", "M15"),
        starting_balance=float(data.get("starting_balance", 10_000.0)),
        spread_points=float(data.get("spread_points", 20.0)),
        commission_per_lot=float(data.get("commission_per_lot", 0.0)),
        poll_seconds=float(data.get("poll_seconds", 5.0)),
        history_bars=int(data.get("history_bars", 400)),
        dry_run=bool(data.get("dry_run", False)),
        terminal_path=(data.get("mt5", {}) or {}).get("terminal_path") or None,
        risk=risk,
        strategy_cfg=weights,
    )


def mt5_credentials() -> dict:
    """Read MT5 secrets from the environment."""
    login = os.getenv("MT5_LOGIN")
    return {
        "login": int(login) if login else None,
        "password": os.getenv("MT5_PASSWORD"),
        "server": os.getenv("MT5_SERVER"),
    }

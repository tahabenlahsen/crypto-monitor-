"""Strategy package: six independent strategies plus the ensemble that fuses
them into a single, robust trading decision."""
from .base import FLAT, LONG, SHORT, Signal, Strategy
from .breakout import BreakoutStrategy
from .ensemble import Ensemble, build_default_ensemble
from .ichimoku_strategy import IchimokuStrategy
from .mean_reversion import MeanReversionStrategy
from .momentum import MomentumStrategy
from .trend_following import TrendFollowingStrategy
from .vwap_flow import VwapFlowStrategy

__all__ = [
    "Signal", "Strategy", "LONG", "SHORT", "FLAT",
    "TrendFollowingStrategy", "MeanReversionStrategy", "BreakoutStrategy",
    "MomentumStrategy", "IchimokuStrategy", "VwapFlowStrategy",
    "Ensemble", "build_default_ensemble",
]

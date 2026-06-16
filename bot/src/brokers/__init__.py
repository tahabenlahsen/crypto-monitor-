"""Broker package: shared interface, paper simulator, and MT5 live adapter."""
from .base import Broker, OrderResult, Position, Tick
from .paper import PaperBroker

__all__ = ["Broker", "Tick", "Position", "OrderResult", "PaperBroker", "get_mt5_broker"]


def get_mt5_broker(*args, **kwargs):
    """Lazily construct the MT5 broker so importing this package never requires
    the Windows-only MetaTrader5 dependency."""
    from .mt5_broker import MT5Broker

    return MT5Broker(*args, **kwargs)

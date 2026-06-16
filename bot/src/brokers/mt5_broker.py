"""MetaTrader 5 live/demo broker adapter.

The ``MetaTrader5`` Python package only runs on Windows (it talks to a running
MT5 terminal), so it is imported lazily: importing this module never fails on
Linux/Mac, you only need the package when you actually trade live.

Recommended workflow:
  1. Open a **demo** account in MT5 first.
  2. Put the credentials in a .env file (never commit it).
  3. Run the bot in paper mode, then demo, and only then consider live.
"""
from __future__ import annotations

from datetime import datetime
from typing import List, Optional

import pandas as pd

from .base import Broker, OrderResult, Position, Tick

_TIMEFRAMES = {
    "M1": "TIMEFRAME_M1", "M5": "TIMEFRAME_M5", "M15": "TIMEFRAME_M15",
    "M30": "TIMEFRAME_M30", "H1": "TIMEFRAME_H1", "H4": "TIMEFRAME_H4",
    "D1": "TIMEFRAME_D1",
}


class MT5Broker(Broker):
    def __init__(
        self,
        symbol: str = "XAUUSD",
        timeframe: str = "M15",
        login: Optional[int] = None,
        password: Optional[str] = None,
        server: Optional[str] = None,
        terminal_path: Optional[str] = None,
        magic: int = 990099,
        deviation: int = 30,
    ):
        try:
            import MetaTrader5 as mt5  # noqa: N813
        except ImportError as exc:  # pragma: no cover - platform dependent
            raise RuntimeError(
                "The 'MetaTrader5' package is required for live trading and only "
                "runs on Windows. Install it with `pip install MetaTrader5` on a "
                "Windows machine (or Windows VPS) that has the MT5 terminal."
            ) from exc

        self._mt5 = mt5
        self.symbol = symbol
        self.timeframe_name = timeframe
        self.magic = magic
        self.deviation = deviation

        kwargs = {}
        if terminal_path:
            kwargs["path"] = terminal_path
        if login:
            kwargs.update(login=int(login), password=password, server=server)
        if not mt5.initialize(**kwargs):
            raise RuntimeError(f"MT5 initialize() failed: {mt5.last_error()}")

        if not mt5.symbol_select(symbol, True):
            raise RuntimeError(f"Could not select symbol {symbol}")

        info = mt5.symbol_info(symbol)
        if info is None:
            raise RuntimeError(f"Symbol {symbol} not found on this account")
        self.point = info.point
        self.contract_size = info.trade_contract_size
        self._tf = getattr(mt5, _TIMEFRAMES.get(timeframe, "TIMEFRAME_M15"))

    # --- account ----------------------------------------------------------
    def _account(self):
        acc = self._mt5.account_info()
        if acc is None:
            raise RuntimeError(f"account_info() failed: {self._mt5.last_error()}")
        return acc

    def equity(self) -> float:
        return float(self._account().equity)

    def balance(self) -> float:
        return float(self._account().balance)

    # --- market data ------------------------------------------------------
    def last_tick(self) -> Tick:
        t = self._mt5.symbol_info_tick(self.symbol)
        return Tick(datetime.fromtimestamp(t.time), float(t.bid), float(t.ask), self.point)

    def candles(self, count: int) -> pd.DataFrame:
        rates = self._mt5.copy_rates_from_pos(self.symbol, self._tf, 0, count)
        if rates is None or len(rates) == 0:
            return pd.DataFrame(columns=["open", "high", "low", "close", "volume"])
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df = df.set_index("time")
        df = df.rename(columns={"tick_volume": "volume"})
        return df[["open", "high", "low", "close", "volume"]]

    # --- positions --------------------------------------------------------
    def positions(self) -> List[Position]:
        raw = self._mt5.positions_get(symbol=self.symbol) or ()
        out = []
        for p in raw:
            if p.magic != self.magic:
                continue
            out.append(
                Position(
                    ticket=p.ticket,
                    symbol=p.symbol,
                    direction=1 if p.type == self._mt5.POSITION_TYPE_BUY else -1,
                    volume=p.volume,
                    entry_price=p.price_open,
                    sl=p.sl,
                    tp=p.tp,
                    open_time=datetime.fromtimestamp(p.time),
                    comment=p.comment,
                )
            )
        return out

    # --- orders -----------------------------------------------------------
    def _filling_mode(self):
        mt5 = self._mt5
        info = mt5.symbol_info(self.symbol)
        # Respect the broker's allowed filling mode where possible.
        if info and info.filling_mode & 1:
            return mt5.ORDER_FILLING_FOK
        if info and info.filling_mode & 2:
            return mt5.ORDER_FILLING_IOC
        return mt5.ORDER_FILLING_RETURN

    def open(self, direction: int, volume: float, sl: float, tp: float, comment: str = "") -> OrderResult:
        mt5 = self._mt5
        tick = mt5.symbol_info_tick(self.symbol)
        if direction > 0:
            order_type, price = mt5.ORDER_TYPE_BUY, tick.ask
        else:
            order_type, price = mt5.ORDER_TYPE_SELL, tick.bid

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": self.symbol,
            "volume": float(volume),
            "type": order_type,
            "price": price,
            "sl": float(sl),
            "tp": float(tp),
            "deviation": self.deviation,
            "magic": self.magic,
            "comment": comment[:31],
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": self._filling_mode(),
        }
        result = mt5.order_send(request)
        if result is None or result.retcode != mt5.TRADE_RETCODE_DONE:
            return OrderResult(False, message=f"order_send failed: {getattr(result, 'comment', mt5.last_error())}")
        pos = Position(
            ticket=result.order, symbol=self.symbol, direction=int(direction),
            volume=volume, entry_price=result.price, sl=sl, tp=tp,
            open_time=datetime.now(), comment=comment,
        )
        return OrderResult(True, pos, "filled")

    def modify(self, ticket: int, sl: float, tp: float) -> bool:
        mt5 = self._mt5
        request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": self.symbol,
            "position": ticket,
            "sl": float(sl),
            "tp": float(tp),
            "magic": self.magic,
        }
        result = mt5.order_send(request)
        return result is not None and result.retcode == mt5.TRADE_RETCODE_DONE

    def close(self, ticket: int) -> bool:
        mt5 = self._mt5
        pos = next((p for p in self.positions() if p.ticket == ticket), None)
        if pos is None:
            return False
        tick = mt5.symbol_info_tick(self.symbol)
        if pos.direction > 0:
            order_type, price = mt5.ORDER_TYPE_SELL, tick.bid
        else:
            order_type, price = mt5.ORDER_TYPE_BUY, tick.ask
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": self.symbol,
            "volume": pos.volume,
            "type": order_type,
            "position": ticket,
            "price": price,
            "deviation": self.deviation,
            "magic": self.magic,
            "comment": "bot close",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": self._filling_mode(),
        }
        result = mt5.order_send(request)
        return result is not None and result.retcode == mt5.TRADE_RETCODE_DONE

    def shutdown(self) -> None:
        self._mt5.shutdown()

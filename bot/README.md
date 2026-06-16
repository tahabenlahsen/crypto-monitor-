# XAUUSD Multi-Strategy Trading Bot 🪙🤖

An automated **gold (XAUUSD)** trading bot for **MetaTrader 5**. It does not bet
everything on one signal — it runs **six independent strategies** built on a
broad library of indicators (including several most retail traders ignore) and
only trades when they **agree**, all wrapped in a strict **risk-management**
layer.

> ⚠️ **Read this first — honest expectations**
>
> - **No trading bot can guarantee profit.** Trading XAUUSD with leverage can
>   lose money quickly, including more than you risk per trade if you misuse it.
> - This software is provided for **education and research**. It is **not**
>   financial advice.
> - **Always** start on a **demo account**, then forward-test, before risking a
>   single real dollar. The safe rollout path is described below.
> - Backtest results — *especially* on the built-in synthetic data — say
>   **nothing** about future live performance.

---

## What's inside

```
bot/
├── run.py                 # live / demo trading (MetaTrader 5)
├── backtest.py            # backtesting (runs anywhere, no broker needed)
├── config.example.yaml    # copy to config.yaml and edit
├── .env.example           # copy to .env and add your MT5 demo credentials
├── requirements.txt
└── src/
    ├── indicators/        # 20+ indicators (trend, momentum, volatility, volume)
    ├── strategies/        # 6 strategies + the ensemble voter
    ├── risk/              # position sizing, stops, kill switches
    ├── brokers/           # paper simulator + MetaTrader 5 adapter
    ├── data/              # CSV loader + synthetic data generator
    ├── engine.py          # the live trading loop
    └── backtester.py      # the event-driven backtest engine
```

### The indicators
Classic **and** commonly-overlooked tools, so the bot "sees" what most don't:

| Category | Indicators |
|---|---|
| Trend | SMA, EMA, WMA, **Hull MA**, MACD, ADX/DI, **Supertrend**, **Ichimoku**, **Parabolic SAR**, **Aroon** |
| Momentum | RSI, Stochastic, **CCI**, **Williams %R**, **MFI**, ROC, **TSI**, **Fisher Transform** |
| Volatility | ATR, Bollinger Bands, **Keltner Channels**, **Donchian**, **Squeeze**, Hist. Volatility |
| Volume/Flow | **OBV**, **VWAP**, **Chaikin Money Flow**, Accumulation/Distribution |

### The six strategies
1. **Trend-following** — EMA regime + ADX filter + MACD + Supertrend
2. **Mean-reversion** — RSI + Bollinger %b + Stochastic + Williams %R (only in ranges)
3. **Breakout** — Bollinger/Keltner squeeze release + Donchian break + money-flow
4. **Momentum** — MACD + TSI + ROC + RSI bias
5. **Ichimoku** — price vs the Kumo cloud + Tenkan/Kijun cross
6. **VWAP + flow** — price vs rolling VWAP + CMF + OBV

These are fused by an **ensemble**: each votes `direction × confidence × weight`,
and the bot only trades when the net conviction clears a threshold **and** a
minimum number of strategies agree. One noisy strategy can never force a trade.

### The risk management (the part that keeps you alive)
Enforced on **every bar**:
- **Fixed-fractional position sizing** from an ATR-based stop (default risk **1%/trade**)
- **ATR stop-loss & take-profit** brackets + **trailing stops**
- **Daily-loss kill switch** (default −5%/day)
- **Max-drawdown halt** (default −20% from peak → stops all new trades)
- **Spread filter**, **session filter** (London/NY hours), **min-confidence** gate
- **Max concurrent positions** cap

---

## Installation

```bash
cd bot
python -m pip install -r requirements.txt
```

That installs everything needed for **backtesting** on any OS (Linux/Mac/Windows).
For **live trading** you also need MetaTrader 5 (Windows only — see below).

---

## Quick start — backtest (safe, no account needed)

```bash
python backtest.py                       # synthetic gold data
python backtest.py --bars 10000 --risk 0.005
python backtest.py --csv data/XAUUSD_M15.csv   # your own exported data
```

**Use real data for meaningful results.** Export history from MT5
(*Tools → History Center*, or right-click a chart → *Save As*) to a CSV with
columns `time, open, high, low, close, volume` and pass it with `--csv`.

Run the tests any time:
```bash
python -m pytest -q
```

---

## Going live — the SAFE rollout path 🐢

Do **not** skip steps. Each one costs you nothing but time and protects real money.

1. **Open a DEMO account** with any MT5 broker that offers XAUUSD. Install the
   **MetaTrader 5 desktop terminal** (Windows) and log in.
2. On that Windows machine: `pip install MetaTrader5`
3. Configure the bot:
   ```bash
   cp config.example.yaml config.yaml      # then edit it
   cp .env.example .env                     # add your DEMO login/password/server
   ```
   Set `mode: mt5` in `config.yaml`.
4. **Observe only** (sends no orders) — let it run for days and read the logs:
   ```bash
   python run.py --dry-run
   ```
5. **Demo trading** — once the signals look sane, drop `--dry-run` on the **demo**
   account and let it actually place (fake-money) trades for a few weeks.
6. **Tune** the strategy weights, `threshold`, `min_agree` and risk settings in
   `config.yaml` based on what you see.
7. **Only then**, if and when you're satisfied, consider a **small** live account
   with conservative risk (e.g. `risk_per_trade: 0.005`). Start tiny.

> 🔐 Your `.env` and `config.yaml` are git-ignored. **Never** commit credentials.
> The bot connects to **your** broker — it never sends your money or login
> anywhere else.

---

## Configuration

Everything is in `config.yaml` (copied from `config.example.yaml`) and is fully
commented. Highlights:

```yaml
mode: mt5                 # paper (backtest) | mt5 (live/demo)
symbol: XAUUSD            # match your broker's exact symbol (GOLD, XAUUSD.m, ...)
timeframe: M15
dry_run: false            # true = log signals but place NO orders
risk:
  risk_per_trade: 0.01    # 1% — lower is safer
  max_daily_loss: 0.05
  max_drawdown: 0.20
strategy:
  threshold: 0.25         # conviction needed to trade
  min_agree: 2            # how many strategies must agree
  weights: { trend_following: 1.3, ichimoku: 1.1, ... }
```

---

## How a live tick works

```
new closed bar ─▶ refresh equity ─▶ trail open stops
              └▶ risk gates (drawdown / daily loss / session / spread)
                 └▶ ensemble signal ─▶ position size (ATR) ─▶ SL/TP bracket ─▶ order
```

If `dry_run` is on, the final step is logged instead of sent.

---

## FAQ

**Will this make me money?** Nobody can promise that, and you should distrust
anyone who does. This gives you a disciplined, well-tested framework with strong
risk controls. The edge still has to be validated on real data and markets change.

**Can I run it on a Mac/Linux laptop?** Backtesting yes. Live MT5 trading needs
Windows (a cheap Windows VPS is the usual way to run it 24/7).

**Can I add my own strategy?** Yes — subclass `Strategy` in `src/strategies/`,
return a `Signal`, and add it to the ensemble in `ensemble.py`.

---

## Disclaimer
This software is provided "as is", without warranty of any kind. Trading
leveraged products like XAUUSD carries a high level of risk and may not be
suitable for all investors. You are solely responsible for any trades placed
with this software. The authors accept no liability for any losses incurred.

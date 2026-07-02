# GoldBots — Multi-Strategy XAUUSD Bot Family for MetaTrader 5

Three Expert Advisors (EAs), each trading a different style, sharing one risk
manager so they behave like a single coordinated team on your account.

| Bot | Strategy | Best market | Suggested chart |
|-----|----------|-------------|-----------------|
| `GoldTrendBot.mq5` | EMA 21/55 cross + ADX > 25 filter, ATR stops + trailing | Strong trends | XAUUSD **H1** |
| `GoldBreakoutBot.mq5` | Asian-range breakout at London open | Session momentum | XAUUSD **M15** |
| `GoldMeanReversionBot.mq5` | Bollinger + RSI fades, only when ADX < 20 | Quiet / ranging days | XAUUSD **M30** |

The strategies are intentionally uncorrelated: the trend bot and the
mean-reversion bot use opposite ADX filters, so they never trade the same
market condition, and the breakout bot only acts in a specific time window.

## How they work together (`Include/RiskManager.mqh`)

Every bot calls the same risk manager before opening a trade:

- **Position sizing** — lot size is computed so a stop-loss hit costs a fixed
  % of balance (default **0.5%** per trade).
- **Daily circuit breaker** — the first bot to run each day records the
  starting equity; if account equity drops by the daily limit (default
  **3%**), *all three bots* stop opening trades until the next day.
- **Family position cap** — max open positions across all GoldBots combined
  (default **3**), so the bots can't pile risk on top of each other.
- **One position per bot**, spread filter on every entry.

Magic numbers: 77701 (trend), 77702 (breakout), 77703 (mean reversion). Keep
any new bots you add in the 77701–77799 range so the shared caps see them.

## Installation

1. In MetaTrader 5: **File → Open Data Folder**, then go to `MQL5/Experts/`.
2. Copy the whole `GoldBots` folder there (including the `Include` subfolder).
3. Open MetaEditor (F4 in MT5), find the three `.mq5` files under
   `Experts/GoldBots`, and **Compile** each one (F7). You should get
   *0 errors, 0 warnings*.
4. In MT5, open three XAUUSD charts (H1, M15, M30) and drag one bot onto each.
5. Enable **Algo Trading** (the button in the toolbar) and allow live trading
   in each EA's settings dialog.

> **Server time warning (breakout bot):** the Asian session hours are in your
> *broker's server time*. Defaults (1–8) fit brokers on GMT+2/GMT+3. Check
> when your broker's quiet Asian hours actually are and adjust
> `InpAsiaStartHour` / `InpAsiaEndHour` accordingly.

## Before risking a single real dollar — do this, in order

1. **Backtest** each bot in the Strategy Tester (Ctrl+R): XAUUSD, "Every tick
   based on real ticks", at least 2–3 years of data. Look at max drawdown and
   profit factor, not just net profit.
2. **Optimize carefully** — tune only a couple of parameters at a time and
   verify on a different date range than you optimized on (walk-forward).
   Over-optimized bots look amazing in tests and lose live.
3. **Demo trade** the full trio together for at least 1–2 months.
4. Go live **small** (lowest risk %, smallest account you're OK losing), and
   only scale up after months of live data.

## Risk disclaimer

These bots are a starting framework, not a money printer. Gold is volatile and
leveraged trading can lose more than you invest. Past backtest results do not
guarantee future performance. Never run these on money you cannot afford to
lose, and never disable the risk manager's limits.

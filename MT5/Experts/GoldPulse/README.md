# GoldPulse — Professional XAUUSD (Gold) Expert Advisor for MetaTrader 5

A trend-following / momentum Expert Advisor (EA) built for **gold (XAUUSD)** on
MetaTrader 5. It is engineered around the thing that actually separates
professional bots from the junk sold on the internet: **disciplined risk
management.** The strategy logic is deliberately transparent so you can
backtest it, understand it, and optimize it for *your* broker.

> ### ⚠️ Read this first — honest expectations
> - **No EA guarantees profit.** Anyone who tells you otherwise is selling a
>   scam. Markets change; an edge that worked last year can stop working.
> - This bot's job is to **trade a defined edge with strict risk control** so a
>   bad run doesn't blow your account. Whether it's *net* profitable depends on
>   the market, your broker's spreads/commissions, and your settings.
> - **Always test on a demo account for weeks** before risking real money, and
>   never risk money you can't afford to lose. Trading leveraged CFDs/forex
>   carries a high risk of losing money.

---

## What it does

**Strategy: Trend + Momentum continuation.**

A trade is only taken when *all* of these align (evaluated on **closed bars**,
so there is no repainting):

1. **Higher-timeframe trend** (default H1 EMA-50): price must be on the correct
   side of the HTF trend filter.
2. **Local trend structure**: Fast EMA (21) vs Slow EMA (50) agree with the HTF
   direction.
3. **Entry trigger** (one of):
   - `PULLBACK` (default): price pulls back through the fast EMA and closes back
     in the trend direction — buy the dip / sell the rally.
   - `CROSS`: a fresh EMA cross. Fewer, cleaner signals.
4. **Trend strength**: ADX ≥ 20 and the correct DI line (+DI / −DI) dominates.
5. **Momentum sanity**: RSI is on the right side of the midline but **not**
   overbought/oversold (avoids chasing exhausted moves).

**Exits / management:**
- **Stop loss & take profit are ATR-based** (volatility-adaptive), not fixed
  pips — essential for gold, whose volatility swings a lot.
- **Break-even**: SL is moved to entry (+offset) once trade reaches +1R.
- **ATR trailing stop**: locks in profit as the move extends.

---

## Risk management (the part that matters)

| Control | What it does |
|---|---|
| **Percent-risk sizing** | Lot size is computed so a stop-out loses exactly `InpRiskPercent` of balance — broker/contract-size agnostic via tick value/size. |
| **ATR stops** | SL = ATR × `InpSLatrMult`; TP = SL distance × `InpRiskReward`. |
| **Daily loss limit** | Stops opening trades for the rest of the day at `InpMaxDailyLossPct` drawdown (includes floating P/L). |
| **Max trades/day** | Caps overtrading. |
| **Max positions** | Caps simultaneous exposure. |
| **Spread filter** | Skips entries when the spread is too wide (gold spreads spike around news). |
| **Session filter** | Trades only during chosen server hours (e.g. London/NY). |
| **Min-stop guard** | Honors the broker's minimum stop distance and spread. |

These are *defensive*. They cannot make a losing strategy win, but they keep a
losing streak survivable — which is exactly why the legitimate commercial EAs
charge for them.

---

## Installation

1. Open **MetaTrader 5** → **File → Open Data Folder**.
2. Copy `GoldPulse.mq5` into `MQL5/Experts/` (a `GoldPulse` subfolder is fine).
3. In MT5, open **MetaEditor** (F4), find `GoldPulse.mq5`, press **Compile**
   (F7). You should get **0 errors**. It only uses the standard `Trade` library
   that ships with MT5 — no external dependencies.
4. Back in MT5, refresh the **Navigator** (right-click → Refresh). Drag
   **GoldPulse** onto an **XAUUSD M15** chart.
5. In the dialog, enable **Allow Algo Trading**, then on the **Inputs** tab click
   **Load** and pick `GoldPulse_XAUUSD_M15_conservative.set`.
6. Make sure the **Algo Trading** button in the MT5 toolbar is green.

> **Symbol naming:** your broker may call gold `XAUUSD`, `GOLD`, `XAUUSD.m`,
> `XAUUSDm`, etc. Attach the EA to whatever chart *is* gold on your broker —
> the EA reads the chart's symbol automatically.

---

## Backtesting & optimization (do this before going live)

1. **View → Strategy Tester** (Ctrl+R).
2. Expert: `GoldPulse`; Symbol: your gold symbol; Period: **M15**.
3. Modelling: **Every tick based on real ticks** (most accurate). Use **at least
   1–2 years** of data.
4. Set a realistic **deposit**, **leverage**, and confirm your broker's
   **spread/commission** (gold commissions matter a lot).
5. Load the `.set` preset, run, and read the report. Look for:
   - **Profit factor** > 1.2, **max drawdown** you can stomach (ideally < 20%),
     and a reasonably smooth equity curve — not one lucky trade.
6. **Optimize** sensibly (don't curve-fit): the parameters most worth tuning are
   `InpFastEMA`, `InpSlowEMA`, `InpADXmin`, `InpSLatrMult`, `InpRiskReward`,
   and the session hours. Optimize on one period, then **forward-test** the
   winners on a *different* unseen period.

> **Curve-fitting warning:** if you optimize until the backtest looks perfect,
> it will almost certainly fail live. Prefer settings that are *robust* across a
> range of values over the single "best" combination.

---

## Going live

- **Run on a VPS** (or keep MT5 always-on) so it doesn't miss signals.
- Start on a **demo** that mirrors your live broker for a few weeks.
- Go live **small** — `InpRiskPercent = 0.25–0.5` until you trust it.
- Use a **unique `InpMagic`** per chart/strategy so it never touches trades it
  didn't open.

---

## Key parameters

See the grouped inputs in the EA. The most important:

| Input | Default | Notes |
|---|---|---|
| `InpRiskPercent` | 0.75 | Risk per trade as % of balance. **The main risk dial.** |
| `InpSLatrMult` | 2.0 | Stop distance in ATRs. Lower = tighter stops, more stop-outs. |
| `InpRiskReward` | 1.8 | Take-profit as a multiple of risk. |
| `InpADXmin` | 20 | Higher = only stronger trends. |
| `InpEntryMode` | Pullback | `Cross` for fewer/cleaner trades. |
| `InpMaxDailyLossPct` | 4.0 | Daily circuit-breaker. |
| `InpStartHour/InpEndHour` | 8–21 | Server-time trading window. **Check your broker's server timezone.** |

---

## How sizing works (so you can trust it)

```
riskMoney  = balance × RiskPercent%
lossPerLot = (stopDistanceInPrice / tickSize) × tickValue
lots       = riskMoney / lossPerLot      (then clamped to broker min/max/step)
```

This means the EA always risks the same % regardless of gold's price or your
broker's contract size — the correct, professional way to size positions.

---

## License & disclaimer

Provided as-is for educational and personal use. **Not financial advice.** You
are solely responsible for any trades placed with this software. Test
thoroughly on demo first.

# Ultimate Gold Trader v2 — MT5 Setup Guide

`XAUUSD_UltimateGold_EA.mq5` is a faithful MetaTrader 5 port of your TradingView
Pine strategy. It trades XAUUSD automatically using the same regime-switching
logic, confluence score, macro filters, and 3-stage scale-out.

---

## 1. Install
1. Open MetaTrader 5 → **File → Open Data Folder**.
2. Copy `XAUUSD_UltimateGold_EA.mq5` into `MQL5/Experts/`.
3. In MetaEditor press **F7** to compile (you want **0 errors**).
4. In MT5, open an **XAUUSD** chart (recommended timeframe: **M15 or H1**).
5. Drag the EA onto the chart. Tick **Allow Algo Trading**.

## 2. The macro symbols (important!)
The strategy uses DXY (US Dollar Index) and US10Y (10-year yield) as filters.
**Broker symbol names differ.** Open Market Watch → right-click → *Symbols* and
find what yours are called, then set the inputs:

| Input | Common broker names |
|---|---|
| `DXYSymbol`   | `DXY`, `USDX`, `US.DOLLAR.IDX`, `DX` |
| `YieldSymbol` | `US10Y`, `USTNOTE10`, `UST10Y` |

➡️ **If your broker doesn't offer them, leave `UseDXY` / `UseYields` ON anyway** —
the EA detects the missing symbol and simply *skips* that filter (it never blocks
trading). But then 2 of the 10 confluence points are unavailable, so consider
lowering `MinScore` from 6 to **4**.

## 3. How it decides to trade (mirrors your Pine script)
- **Regime** from ADX: `>25` = TREND, `<20` = RANGE.
- **TREND** → EMA20/50 cross + price>EMA200 + MACD + 4H bias.
- **RANGE** → RSI extreme + Bollinger band touch (fade).
- **BREAKOUT** → Donchian(20) break + ATR expansion + 4H bias.
- **DIVERGENCE** → RSI vs price pivot divergence.
- A signal only fires if the **confluence score ≥ MinScore** *and* the macro,
  session, and news gates pass.

## 4. Exits (mirrors your Pine script)
- Stop loss = `1.5 × ATR`.
- **Scale-out:** close ⅓ at **TP1 (1R)**, ⅓ at **TP2 (2R)**, runner at **TP3 (3R)**.
- After **TP1** → stop moves to **break-even**.
- After **TP2** → runner **trails** at `1 × ATR`.
- Risk per trade = **1% of equity**; size auto-shrinks 50% in HIGH-volatility regimes.

> ⚠️ **Small-account note:** scale-out needs your position to be ≥ 3× the broker's
> minimum lot (e.g. ≥ 0.03 lots if min is 0.01). Below that, MT5 can't close
> thirds, so the EA keeps the trade whole but still does break-even + trailing.

## 5. Test it the honest way — BEFORE real money
1. **Strategy Tester** (Ctrl+R): symbol XAUUSD, "Every tick based on real ticks".
2. Set **Forward = 1/2** so MT5 optimises on one half and *verifies on unseen data*.
3. Optimization criterion: **Custom max** (uses the built-in `OnTester` score that
   rewards profit + low drawdown, not win rate).
4. **Only trust a setting that stays profitable in the Forward tab.** If it collapses
   out-of-sample, it was curve-fit — discard it.
5. Then run on a **DEMO account for several weeks** before risking one real cent.

## Honest expectation
This bot reproduces your strategy precisely — but reproducing a strategy is not the
same as it being profitable. Most discretionary-looking systems lose their edge once
automated and tested out-of-sample. Let the forward test and demo period tell you the
truth, and size tiny if you ever go live.

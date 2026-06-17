# Gold Master EA — the unified bot

`XAUUSD_GoldMaster_EA.mq5` merges **all three** of our bots into one. Three engines
vote on every new bar; the bot trades when enough of them agree.

| Engine | What it is | Toggle |
|---|---|---|
| **A — Ensemble** | 12 indicators vote (EMA, MACD, ADX, RSI, Stoch, CCI, WPR, BB, Ichimoku, SAR, Supertrend, MFI) | `UseEnsemble` |
| **B — Regime**   | Trend / mean-rev / breakout / divergence + 0-10 confluence + DXY/US10Y macro + 4H bias | `UseRegime` |
| **C — Quality**  | EMA 9/21, RSI, Bollinger, intraday momentum — each scored 0-100 | `UseQuality` |

`MinEnginesAgree` = how many engines must agree on direction (1 = aggressive, 2–3 = stricter).

## Install
1. MT5 → File → Open Data Folder → `MQL5/Experts/` → paste the `.mq5` → **F7** (0 errors).
2. Attach to an **XAUUSD** chart (M5 or M15 recommended). Enable **Allow Algo Trading**.
3. Set `DXYSymbol` / `YieldSymbol` to your broker's names (or it auto-skips them).

## ⚙️ You chose AGGRESSIVE (many positions) — here's what protects you
The old multi-strategy bot you sent had a **fake** risk cap. This one is real:

- `MaxConcurrent = 10` — up to 10 positions at once.
- **`MaxTotalRisk = 20`** — ✅ a *working* cap. Before each entry the bot adds up the
  real risk (entry→stop × lots) of every open position. If a new trade would push
  total open risk past 20% of balance, it is **refused**. This is the line that stops
  "many trades" from becoming "infinite trades."
- `MaxDailyTrades = 50`, `MaxDailyLoss = 10%`, `MaxDrawdown = 25%` (halts new trades).

The live `Comment` on the chart shows current open count and **total risk %** so you
can watch it in real time.

## 🛠️ The 3 bugs from your old bot — all fixed here
1. **Unlimited trades** → replaced with `MaxConcurrent` + the real `MaxTotalRisk` cap.
2. **Fake risk cap** → `OpenRiskPct()` actually sums open risk from live positions.
3. **1-point trailing that killed winners** → ATR-based: trails at `Trail_ATR_Mult × ATR`
   (default 1.5×ATR) only after `Trail_ATR_Start × ATR` of profit. Break-even first.
   Dead inputs `SL_ATR_Mult` and `RiskReward` are now actually used.

## Test it honestly before real money
1. Strategy Tester → XAUUSD, "Every tick based on real ticks", **Forward = 1/2**.
2. Criterion: **Custom max** (the built-in `OnTester` rewards profit + low drawdown, not win rate).
3. Trust only settings that stay profitable in the **Forward** (out-of-sample) tab.
4. Then run on a **DEMO account for weeks**. Aggressive mode can draw down hard — see it
   on demo before you ever risk real money.

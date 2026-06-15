//+------------------------------------------------------------------+
//|                                            ICT_CRT_Scalper.mq5    |
//|                          ICT / CRT mechanical scalper for M5      |
//|                                                                  |
//|  Logic (conservative model):                                     |
//|   1. Liquidity pools = highest/lowest of the last N closed bars  |
//|   2. Manipulation    = a candle sweeps a pool with its wick and  |
//|                        closes back inside the range (stop-hunt)  |
//|   3. Confirmation    = that sweep candle closes in the reversal  |
//|                        direction (optional)                      |
//|   4. Entry (OTE)     = wait for price to retrace into the sweep  |
//|                        candle (discount/premium half), then enter|
//|   5. Stop  = just beyond the swept wick                          |
//|      Target= opposite liquidity pool, or a fixed Risk:Reward     |
//|   6. Trades only inside London / New York kill zones             |
//|                                                                  |
//|  NOTE: ICT/CRT are discretionary concepts. This is a simplified  |
//|  rules-based version. Backtest and demo-test before live use.    |
//+------------------------------------------------------------------+
#property copyright "ICT/CRT Scalper"
#property link      ""
#property version   "1.00"
#property description "Mechanical ICT/CRT liquidity-sweep scalper for M5 (kill zones)"

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
//--- System
input string  sys1 = "════════ SYSTEM ════════";        // ---
input ulong   MagicNumber       = 778899;               // EA Magic Number
input double  RiskPerTrade      = 1.0;                   // Risk % per trade
input int     MaxConcurrentTrades = 1;                  // Max open positions
input int     MaxDailyTrades    = 15;                   // Max trades per day
input int     MaxSpreadPoints   = 40;                   // Skip if spread above (points)
input bool    DebugMode         = true;                 // Print reasons in Experts tab
input bool    DiagnosticMode    = false;                // TEST ONLY: ignore kill zone + confirmation

//--- Kill Zones (BROKER/SERVER time hours - adjust to your broker!)
input string  kz1 = "════════ KILL ZONES (server time) ════════"; // ---
input bool    TradeLondon       = true;                 // Trade London session
input int     LondonStartHour   = 8;                    // London start hour
input int     LondonEndHour     = 11;                   // London end hour
input bool    TradeNewYork      = true;                 // Trade New York session
input int     NYStartHour       = 13;                   // New York start hour
input int     NYEndHour         = 16;                   // New York end hour

//--- Setup detection
input string  set1 = "════════ SETUP / CRT ════════";   // ---
input int     RangeLookback     = 20;                   // Bars used for liquidity pools
input int     MinSweepPoints    = 0;                    // Min wick penetration beyond pool (points)
input bool    RequireConfirmCandle = true;              // Sweep candle must close in reversal dir
input double  EntryRetracePercent  = 50.0;              // OTE retrace into sweep candle (%)
input int     SetupExpiryBars   = 6;                    // Cancel setup if no entry within N bars

//--- Risk / exits
input string  rsk1 = "════════ RISK / EXITS ════════";  // ---
input int     SL_BufferPoints   = 15;                   // Stop buffer beyond swept wick (points)
input bool    TargetOppositeLiquidity = true;           // TP = opposite pool (else use RR)
input double  RiskReward        = 2.0;                   // Risk:Reward when not using liquidity TP
input bool    UseBreakeven      = true;                 // Move SL to breakeven in profit
input int     BreakevenPoints   = 30;                   // Profit (points) to trigger breakeven
input bool    UseTrailing       = true;                 // Trailing stop
input bool    UseATRTrailing    = true;                 // Trail by ATR (else fixed points)
input int     ATRPeriod         = 14;                   // ATR period for trailing
input double  TrailATRMult      = 1.2;                  // Trail distance = ATR x this
input int     TrailFixedPoints  = 60;                   // Trail distance (fixed mode)
input int     TrailStartPoints  = 50;                   // Start trailing after this profit (points)

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
int      handle_ATR;
datetime g_lastBar      = 0;
datetime g_lastReset    = 0;
int      g_tradesToday  = 0;

//--- pending setup (one at a time)
bool     g_setupActive   = false;
int      g_setupDir      = 0;       // 1 = buy, -1 = sell
double   g_zoneTop       = 0;       // entry zone upper bound
double   g_zoneBottom    = 0;       // entry zone lower bound
double   g_setupStop     = 0;       // stop price (beyond wick)
double   g_targetLiq     = 0;       // opposite liquidity target
datetime g_setupExpiry   = 0;

//+------------------------------------------------------------------+
int OnInit() {
   if(RiskPerTrade < 0.1 || RiskPerTrade > 5.0) {
      Print("RiskPerTrade must be 0.1 - 5.0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   handle_ATR = iATR(_Symbol, PERIOD_M5, ATRPeriod);
   if(handle_ATR == INVALID_HANDLE) { Print("ATR handle failed"); return(INIT_FAILED); }

   g_lastReset = iTime(_Symbol, PERIOD_D1, 0);
   g_tradesToday = 0;
   Print("ICT/CRT Scalper initialized. DiagnosticMode=", DiagnosticMode);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if(handle_ATR != INVALID_HANDLE) IndicatorRelease(handle_ATR);
}

//+------------------------------------------------------------------+
//| MAIN LOOP                                                        |
//+------------------------------------------------------------------+
void OnTick() {
   DailyReset();
   ManageTrades();

   //--- Entry trigger is checked every tick for fast scalping fills
   if(g_setupActive) CheckEntryTrigger();

   //--- New setups are scanned once per new M5 bar
   datetime curBar = iTime(_Symbol, PERIOD_M5, 0);
   if(curBar == g_lastBar) return;
   g_lastBar = curBar;

   //--- Expire stale setups
   if(g_setupActive && TimeCurrent() >= g_setupExpiry) {
      if(DebugMode) Print("Setup expired without entry");
      g_setupActive = false;
   }

   if(!g_setupActive) ScanForSetup();
}

//+------------------------------------------------------------------+
//| SETUP SCANNER (runs on a new bar)                                |
//+------------------------------------------------------------------+
void ScanForSetup() {
   //--- Kill zone gate
   if(!DiagnosticMode && !InKillZone()) { if(DebugMode) Print("Outside kill zone"); return; }

   //--- Trade-count / position gate
   if(g_tradesToday >= MaxDailyTrades) return;
   if(CountPositions() >= MaxConcurrentTrades) return;

   //--- Liquidity pools from bars BEFORE the sweep candle (shift 2..RangeLookback+1)
   int hh = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, RangeLookback, 2);
   int ll = iLowest(_Symbol, PERIOD_M5, MODE_LOW, RangeLookback, 2);
   if(hh < 0 || ll < 0) return;
   double rangeHigh = iHigh(_Symbol, PERIOD_M5, hh);
   double rangeLow  = iLow(_Symbol, PERIOD_M5, ll);

   //--- The "manipulation" candle is the last closed bar (shift 1)
   double h1 = iHigh(_Symbol, PERIOD_M5, 1);
   double l1 = iLow(_Symbol, PERIOD_M5, 1);
   double o1 = iOpen(_Symbol, PERIOD_M5, 1);
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double buf = MinSweepPoints * _Point;

   //--- Bullish setup: swept the low and closed back above it
   bool bullSweep = (l1 < rangeLow - buf) && (c1 > rangeLow);
   if(RequireConfirmCandle) bullSweep = bullSweep && (c1 > o1);   // bullish close

   //--- Bearish setup: swept the high and closed back below it
   bool bearSweep = (h1 > rangeHigh + buf) && (c1 < rangeHigh);
   if(RequireConfirmCandle) bearSweep = bearSweep && (c1 < o1);   // bearish close

   if(bullSweep) {
      double mid = l1 + (h1 - l1) * (EntryRetracePercent / 100.0);  // OTE / discount
      ArmSetup(1, mid, l1, l1 - SL_BufferPoints * _Point, rangeHigh);
      if(DebugMode) Print("BULL sweep armed: zone[", g_zoneBottom, " - ", g_zoneTop, "] stop=", g_setupStop, " targetLiq=", rangeHigh);
   }
   else if(bearSweep) {
      double mid = h1 - (h1 - l1) * (EntryRetracePercent / 100.0);  // OTE / premium
      ArmSetup(-1, h1, mid, h1 + SL_BufferPoints * _Point, rangeLow);
      if(DebugMode) Print("BEAR sweep armed: zone[", g_zoneBottom, " - ", g_zoneTop, "] stop=", g_setupStop, " targetLiq=", rangeLow);
   }
}

void ArmSetup(int dir, double zoneTop, double zoneBottom, double stop, double targetLiq) {
   g_setupActive = true;
   g_setupDir    = dir;
   g_zoneTop     = zoneTop;
   g_zoneBottom  = zoneBottom;
   g_setupStop   = stop;
   g_targetLiq   = targetLiq;
   g_setupExpiry = TimeCurrent() + SetupExpiryBars * PeriodSeconds(PERIOD_M5);
}

//+------------------------------------------------------------------+
//| ENTRY TRIGGER (runs every tick while a setup is armed)           |
//+------------------------------------------------------------------+
void CheckEntryTrigger() {
   if(!DiagnosticMode && !InKillZone()) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask - bid) / _Point;
   if(spreadPts > MaxSpreadPoints) return;

   if(g_setupDir == 1) {
      //--- Invalidate if price broke below the swept wick (structure failed)
      if(bid < g_setupStop) { g_setupActive = false; if(DebugMode) Print("Bull setup invalidated"); return; }
      //--- Enter when price retraces down into the discount zone
      if(bid <= g_zoneTop) {
         OpenTrade(1, g_setupStop, g_targetLiq);
         g_setupActive = false;
      }
   }
   else if(g_setupDir == -1) {
      if(ask > g_setupStop) { g_setupActive = false; if(DebugMode) Print("Bear setup invalidated"); return; }
      if(ask >= g_zoneBottom) {
         OpenTrade(-1, g_setupStop, g_targetLiq);
         g_setupActive = false;
      }
   }
}

//+------------------------------------------------------------------+
//| ORDER EXECUTION                                                  |
//+------------------------------------------------------------------+
void OpenTrade(int dir, double stop, double targetLiq) {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (dir == 1) ? ask : bid;

   double stopDistPoints = MathAbs(entry - stop) / _Point;
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(MathAbs(entry - stop) < minStop) {
      if(DebugMode) Print("Stop too close to entry, skip");
      return;
   }

   //--- Take profit: opposite liquidity, else Risk:Reward
   double tp;
   if(TargetOppositeLiquidity) {
      tp = targetLiq;
      //--- Fallback to RR if the liquidity target is on the wrong side / too close
      bool badTp = (dir == 1 && tp <= entry + minStop) || (dir == -1 && tp >= entry - minStop);
      if(badTp) tp = entry + dir * RiskReward * MathAbs(entry - stop);
   } else {
      tp = entry + dir * RiskReward * MathAbs(entry - stop);
   }

   double lots = CalcLots(stopDistPoints);

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lots;
   req.type      = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price     = entry;
   req.sl        = NormalizeDouble(stop, _Digits);
   req.tp        = NormalizeDouble(tp, _Digits);
   req.deviation = 10;
   req.magic     = MagicNumber;
   req.comment   = (dir == 1) ? "ICT_CRT_BUY" : "ICT_CRT_SELL";

   if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
      g_tradesToday++;
      Print("TRADE: ", (dir==1?"BUY":"SELL"), " lots=", lots, " entry=", entry, " SL=", stop, " TP=", tp);
   } else {
      Print("OrderSend failed retcode=", res.retcode, " err=", GetLastError());
   }
}

double CalcLots(double stopDistPoints) {
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPerTrade / 100.0);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double valPerPoint = contractSize * tickSize;
   double lossOneLot = stopDistPoints * valPerPoint;
   if(lossOneLot <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = riskAmount / lossOneLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, minL);
   lots = MathMin(lots, maxL);
   return lots;
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT (breakeven + trailing)                          |
//+------------------------------------------------------------------+
void ManageTrades() {
   double atr[1];
   double trailDist = TrailFixedPoints * _Point;
   if(UseATRTrailing && CopyBuffer(handle_ATR, 0, 0, 1, atr) == 1) trailDist = atr[0] * TrailATRMult;
   double beBuffer = 3 * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = isBuy ? (price - open) / _Point : (open - price) / _Point;

      //--- Breakeven
      if(UseBreakeven && profitPts >= BreakevenPoints) {
         double beSL = open + (isBuy ? beBuffer : -beBuffer);
         if(isBuy  && sl < beSL) { Modify(ticket, beSL, tp); sl = beSL; }
         if(!isBuy && (sl == 0 || sl > beSL)) { Modify(ticket, beSL, tp); sl = beSL; }
      }

      //--- Trailing
      if(UseTrailing && profitPts >= TrailStartPoints) {
         if(isBuy) {
            double n = price - trailDist;
            if(n > sl) Modify(ticket, n, tp);
         } else {
            double n = price + trailDist;
            if(n < sl || sl == 0) Modify(ticket, n, tp);
         }
      }
   }
}

void Modify(ulong ticket, double sl, double tp) {
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.sl       = NormalizeDouble(sl, _Digits);
   req.tp       = NormalizeDouble(tp, _Digits);
   if(!OrderSend(req, res)) Print("Modify failed retcode=", res.retcode);
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
bool InKillZone() {
   MqlDateTime t; TimeCurrent(t);
   int h = t.hour;
   if(TradeLondon  && h >= LondonStartHour && h < LondonEndHour) return true;
   if(TradeNewYork && h >= NYStartHour     && h < NYEndHour)     return true;
   return false;
}

int CountPositions() {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) c++;
   }
   return c;
}

void DailyReset() {
   datetime d = iTime(_Symbol, PERIOD_D1, 0);
   if(d != g_lastReset) {
      g_lastReset = d;
      g_tradesToday = 0;
      if(DebugMode) Print("Daily reset");
   }
}
//+------------------------------------------------------------------+

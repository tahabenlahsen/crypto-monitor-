//+------------------------------------------------------------------+
//|                                                    GoldPulse.mq5  |
//|                  Professional XAUUSD (Gold) Trend + Momentum EA   |
//|                                                                   |
//|  A trend-following / momentum Expert Advisor designed for gold.   |
//|  Its value is in DISCIPLINE, not magic: ATR-based stops, strict   |
//|  percent-risk position sizing, daily loss limits, spread/session  |
//|  filters, break-even and trailing management.                     |
//|                                                                   |
//|  There is NO guaranteed-profit setting. Backtest and optimize     |
//|  on YOUR broker's data before risking real money.                 |
//+------------------------------------------------------------------+
#property copyright "GoldPulse EA"
#property version   "1.10"
#property description "XAUUSD Trend + Momentum EA with strict risk management."

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//==================================================================//
//                            INPUTS                                //
//==================================================================//

enum ENUM_TRADE_DIR
  {
   DIR_BOTH = 0,   // Long & Short
   DIR_LONG = 1,   // Long only
   DIR_SHORT= 2    // Short only
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_CROSS    = 0, // Fresh EMA cross (fewer, cleaner signals)
   ENTRY_PULLBACK = 1  // Pullback re-cross of fast EMA (more signals)
  };

enum ENUM_LOT_MODE
  {
   LOT_RISK_PERCENT = 0, // Risk % of balance (recommended)
   LOT_FIXED        = 1  // Fixed lot size
  };

input group "=== General ==="
input long           InpMagic          = 770011;     // Magic number (unique per chart)
input string         InpComment        = "GoldPulse"; // Order comment
input int            InpSlippage       = 30;          // Max slippage (points)

input group "=== Strategy / Trend ==="
input ENUM_ENTRY_MODE InpEntryMode     = ENTRY_PULLBACK; // Entry mode
input ENUM_TRADE_DIR InpTradeDir       = DIR_BOTH;     // Allowed trade direction
input int            InpFastEMA        = 21;           // Fast EMA period
input int            InpSlowEMA        = 50;           // Slow EMA period
input ENUM_TIMEFRAMES InpHTF           = PERIOD_H1;    // Higher timeframe (trend filter)
input int            InpHTFema         = 50;           // HTF EMA period (trend filter)

input group "=== Momentum Filters ==="
input int            InpADXperiod      = 14;           // ADX period
input double         InpADXmin         = 20.0;         // Min ADX (trend strength)
input int            InpRSIperiod      = 14;           // RSI period
input double         InpRSImid         = 50.0;         // RSI midline
input double         InpRSIoverbought  = 72.0;         // RSI overbought (block longs above)
input double         InpRSIoversold    = 28.0;         // RSI oversold (block shorts below)

input group "=== Volatility / Stops (ATR) ==="
input int            InpATRperiod      = 14;           // ATR period
input double         InpSLatrMult      = 2.0;          // Stop loss = ATR x this
input bool           InpUseTP          = true;         // Use a take profit
input double         InpRiskReward     = 1.8;          // TP = SL distance x this (reward:risk)
input int            InpMinStopPoints  = 0;            // Extra min stop distance (points, 0=auto)

input group "=== Position Sizing / Risk ==="
input ENUM_LOT_MODE  InpLotMode        = LOT_RISK_PERCENT; // Lot sizing method
input double         InpRiskPercent    = 0.75;         // Risk per trade (% of balance)
input double         InpFixedLot       = 0.10;         // Fixed lot (if LOT_FIXED)
input double         InpMaxLot         = 5.0;          // Hard cap on lot size

input group "=== Trade Management ==="
input bool           InpUseBreakEven   = true;         // Move SL to break-even
input double         InpBEtriggerR      = 1.0;         // BE trigger at this R (profit/risk)
input double         InpBEoffsetPoints  = 20;          // BE offset (points beyond entry)
input bool           InpUseTrailing    = true;         // Trailing stop (ATR based)
input double         InpTrailATRmult   = 2.0;          // Trailing distance = ATR x this
input double         InpTrailStartR     = 1.0;         // Start trailing at this R

input group "=== Safety Filters ==="
input int            InpMaxSpread       = 0;           // Max spread (points), 0 = OFF (digit-dependent!)
input double         InpMaxSpreadATRpct = 35.0;        // Max spread as % of ATR (0 = OFF, broker-agnostic)
input int            InpMaxPositions    = 1;           // Max simultaneous EA positions
input int            InpMaxTradesPerDay = 6;           // Max new trades per day (0 = no limit)
input double         InpMaxDailyLossPct = 4.0;         // Stop for the day at this loss (% bal)
input bool           InpOnePerBar       = true;        // Only one entry per bar
input bool           InpVerbose         = true;        // Print diagnostics to Journal

input group "=== Session Filter (server time) ==="
input bool           InpUseSession     = true;         // Restrict trading hours
input int            InpStartHour      = 8;            // Session start hour (0-23)
input int            InpEndHour        = 21;           // Session end hour (0-23)
input bool           InpCloseOutOfSess = false;        // Close trades outside session

//==================================================================//
//                         GLOBAL STATE                             //
//==================================================================//
CTrade        trade;
CSymbolInfo   symInfo;

int  hFastEMA = INVALID_HANDLE;
int  hSlowEMA = INVALID_HANDLE;
int  hHTFema  = INVALID_HANDLE;
int  hADX     = INVALID_HANDLE;
int  hRSI     = INVALID_HANDLE;
int  hATR     = INVALID_HANDLE;

datetime g_lastBarTime  = 0;   // for new-bar detection
datetime g_lastTradeBar = 0;   // bar of last entry (one-per-bar)
int      g_today        = -1;  // current day-of-year
int      g_tradesToday  = 0;   // entries opened today
double   g_dayStartEquity = 0; // equity at start of day
bool     g_dayBlocked   = false; // daily loss limit hit

double   g_point  = 0.0;
int      g_digits = 0;

// --- diagnostic counters (why are we / are we not trading) ---
long g_barsEval=0, g_blkDaily=0, g_blkSession=0, g_blkSpread=0, g_blkMaxPos=0;
long g_blkMaxTr=0, g_blkOnePerBar=0, g_noSignal=0, g_blkDir=0, g_tradesTotal=0;

//==================================================================//
//                            INIT                                  //
//==================================================================//
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(!symInfo.Name(_Symbol))
     {
      Print("ERROR: cannot select symbol ", _Symbol);
      return(INIT_FAILED);
     }

   // --- create indicator handles on the CHART timeframe ---
   hFastEMA = iMA(_Symbol, PERIOD_CURRENT, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, PERIOD_CURRENT, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hHTFema  = iMA(_Symbol, InpHTF,         InpHTFema,  0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, PERIOD_CURRENT, InpADXperiod);
   hRSI     = iRSI(_Symbol, PERIOD_CURRENT, InpRSIperiod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_CURRENT, InpATRperiod);

   if(hFastEMA==INVALID_HANDLE || hSlowEMA==INVALID_HANDLE || hHTFema==INVALID_HANDLE ||
      hADX==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      Print("ERROR: failed to create one or more indicator handles.");
      return(INIT_FAILED);
     }

   // --- configure trade object ---
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   ResetDayCounters();
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   PrintFormat("GoldPulse initialized on %s %s | point=%.*f digits=%d",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()), g_digits, g_point, g_digits);

   if(InpVerbose)
     {
      PrintFormat("SYMBOL SPEC %s: digits=%d  point=%.*f  spread(now)=%d pts",
                  _Symbol, g_digits, g_digits, g_point,
                  (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
      PrintFormat("  tickValue=%.5f tickSize=%.5f volMin=%.2f volStep=%.2f volMax=%.2f stopsLevel=%d",
                  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
                  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
                  (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
     }
   return(INIT_SUCCEEDED);
  }

//==================================================================//
//                           DEINIT                                 //
//==================================================================//
void OnDeinit(const int reason)
  {
   if(hFastEMA!=INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA!=INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hHTFema !=INVALID_HANDLE) IndicatorRelease(hHTFema);
   if(hADX    !=INVALID_HANDLE) IndicatorRelease(hADX);
   if(hRSI    !=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR    !=INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");

   if(InpVerbose)
     {
      Print("================ GoldPulse DIAGNOSTIC SUMMARY ================");
      PrintFormat("Bars evaluated (new bars): %I64d", g_barsEval);
      PrintFormat("Blocked -> spread:%I64d  session:%I64d  daily:%I64d  maxPos:%I64d  maxTrades:%I64d  onePerBar:%I64d  direction:%I64d",
                  g_blkSpread, g_blkSession, g_blkDaily, g_blkMaxPos, g_blkMaxTr, g_blkOnePerBar, g_blkDir);
      PrintFormat("No-signal bars: %I64d   |   TRADES OPENED: %I64d", g_noSignal, g_tradesTotal);

      if(g_barsEval>0 && g_blkSpread >= g_barsEval)
         Print(">>> CAUSE: the SPREAD filter blocked EVERY bar. Set InpMaxSpread=0 and/or raise InpMaxSpreadATRpct.");
      else if(g_barsEval>0 && g_blkSession >= g_barsEval)
         Print(">>> CAUSE: the SESSION filter blocked every bar. Check broker server hours / set InpUseSession=false.");
      else if(g_tradesTotal==0 && g_noSignal>0 && g_noSignal >= g_barsEval/2)
         Print(">>> CAUSE: no signals met all conditions. Loosen InpADXmin / try InpEntryMode=Cross / longer test period.");
      Print("=============================================================");
     }
  }

//==================================================================//
//                            TICK                                  //
//==================================================================//
void OnTick()
  {
   if(!symInfo.RefreshRates())
      return;

   UpdateDayState();

   // Manage existing positions every tick (break-even, trailing, session close)
   ManageOpenPositions();

   // Out-of-session forced close
   if(InpUseSession && InpCloseOutOfSess && !InSession())
      CloseAllOurPositions("out-of-session");

   // Only evaluate entries on a fresh bar
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool newBar = (curBar != g_lastBarTime);
   if(newBar)
      g_lastBarTime = curBar;

   ShowDashboard();

   if(!newBar)
      return;

   g_barsEval++;

   // --- Entry gating (with diagnostic counters) ---
   if(g_dayBlocked)                                   { g_blkDaily++;     return; }
   if(InpUseSession && !InSession())                  { g_blkSession++;   return; }
   if(!SpreadOK())                                    { g_blkSpread++;    return; }
   if(CountOurPositions() >= InpMaxPositions)         { g_blkMaxPos++;    return; }
   if(InpMaxTradesPerDay>0 && g_tradesToday >= InpMaxTradesPerDay) { g_blkMaxTr++; return; }
   if(InpOnePerBar && g_lastTradeBar==curBar)         { g_blkOnePerBar++; return; }

   int signal = GetSignal();   // +1 buy, -1 sell, 0 none
   if(signal == 0)                                    { g_noSignal++;     return; }

   if(signal>0 && InpTradeDir==DIR_SHORT)             { g_blkDir++;       return; }
   if(signal<0 && InpTradeDir==DIR_LONG)              { g_blkDir++;       return; }

   OpenTrade(signal);
  }

//==================================================================//
//                       SIGNAL GENERATION                          //
//==================================================================//
// Evaluates on CLOSED bars (shift 1 & 2) to avoid intrabar repaint.
int GetSignal()
  {
   double fast[], slow[], htf[], adxMain[], plusDI[], minusDI[], rsi[], close[];

   if(!CopyBufSeries(hFastEMA,0,3,fast))   return(0);
   if(!CopyBufSeries(hSlowEMA,0,3,slow))   return(0);
   if(!CopyBufSeries(hHTFema, 0,3,htf))    return(0);
   if(!CopyBufSeries(hADX,    0,3,adxMain))return(0);
   if(!CopyBufSeries(hADX,    1,3,plusDI)) return(0);
   if(!CopyBufSeries(hADX,    2,3,minusDI))return(0);
   if(!CopyBufSeries(hRSI,    0,3,rsi))    return(0);

   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, close) < 3) return(0);
   ArraySetAsSeries(close, true);

   // Indices: [0]=forming bar, [1]=last closed, [2]=prior closed.
   double c1 = close[1],  c2 = close[2];
   double f1 = fast[1],   f2 = fast[2];
   double s1 = slow[1],   s2 = slow[2];
   double htfVal = htf[1];
   double adx = adxMain[1];
   double pdi = plusDI[1], mdi = minusDI[1];
   double r1  = rsi[1];

   bool trendOK   = (adx >= InpADXmin);
   bool htfUp     = (c1 > htfVal);
   bool htfDown   = (c1 < htfVal);

   //------------------- LONG -------------------
   bool emaLongStruct = (f1 > s1);
   bool longTrigger   = false;
   if(InpEntryMode==ENTRY_CROSS)
      longTrigger = (f2 <= s2 && f1 > s1);            // fresh bullish cross
   else
      longTrigger = (c2 < f2 && c1 > f1 && f1 > s1);  // pullback re-cross above fast EMA

   bool longRSI = (r1 > InpRSImid && r1 < InpRSIoverbought);

   if(htfUp && trendOK && emaLongStruct && longTrigger && (pdi > mdi) && longRSI)
      return(+1);

   //------------------- SHORT ------------------
   bool emaShortStruct = (f1 < s1);
   bool shortTrigger   = false;
   if(InpEntryMode==ENTRY_CROSS)
      shortTrigger = (f2 >= s2 && f1 < s1);
   else
      shortTrigger = (c2 > f2 && c1 < f1 && f1 < s1);

   bool shortRSI = (r1 < InpRSImid && r1 > InpRSIoversold);

   if(htfDown && trendOK && emaShortStruct && shortTrigger && (mdi > pdi) && shortRSI)
      return(-1);

   return(0);
  }

//==================================================================//
//                          OPEN TRADE                              //
//==================================================================//
void OpenTrade(int signal)
  {
   double atr = GetATR();
   if(atr <= 0)
     {
      Print("ATR unavailable, skipping entry.");
      return;
     }

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();

   double slDist = atr * InpSLatrMult;
   slDist = EnforceMinStop(slDist);

   double price, sl, tp = 0.0;

   if(signal > 0) // BUY
     {
      price = ask;
      sl    = NormalizePrice(price - slDist);
      if(InpUseTP)
         tp = NormalizePrice(price + slDist * InpRiskReward);
     }
   else           // SELL
     {
      price = bid;
      sl    = NormalizePrice(price + slDist);
      if(InpUseTP)
         tp = NormalizePrice(price - slDist * InpRiskReward);
     }

   double lots = CalcLots(slDist);
   if(lots <= 0)
     {
      Print("Lot size resolved to 0 — entry skipped (check risk/SL settings).");
      return;
     }

   bool ok;
   if(signal > 0)
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment);
   else
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);

   if(ok)
     {
      g_tradesToday++;
      g_tradesTotal++;
      g_lastTradeBar = iTime(_Symbol, PERIOD_CURRENT, 0);
      PrintFormat("OPEN %s %.2f lots @~%.*f SL=%.*f TP=%.*f (ATR=%.*f, risk=%.2f%%)",
                  (signal>0?"BUY":"SELL"), lots, g_digits, price, g_digits, sl,
                  g_digits, tp, g_digits, atr,
                  (InpLotMode==LOT_RISK_PERCENT?InpRiskPercent:0.0));
     }
   else
     {
      PrintFormat("Order FAILED: retcode=%d (%s)", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
     }
  }

//==================================================================//
//                    POSITION MANAGEMENT                           //
//==================================================================//
void ManageOpenPositions()
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   double atr = GetATR();

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)                              continue;
      if(!PositionSelectByTicket(ticket))          continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double bid    = symInfo.Bid();
      double ask    = symInfo.Ask();

      // R = initial risk distance (approx via current SL or ATR fallback)
      double riskDist = (curSL>0 ? MathAbs(open - curSL) : atr*InpSLatrMult);
      if(riskDist <= 0) continue;

      if(type == POSITION_TYPE_BUY)
        {
         double profitDist = bid - open;
         double rMultiple  = profitDist / riskDist;

         // Break-even
         if(InpUseBreakEven && rMultiple >= InpBEtriggerR)
           {
            double beSL = NormalizePrice(open + InpBEoffsetPoints*g_point);
            if(beSL > curSL && beSL < bid)
               ModifySL(ticket, beSL, curTP);
            curSL = MathMax(curSL, beSL);
           }

         // Trailing
         if(InpUseTrailing && atr>0 && rMultiple >= InpTrailStartR)
           {
            double trailSL = NormalizePrice(bid - atr*InpTrailATRmult);
            if(trailSL > curSL && trailSL < bid)
               ModifySL(ticket, trailSL, curTP);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profitDist = open - ask;
         double rMultiple  = profitDist / riskDist;

         if(InpUseBreakEven && rMultiple >= InpBEtriggerR)
           {
            double beSL = NormalizePrice(open - InpBEoffsetPoints*g_point);
            if((curSL==0 || beSL < curSL) && beSL > ask)
               ModifySL(ticket, beSL, curTP);
            if(curSL==0) curSL = beSL; else curSL = MathMin(curSL, beSL);
           }

         if(InpUseTrailing && atr>0 && rMultiple >= InpTrailStartR)
           {
            double trailSL = NormalizePrice(ask + atr*InpTrailATRmult);
            if((curSL==0 || trailSL < curSL) && trailSL > ask)
               ModifySL(ticket, trailSL, curTP);
           }
        }
     }
  }

void ModifySL(ulong ticket, double sl, double tp)
  {
   // Respect broker minimum stop distance from market.
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * g_point;
   double bid = symInfo.Bid();
   double ask = symInfo.Ask();

   if(PositionSelectByTicket(ticket))
     {
      long type = PositionGetInteger(POSITION_TYPE);
      if(type==POSITION_TYPE_BUY  && (bid - sl) < minDist) return;
      if(type==POSITION_TYPE_SELL && (sl - ask) < minDist) return;
     }
   if(!trade.PositionModify(ticket, sl, tp))
      PrintFormat("PositionModify failed t=%I64u retcode=%d", ticket, trade.ResultRetcode());
  }

//==================================================================//
//                       RISK / SIZING                              //
//==================================================================//
double CalcLots(double slPriceDistance)
  {
   if(InpLotMode == LOT_FIXED)
      return NormalizeVolume(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent/100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0 || slPriceDistance <= 0)
      return(0);

   double lossPerLot = (slPriceDistance / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return(0);

   double lots = riskMoney / lossPerLot;
   return NormalizeVolume(lots);
  }

double NormalizeVolume(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;

   lots = MathFloor(lots/stepLot) * stepLot;
   if(InpMaxLot > 0) lots = MathMin(lots, InpMaxLot);
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   // round to step decimals to avoid float noise
   int stepDigits = (int)MathRound(-MathLog10(stepLot));
   if(stepDigits < 0) stepDigits = 0;
   return NormalizeDouble(lots, stepDigits);
  }

double EnforceMinStop(double slDist)
  {
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double brokerMin = stopsLevel * g_point;
   double userMin   = InpMinStopPoints * g_point;
   double floorDist = MathMax(brokerMin, userMin);
   // also never let SL be absurdly tiny relative to spread
   double spreadDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_point;
   floorDist = MathMax(floorDist, spreadDist*2.0);
   return MathMax(slDist, floorDist);
  }

//==================================================================//
//                     DAY / SAFETY STATE                           //
//==================================================================//
void UpdateDayState()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_today)
     {
      ResetDayCounters();
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }

   // Daily loss guard (includes floating PnL — conservative)
   if(InpMaxDailyLossPct > 0 && g_dayStartEquity > 0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double lossPct = (g_dayStartEquity - equity)/g_dayStartEquity*100.0;
      if(lossPct >= InpMaxDailyLossPct && !g_dayBlocked)
        {
         g_dayBlocked = true;
         PrintFormat("DAILY LOSS LIMIT hit (%.2f%% >= %.2f%%). No new trades today.",
                     lossPct, InpMaxDailyLossPct);
        }
     }
  }

void ResetDayCounters()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_today       = dt.day_of_year;
   g_tradesToday = 0;
   g_dayBlocked  = false;
  }

//==================================================================//
//                          FILTERS                                 //
//==================================================================//
bool InSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpStartHour == InpEndHour) return(true);          // 24h
   if(InpStartHour < InpEndHour)
      return(h >= InpStartHour && h < InpEndHour);
   // wraps midnight
   return(h >= InpStartHour || h < InpEndHour);
  }

bool SpreadOK()
  {
   long   spreadPts   = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPrice = (double)spreadPts * g_point;

   // (1) Optional fixed points cap (digit-dependent — off by default).
   if(InpMaxSpread > 0 && spreadPts > InpMaxSpread)
      return(false);

   // (2) Broker-agnostic cap: spread as a fraction of ATR (works for any digits).
   if(InpMaxSpreadATRpct > 0)
     {
      double atr = GetATR();
      if(atr > 0 && spreadPrice > atr * InpMaxSpreadATRpct/100.0)
         return(false);
     }
   return(true);
  }

//==================================================================//
//                         UTILITIES                                //
//==================================================================//
bool CopyBufSeries(int handle, int bufIndex, int count, double &dst[])
  {
   ArraySetAsSeries(dst, true);
   int copied = CopyBuffer(handle, bufIndex, 0, count, dst);
   return(copied >= count);
  }

double GetATR()
  {
   double atr[];
   if(!CopyBufSeries(hATR, 0, 2, atr)) return(0.0);
   return(atr[1] > 0 ? atr[1] : atr[0]); // last closed ATR
  }

double NormalizePrice(double price)
  {
   return NormalizeDouble(price, g_digits);
  }

int CountOurPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic)
         cnt++;
     }
   return(cnt);
  }

void CloseAllOurPositions(string reason)
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic)
        {
         if(trade.PositionClose(ticket))
            PrintFormat("Closed #%I64u (%s)", ticket, reason);
        }
     }
  }

//==================================================================//
//                         DASHBOARD                                //
//==================================================================//
void ShowDashboard()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPnL  = (g_dayStartEquity>0 ? equity - g_dayStartEquity : 0.0);
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   string s = StringFormat(
      "GoldPulse  |  %s %s\n"
      "-----------------------------------\n"
      "Equity:        %.2f %s\n"
      "Day P/L:       %.2f (start %.2f)\n"
      "Open (EA):     %d / %d\n"
      "Trades (today/total): %d / %I64d\n"
      "Spread:        %d pts  (filter: %s)\n"
      "Session:       %s\n"
      "Status:        %s",
      _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
      equity, AccountInfoString(ACCOUNT_CURRENCY),
      dayPnL, g_dayStartEquity,
      CountOurPositions(), InpMaxPositions,
      g_tradesToday, g_tradesTotal,
      (int)spread, (SpreadOK() ? "OK" : "TOO WIDE"),
      ((!InpUseSession || InSession()) ? "OPEN" : "CLOSED"),
      (g_dayBlocked ? "DAILY LOSS LIMIT - paused" : "active")
   );
   Comment(s);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                       XAUUSD_UltimateGold_EA.mq5  |
//|   "Ultimate Gold Trader v2" — MT5 port of the TradingView Pine    |
//|   strategy. Regime-switching auto-trader for gold (XAUUSD).       |
//|                                                                  |
//|   It reproduces the Pine logic 1:1 where MT5 allows:              |
//|     • TREND mode      (ADX>trend): EMA20/50 cross + 200 filter +   |
//|                        MACD + higher-timeframe (4H) bias           |
//|     • MEAN-REVERSION  (ADX<range): RSI extreme + Bollinger touch   |
//|     • BREAKOUT        (any regime): Donchian break + ATR expansion |
//|     • DIVERGENCE      RSI/price pivot divergence                   |
//|     • Confluence score gate (0-10), macro gate (DXY + US10Y),      |
//|       session + news gate, ATR risk, 3-stage scale-out + trailing  |
//|                                                                  |
//|   *** RISK WARNING ***                                            |
//|   No bot can guarantee profit. Gold + leverage can lose money     |
//|   fast. TEST ON A DEMO ACCOUNT for weeks before risking a cent.   |
//|   This is educational software, not financial advice.             |
//+------------------------------------------------------------------+
#property copyright "Ultimate Gold Trader v2 (MT5 port)"
#property version   "1.00"

#include <Trade/Trade.mqh>

//============================ INPUTS ================================
input group "=== General ==="
input long            Magic        = 770077;        // Magic number (unique per chart)
input int             Deviation    = 30;            // Max slippage (points)
input string          TradeComment = "UGTv2";       // Order comment

input group "=== Trend ==="
input int             EmaFast      = 20;            // EMA fast
input int             EmaSlow      = 50;            // EMA slow
input int             EmaTrend     = 200;           // EMA trend filter

input group "=== Higher timeframe bias ==="
input bool            UseHTF       = true;          // Require higher-timeframe alignment
input ENUM_TIMEFRAMES HTF          = PERIOD_H4;     // Higher timeframe (Pine default 4H)

input group "=== Regime detection (ADX) ==="
input int             AdxLen       = 14;            // ADX length
input double          AdxTrendTh   = 25.0;          // ADX > this  => TRENDING
input double          AdxRangeTh   = 20.0;          // ADX < this  => RANGING

input group "=== Mean reversion ==="
input int             RsiLen       = 14;            // RSI length
input int             RsiOB        = 70;            // RSI overbought
input int             RsiOS        = 30;            // RSI oversold
input int             BbLen        = 20;            // Bollinger length
input double          BbMult       = 2.0;           // Bollinger multiplier

input group "=== Breakout ==="
input int             DonchLen     = 20;            // Donchian length

input group "=== Divergence ==="
input bool            UseDivergence= true;          // Use RSI/price pivot divergence
input int             PivotLeft    = 5;             // Pivot left bars
input int             PivotRight   = 5;             // Pivot right bars (confirmation lag)
input int             DivLookback  = 250;           // Bars scanned for pivots

input group "=== Macro filter (broker symbol names vary!) ==="
input bool            UseDXY       = true;          // Gate by US Dollar Index (inverse)
input string          DXYSymbol    = "DXY";         // DXY symbol on YOUR broker (e.g. USDX, DX)
input bool            UseYields    = true;          // Gate by US10Y yield (inverse)
input string          YieldSymbol  = "US10Y";       // US10Y symbol on YOUR broker
// NOTE: if the symbol is missing/empty on your broker the filter PASSES (never blocks).

input group "=== Confluence gate ==="
input int             MinScore     = 6;             // Min confluence score (0-10) to trade

input group "=== Session / news (SERVER time, 24h) ==="
input bool            UseSession   = false;         // Restrict trading hours (OFF by default)
input int             SessStart    = 7;             // Session start hour (server time)
input int             SessEnd      = 17;            // Session end hour (server time)
input bool            UseNewsBlk   = false;         // Block trading inside news windows
input int             News1Start   = 12;            // News window 1 start hour
input int             News1End     = 14;            // News window 1 end hour
input int             News2Start   = 18;            // News window 2 start hour
input int             News2End     = 19;            // News window 2 end hour

input group "=== Risk & exits ==="
input int             AtrLen       = 14;            // ATR length
input double          AtrMultSL    = 1.5;           // Stop loss = ATR x this
input double          RR_TP1       = 1.0;           // TP1 (R multiple) — close 1/3
input double          RR_TP2       = 2.0;           // TP2 (R multiple) — close 1/3
input double          RR_TP3       = 3.0;           // TP3 (R multiple) — close runner
input double          RiskPctEq    = 1.0;           // Risk per trade (% of equity)
input bool            UseTrail     = true;          // Trail runner with ATR after TP2
input double          TrailAtrMult = 1.0;           // Post-TP2 trail = ATR x this
input bool            UseVolSizing = true;          // Shrink size in HIGH-vol regime
input double          HighVolScale = 0.5;           // HIGH-vol size multiplier

input group "=== Direction ==="
input bool            AllowLong    = true;          // Allow long trades
input bool            AllowShort   = true;          // Allow short trades

input group "=== Safety rails ==="
input int             MaxSpreadPts = 500;           // Skip entry if spread wider (points)
input double          MaxDailyLoss = 5.0;           // Stop new trades after -X% on the day
input double          MaxDrawdown  = 20.0;          // HALT all new trades after -X% from peak

//========================== GLOBALS ================================
CTrade trade;

int hEmaF, hEmaS, hEmaT, hHtfF, hHtfS, hADX, hMACD, hRSI, hBands, hATR;
int hDXYema=INVALID_HANDLE, hYldEma=INVALID_HANDLE;
bool g_dxyOK=false, g_yldOK=false;

datetime g_lastBar  = 0;
double   g_peakEq   = 0.0;
double   g_dayAnchor= 0.0;
int      g_curDay   = -1;
bool     g_halted   = false;

// daily VWAP accumulators
int      g_vwapDay  = -1;
double   g_cumPV    = 0.0;
double   g_cumVol   = 0.0;

// divergence "trigger" memory (state on previous bar)
bool     g_prevBull = false;
bool     g_prevBear = false;

// open-position state (single position; Pine pyramiding=0)
ulong    g_ticket   = 0;
int      g_dir      = 0;
double   g_entry=0, g_initLots=0, g_tp1=0, g_tp2=0, g_tp3=0, g_slInit=0, g_atrEntry=0;
int      g_stage    = 0;            // 0=full, 1=after TP1, 2=after TP2 (trailing)

//============================ INIT =================================
int OnInit()
{
   hEmaF  = iMA(_Symbol,_Period,EmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaS  = iMA(_Symbol,_Period,EmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hEmaT  = iMA(_Symbol,_Period,EmaTrend,0,MODE_EMA,PRICE_CLOSE);
   hHtfF  = iMA(_Symbol,HTF,EmaFast,0,MODE_EMA,PRICE_CLOSE);
   hHtfS  = iMA(_Symbol,HTF,EmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hADX   = iADX(_Symbol,_Period,AdxLen);
   hMACD  = iMACD(_Symbol,_Period,12,26,9,PRICE_CLOSE);
   hRSI   = iRSI(_Symbol,_Period,RsiLen,PRICE_CLOSE);
   hBands = iBands(_Symbol,_Period,BbLen,0,BbMult,PRICE_CLOSE);
   hATR   = iATR(_Symbol,_Period,AtrLen);

   if(hEmaF==INVALID_HANDLE || hEmaS==INVALID_HANDLE || hEmaT==INVALID_HANDLE ||
      hHtfF==INVALID_HANDLE || hHtfS==INVALID_HANDLE || hADX==INVALID_HANDLE ||
      hMACD==INVALID_HANDLE || hRSI==INVALID_HANDLE || hBands==INVALID_HANDLE ||
      hATR==INVALID_HANDLE)
   {
      Print("Failed to create one or more core indicator handles");
      return(INIT_FAILED);
   }

   // Macro symbols are optional — gracefully disable if unavailable.
   g_dxyOK = SetupMacro(UseDXY, DXYSymbol, hDXYema, "DXY");
   g_yldOK = SetupMacro(UseYields, YieldSymbol, hYldEma, "US10Y");

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Deviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_peakEq    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayAnchor = g_peakEq;

   PrintFormat("Ultimate Gold Trader v2 ready on %s %s | DXY:%s US10Y:%s",
               _Symbol, EnumToString(_Period),
               (g_dxyOK?"on":"off"), (g_yldOK?"on":"off"));
   return(INIT_SUCCEEDED);
}

// Try to enable a macro symbol + its EMA handle. Returns false (filter off) if missing.
bool SetupMacro(bool use, string sym, int &emaHandle, string label)
{
   if(!use || StringLen(sym)==0) return false;
   if(!SymbolSelect(sym,true))
   {
      PrintFormat("WARNING: macro symbol '%s' (%s) not found on broker -> filter disabled", sym, label);
      return false;
   }
   emaHandle = iMA(sym,_Period,20,0,MODE_EMA,PRICE_CLOSE);
   if(emaHandle==INVALID_HANDLE)
   {
      PrintFormat("WARNING: could not build EMA on '%s' (%s) -> filter disabled", sym, label);
      return false;
   }
   return true;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hEmaF);  IndicatorRelease(hEmaS);  IndicatorRelease(hEmaT);
   IndicatorRelease(hHtfF);  IndicatorRelease(hHtfS);  IndicatorRelease(hADX);
   IndicatorRelease(hMACD);  IndicatorRelease(hRSI);   IndicatorRelease(hBands);
   IndicatorRelease(hATR);
   if(hDXYema!=INVALID_HANDLE) IndicatorRelease(hDXYema);
   if(hYldEma!=INVALID_HANDLE) IndicatorRelease(hYldEma);
}

//===================== OPTIMIZATION CRITERION ======================
// Pick "Custom max" in the Strategy Tester to use this. Rewards PROFIT and
// low DRAWDOWN (never win rate) and needs >=30 trades, so the optimizer can't
// cheat with the high-win-rate / huge-stop trap.
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double ddPct  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   if(trades < 30 || profit <= 0.0) return 0.0;
   double denom = (ddPct > 0.0 ? ddPct : 1.0);
   return (profit / denom) * pf;
}

//============================ TICK =================================
void OnTick()
{
   // Manage scale-out + trailing on every tick (price-sensitive).
   ManageOpenPosition();

   // Signal logic only on a new bar.
   datetime t = iTime(_Symbol,_Period,0);
   if(t == g_lastBar) return;
   g_lastBar = t;

   if(Bars(_Symbol,_Period) < MathMax(EmaTrend, DivLookback) + 10) return;

   UpdateRiskState();
   UpdateVWAP();

   if(g_halted){ Comment("HALTED: max drawdown reached. No new trades."); return; }

   // ---- evaluate the strategy --------------------------------------
   int    dir   = 0;
   int    sLong = 0, sShort = 0;
   string regime= "";
   dir = EvaluateSignal(sLong, sShort, regime);

   Comment(StringFormat("UGTv2 | Regime:%s  ScoreL:%d ScoreR:%d (min %d)  Dir:%s",
           regime, sLong, sShort, MinScore,
           (dir>0?"LONG":dir<0?"SHORT":"flat")));

   // ---- safety + flat checks ---------------------------------------
   if(dir==0) return;
   if(CountMyPositions() > 0) return;                 // pyramiding 0 -> only enter when flat
   if(SpreadTooWide())        return;
   if(DailyLossHit())         return;

   // ---- size & execute ---------------------------------------------
   double atr = GetBuf(hATR,0,1);
   if(Bad(atr) || atr<=0) return;
   OpenTrade(dir, atr);
}

//====================== STRATEGY EVALUATION ========================
// Returns +1 long / -1 short / 0 none, and fills the confluence scores.
int EvaluateSignal(int &scoreLong, int &scoreShort, string &regimeStr)
{
   double c1  = iClose(_Symbol,_Period,1);
   double c2  = iClose(_Symbol,_Period,2);

   double emaF1=GetBuf(hEmaF,0,1), emaF2=GetBuf(hEmaF,0,2);
   double emaS1=GetBuf(hEmaS,0,1);
   double emaT1=GetBuf(hEmaT,0,1);
   if(Bad(emaF1)||Bad(emaS1)||Bad(emaT1)) return 0;

   double htfF=GetBuf(hHtfF,0,0), htfS=GetBuf(hHtfS,0,0);
   bool htfBull = (!Bad(htfF)&&!Bad(htfS)&&htfF>htfS);
   bool htfBear = (!Bad(htfF)&&!Bad(htfS)&&htfF<htfS);

   double adx=GetBuf(hADX,0,1);
   bool isTrending = (!Bad(adx)&&adx>AdxTrendTh);
   bool isRanging  = (!Bad(adx)&&adx<AdxRangeTh);
   regimeStr = isTrending ? "TRENDING" : isRanging ? "RANGING" : "TRANSITION";

   double mMain=GetBuf(hMACD,0,1), mSig=GetBuf(hMACD,1,1);
   bool macdBull = (!Bad(mMain)&&!Bad(mSig)&&mMain>mSig&&mMain>0);
   bool macdBear = (!Bad(mMain)&&!Bad(mSig)&&mMain<mSig&&mMain<0);

   double rsi=GetBuf(hRSI,0,1);

   double bbMid=GetBuf(hBands,0,1), bbUp=GetBuf(hBands,1,1), bbDn=GetBuf(hBands,2,1);

   // Donchian (highest/lowest of previous DonchLen bars, shifted by 1 like Pine)
   double donchUp1 = HighestHigh(2, DonchLen);   // value on last closed bar
   double donchUp2 = HighestHigh(3, DonchLen);   // value on the bar before
   double donchDn1 = LowestLow(2,  DonchLen);
   double donchDn2 = LowestLow(3,  DonchLen);

   // ATR regime + volatility expansion
   double atrCur = GetBuf(hATR,0,1);
   double atrAvg = SmaOfBuffer(hATR, 1, 20);
   double atrLong= SmaOfBuffer(hATR, 1, 100);
   bool   volExp = (!Bad(atrCur)&&!Bad(atrAvg)&&atrCur>atrAvg);
   double volRatio = (atrLong>0 ? atrCur/atrLong : 1.0);
   string volRegime = (volRatio<0.8 ? "LOW" : volRatio>1.4 ? "HIGH" : "NORMAL");

   // Macro state
   bool dxyFalling=false, dxyRising=false, yldFalling=false, yldRising=false;
   if(g_dxyOK) MacroState(hDXYema, DXYSymbol, dxyFalling, dxyRising);
   if(g_yldOK) MacroState(hYldEma, YieldSymbol, yldFalling, yldRising);

   double vwap = (g_cumVol>0 ? g_cumPV/g_cumVol : EMPTY_VALUE);
   bool vwapValid = !Bad(vwap);

   // ---- raw signal components --------------------------------------
   bool htfOkLong  = (!UseHTF || htfBull);
   bool htfOkShort = (!UseHTF || htfBear);

   bool crossUpEmaF   = (c2<=emaF2 && c1>emaF1);
   bool crossDnEmaF   = (c2>=emaF2 && c1<emaF1);
   bool crossUpDonch  = (c2<=donchUp2 && c1>donchUp1);
   bool crossDnDonch  = (c2>=donchDn2 && c1<donchDn1);

   bool trendLong  = isTrending && c1>emaT1 && emaF1>emaS1 && macdBull && htfOkLong  && crossUpEmaF;
   bool trendShort = isTrending && c1<emaT1 && emaF1<emaS1 && macdBear && htfOkShort && crossDnEmaF;
   bool mrLong     = isRanging  && !Bad(rsi) && rsi<RsiOS && !Bad(bbDn) && c1<bbDn;
   bool mrShort    = isRanging  && !Bad(rsi) && rsi>RsiOB && !Bad(bbUp) && c1>bbUp;
   bool brLong     = crossUpDonch && volExp && htfOkLong;
   bool brShort    = crossDnDonch && volExp && htfOkShort;

   // Divergence (pivot based) + "just turned true" trigger
   bool bullDiv=false, bearDiv=false;
   if(UseDivergence) DetectDivergence(bullDiv, bearDiv);
   bool bullDivTrig = bullDiv && !g_prevBull;
   bool bearDivTrig = bearDiv && !g_prevBear;
   g_prevBull = bullDiv;
   g_prevBear = bearDiv;

   bool rawLong  = trendLong  || mrLong  || brLong  || bullDivTrig;
   bool rawShort = trendShort || mrShort || brShort || bearDivTrig;

   // ---- confluence score (0-10), mirrors Pine -----------------------
   int sL=0, sR=0;
   sL += htfBull?1:0;                                sR += htfBear?1:0;
   sL += (c1>emaT1)?1:0;                             sR += (c1<emaT1)?1:0;
   sL += (emaF1>emaS1)?1:0;                          sR += (emaF1<emaS1)?1:0;
   sL += macdBull?1:0;                               sR += macdBear?1:0;
   sL += (!Bad(rsi)&&rsi>40&&rsi<70)?1:0;            sR += (!Bad(rsi)&&rsi<60&&rsi>30)?1:0;
   sL += dxyFalling?1:0;                             sR += dxyRising?1:0;
   sL += yldFalling?1:0;                             sR += yldRising?1:0;
   sL += (!Bad(adx)&&adx>20)?1:0;                    sR += (!Bad(adx)&&adx>20)?1:0;
   sL += (vwapValid&&c1>vwap)?1:0;                   sR += (vwapValid&&c1<vwap)?1:0;
   sL += (volRegime!="LOW")?1:0;                     sR += (volRegime!="LOW")?1:0;
   scoreLong=sL; scoreShort=sR;

   // ---- gates -------------------------------------------------------
   bool canTrade  = (!UseSession || SessionOK()) && !(UseNewsBlk && InBlackout());
   bool dxyOkLong = (!UseDXY || !g_dxyOK || dxyFalling);
   bool dxyOkShort= (!UseDXY || !g_dxyOK || dxyRising);
   bool yldOkLong = (!UseYields || !g_yldOK || yldFalling);
   bool yldOkShort= (!UseYields || !g_yldOK || yldRising);

   bool longOK  = canTrade && dxyOkLong  && yldOkLong  && sL>=MinScore && AllowLong;
   bool shortOK = canTrade && dxyOkShort && yldOkShort && sR>=MinScore && AllowShort;

   bool longSignal  = rawLong  && longOK;
   bool shortSignal = rawShort && shortOK;

   if(longSignal && shortSignal) return (sL>=sR ? 1 : -1);   // both: take stronger score
   if(longSignal)  return 1;
   if(shortSignal) return -1;
   return 0;
}

// RSI/price pivot divergence over the last DivLookback bars.
void DetectDivergence(bool &bullDiv, bool &bearDiv)
{
   bullDiv=false; bearDiv=false;
   int need = DivLookback;
   double low[], high[], rsi[];
   ArraySetAsSeries(low,true); ArraySetAsSeries(high,true); ArraySetAsSeries(rsi,true);
   if(CopyLow(_Symbol,_Period,0,need,low)   <= 0) return;
   if(CopyHigh(_Symbol,_Period,0,need,high) <= 0) return;
   if(CopyBuffer(hRSI,0,0,need,rsi)         <= 0) return;
   int n = MathMin(ArraySize(low), MathMin(ArraySize(high), ArraySize(rsi)));

   double lastLP,prevLP,lastLR,prevLR, lastHP,prevHP,lastHR,prevHR;
   bool plOK = LastTwoPivots(low, n, PivotLeft, PivotRight, true,  lastLP, prevLP);
   bool prOK = LastTwoPivots(rsi, n, PivotLeft, PivotRight, true,  lastLR, prevLR);
   bool phOK = LastTwoPivots(high,n, PivotLeft, PivotRight, false, lastHP, prevHP);
   bool hrOK = LastTwoPivots(rsi, n, PivotLeft, PivotRight, false, lastHR, prevHR);

   if(plOK && prOK) bullDiv = (lastLP<prevLP && lastLR>prevLR);  // lower low, higher RSI low
   if(phOK && hrOK) bearDiv = (lastHP>prevHP && lastHR<prevHR);  // higher high, lower RSI high
}

// Find the two most recent confirmed pivots in a series-indexed array.
// wantLow=true -> pivot lows; false -> pivot highs. Returns false if <2 found.
bool LastTwoPivots(const double &arr[], int total, int L, int R, bool wantLow,
                   double &recent, double &older)
{
   int found=0;
   for(int s=R+1; s+L<=total-1 && found<2; s++)
   {
      bool isPivot=true;
      for(int k=s-R; k<=s+L && isPivot; k++)
      {
         if(k==s) continue;
         if(wantLow){ if(arr[k] <= arr[s]) isPivot=false; }
         else       { if(arr[k] >= arr[s]) isPivot=false; }
      }
      if(isPivot)
      {
         if(found==0) recent=arr[s]; else older=arr[s];
         found++;
         s += L;   // skip the confirmation window so we don't double-count a flat pivot
      }
   }
   return (found==2);
}

//====================== TRADE EXECUTION ============================
void OpenTrade(int dir, double atr)
{
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price = (dir>0 ? ask : bid);

   double slDist = atr*AtrMultSL;
   double minDist = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(slDist < minDist) slDist = minDist;

   double sl, tp1, tp2, tp3;
   if(dir>0)
   {
      sl  = price - slDist;
      tp1 = price + slDist*RR_TP1;
      tp2 = price + slDist*RR_TP2;
      tp3 = price + slDist*RR_TP3;
   }
   else
   {
      sl  = price + slDist;
      tp1 = price - slDist*RR_TP1;
      tp2 = price - slDist*RR_TP2;
      tp3 = price - slDist*RR_TP3;
   }
   sl  = NormalizeDouble(sl,_Digits);
   tp3 = NormalizeDouble(tp3,_Digits);

   double lots = CalcLots(slDist);
   if(UseVolSizing)
   {
      double atrLong = SmaOfBuffer(hATR,1,100);
      double atrCur  = GetBuf(hATR,0,1);
      double ratio   = (atrLong>0 ? atrCur/atrLong : 1.0);
      if(ratio > 1.4) lots *= HighVolScale;          // HIGH-vol regime -> shrink
   }
   lots = NormalizeLots(lots);
   if(lots<=0){ Print("Lot size came out 0 - skipping trade"); return; }

   // Broker TP set at TP3 so the runner always has a hard exit; TP1/TP2 are managed manually.
   bool ok = (dir>0) ? trade.Buy(lots,_Symbol,ask,sl,tp3,TradeComment)
                     : trade.Sell(lots,_Symbol,bid,sl,tp3,TradeComment);
   if(!ok)
   {
      PrintFormat("Order FAILED: %s (retcode %d)",
                  trade.ResultRetcodeDescription(), trade.ResultRetcode());
      return;
   }

   // Record state for scale-out management.
   g_ticket   = GetMyPositionTicket();
   g_dir      = dir;
   g_entry    = price;
   g_initLots = lots;
   g_slInit   = sl;
   g_tp1=tp1; g_tp2=tp2; g_tp3=tp3;
   g_atrEntry = atr;
   g_stage    = 0;
   PrintFormat("OPEN %s %.2f lots @ %.2f  SL=%.2f  TP1=%.2f TP2=%.2f TP3=%.2f",
               (dir>0?"BUY":"SELL"), lots, price, sl, tp1, tp2, tp3);
}

//================== POSITION MANAGEMENT (scale-out) ================
void ManageOpenPosition()
{
   // Adopt an existing position after a restart so we never leave one unmanaged.
   if(g_ticket==0)
   {
      if(!AdoptExistingPosition()) return;
   }
   if(!PositionSelectByTicket(g_ticket)){ ResetPosState(); return; }
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
      PositionGetInteger(POSITION_MAGIC)!=Magic){ ResetPosState(); return; }

   double atr = GetBuf(hATR,0,1);
   if(Bad(atr) || atr<=0) atr = g_atrEntry;

   double curSL = PositionGetDouble(POSITION_SL);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   double part  = NormalizeLots(g_initLots/3.0);
   double minLot= SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   if(g_dir>0)
   {
      double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(g_stage==0 && bid>=g_tp1)
      {
         if(part>=minLot && vol>part+1e-8) trade.PositionClosePartial(g_ticket,part);
         MoveSL(g_entry);                              // SL -> breakeven
         g_stage=1;
      }
      else if(g_stage==1 && bid>=g_tp2)
      {
         if(part>=minLot && vol>part+1e-8) trade.PositionClosePartial(g_ticket,part);
         g_stage=2;
      }
      else if(g_stage>=2 && UseTrail)
      {
         double nsl = NormalizeDouble(bid-atr*TrailAtrMult,_Digits);
         if(nsl>curSL+_Point && nsl>=g_entry && nsl<bid) MoveSL(nsl);
      }
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(g_stage==0 && ask<=g_tp1)
      {
         if(part>=minLot && vol>part+1e-8) trade.PositionClosePartial(g_ticket,part);
         MoveSL(g_entry);
         g_stage=1;
      }
      else if(g_stage==1 && ask<=g_tp2)
      {
         if(part>=minLot && vol>part+1e-8) trade.PositionClosePartial(g_ticket,part);
         g_stage=2;
      }
      else if(g_stage>=2 && UseTrail)
      {
         double nsl = NormalizeDouble(ask+atr*TrailAtrMult,_Digits);
         if((curSL==0 || nsl<curSL-_Point) && nsl<=g_entry && nsl>ask) MoveSL(nsl);
      }
   }
}

void MoveSL(double newSL)
{
   if(!PositionSelectByTicket(g_ticket)) return;
   double tp = PositionGetDouble(POSITION_TP);
   newSL = NormalizeDouble(newSL,_Digits);
   trade.PositionModify(g_ticket, newSL, tp);
}

bool AdoptExistingPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)   continue;

      g_ticket   = tk;
      g_dir      = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1);
      g_entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_initLots = PositionGetDouble(POSITION_VOLUME);
      double atr = GetBuf(hATR,0,1); if(Bad(atr)||atr<=0) atr=(g_atrEntry>0?g_atrEntry:1.0);
      g_atrEntry = atr;
      double slDist = atr*AtrMultSL;
      if(g_dir>0){ g_tp1=g_entry+slDist*RR_TP1; g_tp2=g_entry+slDist*RR_TP2; g_tp3=g_entry+slDist*RR_TP3; }
      else       { g_tp1=g_entry-slDist*RR_TP1; g_tp2=g_entry-slDist*RR_TP2; g_tp3=g_entry-slDist*RR_TP3; }
      g_stage = 0;                       // unknown -> manage from scratch (safe)
      return true;
   }
   return false;
}

void ResetPosState()
{
   g_ticket=0; g_dir=0; g_entry=0; g_initLots=0;
   g_tp1=0; g_tp2=0; g_tp3=0; g_slInit=0; g_atrEntry=0; g_stage=0;
}

ulong GetMyPositionTicket()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==Magic) return tk;
   }
   return 0;
}

//====================== RISK MANAGEMENT ============================
void UpdateRiskState()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   if(tm.day != g_curDay){ g_curDay=tm.day; g_dayAnchor=eq; }
   if(eq > g_peakEq) g_peakEq = eq;
   if(g_peakEq>0 && eq <= g_peakEq*(1.0-MaxDrawdown/100.0)) g_halted=true;
}

void UpdateVWAP()
{
   // Accumulate typical-price * tick-volume since the start of the server day,
   // updated once per closed bar (shift 1). Resets when the calendar day changes.
   datetime bt = iTime(_Symbol,_Period,1);
   MqlDateTime tm; TimeToStruct(bt,tm);
   double tp  = (iHigh(_Symbol,_Period,1)+iLow(_Symbol,_Period,1)+iClose(_Symbol,_Period,1))/3.0;
   double vol = (double)iTickVolume(_Symbol,_Period,1);
   if(vol<=0) vol = 1.0;
   if(tm.day != g_vwapDay){ g_vwapDay=tm.day; g_cumPV=tp*vol; g_cumVol=vol; }
   else                   { g_cumPV+=tp*vol; g_cumVol+=vol; }
}

bool DailyLossHit()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (g_dayAnchor>0 && eq <= g_dayAnchor*(1.0-MaxDailyLoss/100.0));
}

bool SessionOK()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   int h=tm.hour;
   if(SessStart<=SessEnd) return (h>=SessStart && h<SessEnd);
   return (h>=SessStart || h<SessEnd);
}

bool InBlackout()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   int h=tm.hour;
   bool w1 = (News1Start<=News1End) ? (h>=News1Start && h<News1End) : (h>=News1Start || h<News1End);
   bool w2 = (News2Start<=News2End) ? (h>=News2Start && h<News2End) : (h>=News2Start || h<News2End);
   return (w1 || w2);
}

bool SpreadTooWide()
{
   return (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) > MaxSpreadPts);
}

int CountMyPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==Magic) c++;
   }
   return c;
}

double CalcLots(double slDistance)
{
   double tickVal = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSz<=0 || tickVal<=0 || slDistance<=0) return 0;

   double riskMoney  = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPctEq/100.0;
   double lossPerLot = (slDistance/tickSz) * tickVal;
   if(lossPerLot<=0) return 0;
   return riskMoney / lossPerLot;
}

double NormalizeLots(double lots)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step>0) lots = MathFloor(lots/step)*step;
   if(lots<minLot) lots=minLot;
   if(lots>maxLot) lots=maxLot;
   return lots;
}

//============================ HELPERS ==============================
double GetBuf(int handle, int bufferIndex, int shift)
{
   double tmp[];
   if(CopyBuffer(handle, bufferIndex, shift, 1, tmp) <= 0) return EMPTY_VALUE;
   return tmp[0];
}

double SmaOfBuffer(int handle, int startShift, int period)
{
   double tmp[];
   if(CopyBuffer(handle, 0, startShift, period, tmp) < period) return EMPTY_VALUE;
   double s=0; for(int i=0;i<period;i++) s+=tmp[i];
   return s/period;
}

double HighestHigh(int startShift, int count)
{
   double h[];
   if(CopyHigh(_Symbol,_Period,startShift,count,h) < count) return EMPTY_VALUE;
   double m=h[0]; for(int i=1;i<count;i++) if(h[i]>m) m=h[i];
   return m;
}

double LowestLow(int startShift, int count)
{
   double l[];
   if(CopyLow(_Symbol,_Period,startShift,count,l) < count) return EMPTY_VALUE;
   double m=l[0]; for(int i=1;i<count;i++) if(l[i]<m) m=l[i];
   return m;
}

// Read a macro symbol's close vs its EMA and report direction.
void MacroState(int emaHandle, string sym, bool &falling, bool &rising)
{
   falling=false; rising=false;
   double cl[]; double em = GetBufOf(emaHandle,1);
   if(Bad(em)) return;
   if(CopyClose(sym,_Period,1,1,cl) <= 0) return;
   falling = (cl[0] < em);
   rising  = (cl[0] > em);
}

double GetBufOf(int handle, int shift)
{
   double tmp[];
   if(CopyBuffer(handle,0,shift,1,tmp) <= 0) return EMPTY_VALUE;
   return tmp[0];
}

bool Bad(double v){ return (v==EMPTY_VALUE); }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                         XAUUSD_GoldMaster_EA.mq5  |
//|   ALL-IN-ONE gold (XAUUSD) Expert Advisor.                        |
//|                                                                  |
//|   Merges three engines into one bot. Each can be toggled on/off:  |
//|     ENGINE A — 12-indicator ensemble vote                         |
//|     ENGINE B — regime switch (trend / mean-rev / breakout /       |
//|                divergence) + confluence score + DXY/US10Y macro   |
//|                + higher-timeframe bias                            |
//|     ENGINE C — 4 quality-scored strategies (EMA / RSI / BB /      |
//|                intraday momentum)                                 |
//|   The enabled engines VOTE; the bot trades when enough agree.     |
//|                                                                  |
//|   Runs in "aggressive" mode: MANY positions allowed — but behind  |
//|   a REAL total-risk cap that actually sums open risk (the thing    |
//|   the old multi-strategy bot only pretended to do).               |
//|                                                                  |
//|   *** RISK WARNING ***                                            |
//|   No bot guarantees profit. Many positions + leverage on gold can |
//|   draw down hard and fast. TEST ON DEMO for weeks first. This is  |
//|   educational software, not financial advice.                     |
//+------------------------------------------------------------------+
#property copyright "Gold Master EA (unified)"
#property version   "1.00"

#include <Trade/Trade.mqh>

//============================ INPUTS ================================
input group "=== General ==="
input long            Magic         = 555001;       // Magic number (unique per chart)
input int             Deviation     = 30;           // Max slippage (points)
input string          TradeComment  = "GoldMaster"; // Order comment
input bool            TradeLong     = true;         // Allow long (BUY) trades
input bool            TradeShort    = true;         // Allow short (SELL) trades
input bool            DebugMode     = true;         // Print decision details to Experts tab

input group "=== Engine switches (turn parts on/off) ==="
input bool            UseEnsemble   = true;         // ENGINE A: 12-indicator vote
input bool            UseRegime     = true;         // ENGINE B: regime + confluence + macro
input bool            UseQuality    = true;         // ENGINE C: 4 quality strategies
input int             MinEnginesAgree = 1;          // How many engines must agree on direction (1-3)

input group "=== AGGRESSIVE position limits (with a REAL risk cap) ==="
input int             MaxConcurrent = 10;           // Max simultaneous positions
input double          MaxTotalRisk  = 20.0;         // *** REAL *** cap: total open risk % of balance
input int             MaxDailyTrades= 50;           // Max new trades per day
input int             MinBarsBetween= 1;            // Min new bars between entries (0 = every bar)

input group "=== Risk per trade & exits ==="
input double          RiskPerTrade  = 1.0;          // Risk per trade (% of balance)
input double          SL_ATR_Mult   = 1.5;          // Stop loss = ATR x this  (WIRED UP)
input bool            UseFixedTP    = true;         // Use a fixed take-profit
input double          RiskReward    = 2.0;          // TP = SL distance x this  (WIRED UP)
input bool            UseBreakeven  = true;         // Move SL to break-even in profit
input double          BE_ATR_Trigger= 1.0;          // Break-even after profit >= ATR x this
input bool            UseTrailing   = true;         // Trail the stop in profit
input double          Trail_ATR_Start = 1.5;        // Start trailing after profit >= ATR x this
input double          Trail_ATR_Mult  = 1.5;        // Trailing distance = ATR x this (SANE, not 1 point)

input group "=== Safety rails ==="
input int             MaxSpreadPts  = 500;          // Skip entry if spread wider (points)
input double          MaxDailyLoss  = 10.0;         // Stop new trades after -X% on the day
input double          MaxDrawdown   = 25.0;         // HALT new trades after -X% from equity peak
input bool            UseTimeFilter = false;        // Restrict trading hours (server time)
input int             StartHour     = 0;            // Session start hour
input int             EndHour       = 24;           // Session end hour

input group "=== ENGINE A: ensemble ==="
input int             EnsMinScore   = 4;            // Min |net vote| of the 12 indicators
input int             EnsMinAgree   = 6;            // Min indicators agreeing

input group "=== ENGINE B: regime ==="
input bool            UseHTF        = true;         // Require higher-timeframe alignment
input ENUM_TIMEFRAMES HTF           = PERIOD_H4;    // Higher timeframe
input double          AdxTrendTh    = 25.0;         // ADX > this => TRENDING
input double          AdxRangeTh    = 20.0;         // ADX < this => RANGING
input int             RsiOB         = 70;           // RSI overbought
input int             RsiOS         = 30;           // RSI oversold
input int             DonchLen      = 20;           // Donchian length
input bool            UseDivergence = true;         // RSI/price pivot divergence
input int             PivotLeft     = 5;            // Pivot left bars
input int             PivotRight    = 5;            // Pivot right bars
input int             DivLookback   = 250;          // Bars scanned for pivots
input int             RegMinScore   = 6;            // Min confluence score (0-10)
input bool            UseDXY        = true;         // Gate by US Dollar Index (inverse)
input string          DXYSymbol     = "DXY";        // DXY symbol on YOUR broker
input bool            UseYields     = true;         // Gate by US10Y yield (inverse)
input string          YieldSymbol   = "US10Y";      // US10Y symbol on YOUR broker

input group "=== ENGINE C: quality strategies ==="
input bool            EnableEMA     = true;         // EMA 9/21 crossover
input bool            EnableRSIs    = true;         // RSI momentum
input bool            EnableBB      = true;         // Bollinger bands
input bool            EnableMomentum= true;         // Intraday momentum
input double          MinQuality    = 65.0;         // Min signal quality (0-100)
input double          MomVolMult    = 1.5;          // Momentum min volatility multiplier

input group "=== Indicator periods (shared) ==="
input int             EmaQFast      = 9;            // Quality fast EMA
input int             EmaQSlow      = 21;           // Quality slow EMA
input int             EmaFast       = 20;           // Trend fast EMA
input int             EmaSlow       = 50;           // Trend slow EMA
input int             EmaTrend      = 200;          // Trend filter EMA
input int             RSI_Period    = 14;           // RSI period
input int             BB_Period     = 20;           // Bollinger period
input double          BB_Dev        = 2.0;          // Bollinger deviation
input int             ADX_Period    = 14;           // ADX period
input int             ATR_Period    = 14;           // ATR period
input int             Stoch_K       = 14;           // Stochastic %K
input int             Stoch_D       = 3;            // Stochastic %D
input int             Stoch_Slow    = 3;            // Stochastic slowing
input int             CCI_Period    = 20;           // CCI period
input int             WPR_Period    = 14;           // Williams %R period
input int             Ichi_Tenkan   = 9;            // Ichimoku Tenkan
input int             Ichi_Kijun    = 26;           // Ichimoku Kijun
input int             Ichi_Senkou   = 52;           // Ichimoku Senkou
input double          SAR_Step      = 0.02;         // Parabolic SAR step
input double          SAR_Max       = 0.2;          // Parabolic SAR max
input int             MFI_Period    = 14;           // MFI period
input int             ST_Period     = 10;           // Supertrend ATR period
input double          ST_Mult       = 3.0;          // Supertrend multiplier
input int             ST_Look       = 300;          // Supertrend lookback bars

//========================== GLOBALS ================================
CTrade trade;

// shared / engine handles
int hEmaQF,hEmaQS,hEmaF,hEmaS,hEmaT,hHtfF,hHtfS;
int hRSI,hBB,hADX,hATR,hMACD;
int hStoch,hCCI,hWPR,hIchi,hSAR,hMFI,hST;
int hDXYema=INVALID_HANDLE,hYldEma=INVALID_HANDLE;
bool g_dxyOK=false,g_yldOK=false;

datetime g_lastBar=0, g_lastEntryBar=0;
double   g_peakEq=0.0, g_dayAnchor=0.0;
int      g_curDay=-1, g_tradesToday=0;
bool     g_halted=false;

// daily VWAP accumulators (engine B)
int      g_vwapDay=-1;
double   g_cumPV=0.0, g_cumVol=0.0;

// divergence trigger memory (engine B)
bool     g_prevBull=false, g_prevBear=false;

struct SignalData { double quality; int direction; };

//============================ INIT =================================
int OnInit()
{
   hEmaQF = iMA(_Symbol,_Period,EmaQFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaQS = iMA(_Symbol,_Period,EmaQSlow,0,MODE_EMA,PRICE_CLOSE);
   hEmaF  = iMA(_Symbol,_Period,EmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaS  = iMA(_Symbol,_Period,EmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hEmaT  = iMA(_Symbol,_Period,EmaTrend,0,MODE_EMA,PRICE_CLOSE);
   hHtfF  = iMA(_Symbol,HTF,EmaFast,0,MODE_EMA,PRICE_CLOSE);
   hHtfS  = iMA(_Symbol,HTF,EmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hRSI   = iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);
   hBB    = iBands(_Symbol,_Period,BB_Period,0,BB_Dev,PRICE_CLOSE);
   hADX   = iADX(_Symbol,_Period,ADX_Period);
   hATR   = iATR(_Symbol,_Period,ATR_Period);
   hMACD  = iMACD(_Symbol,_Period,12,26,9,PRICE_CLOSE);
   hStoch = iStochastic(_Symbol,_Period,Stoch_K,Stoch_D,Stoch_Slow,MODE_SMA,STO_LOWHIGH);
   hCCI   = iCCI(_Symbol,_Period,CCI_Period,PRICE_TYPICAL);
   hWPR   = iWPR(_Symbol,_Period,WPR_Period);
   hIchi  = iIchimoku(_Symbol,_Period,Ichi_Tenkan,Ichi_Kijun,Ichi_Senkou);
   hSAR   = iSAR(_Symbol,_Period,SAR_Step,SAR_Max);
   hMFI   = iMFI(_Symbol,_Period,MFI_Period,VOLUME_TICK);
   hST    = iATR(_Symbol,_Period,ST_Period);

   if(hEmaQF==INVALID_HANDLE||hEmaQS==INVALID_HANDLE||hEmaF==INVALID_HANDLE||
      hEmaS==INVALID_HANDLE||hEmaT==INVALID_HANDLE||hHtfF==INVALID_HANDLE||
      hHtfS==INVALID_HANDLE||hRSI==INVALID_HANDLE||hBB==INVALID_HANDLE||
      hADX==INVALID_HANDLE||hATR==INVALID_HANDLE||hMACD==INVALID_HANDLE||
      hStoch==INVALID_HANDLE||hCCI==INVALID_HANDLE||hWPR==INVALID_HANDLE||
      hIchi==INVALID_HANDLE||hSAR==INVALID_HANDLE||hMFI==INVALID_HANDLE||
      hST==INVALID_HANDLE)
   {
      Print("Failed to create one or more indicator handles");
      return(INIT_FAILED);
   }

   g_dxyOK = SetupMacro(UseDXY, DXYSymbol, hDXYema, "DXY");
   g_yldOK = SetupMacro(UseYields, YieldSymbol, hYldEma, "US10Y");

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Deviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_peakEq    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayAnchor = g_peakEq;
   g_curDay    = -1;

   PrintFormat("GoldMaster EA ready on %s %s | Engines A:%s B:%s C:%s | DXY:%s US10Y:%s",
               _Symbol, EnumToString(_Period),
               (UseEnsemble?"on":"off"),(UseRegime?"on":"off"),(UseQuality?"on":"off"),
               (g_dxyOK?"on":"off"),(g_yldOK?"on":"off"));
   return(INIT_SUCCEEDED);
}

bool SetupMacro(bool use, string sym, int &emaHandle, string label)
{
   if(!use || StringLen(sym)==0) return false;
   if(!SymbolSelect(sym,true))
   {
      PrintFormat("WARNING: macro symbol '%s' (%s) not found -> filter disabled", sym, label);
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
   IndicatorRelease(hEmaQF); IndicatorRelease(hEmaQS); IndicatorRelease(hEmaF);
   IndicatorRelease(hEmaS);  IndicatorRelease(hEmaT);  IndicatorRelease(hHtfF);
   IndicatorRelease(hHtfS);  IndicatorRelease(hRSI);   IndicatorRelease(hBB);
   IndicatorRelease(hADX);   IndicatorRelease(hATR);   IndicatorRelease(hMACD);
   IndicatorRelease(hStoch); IndicatorRelease(hCCI);   IndicatorRelease(hWPR);
   IndicatorRelease(hIchi);  IndicatorRelease(hSAR);   IndicatorRelease(hMFI);
   IndicatorRelease(hST);
   if(hDXYema!=INVALID_HANDLE) IndicatorRelease(hDXYema);
   if(hYldEma!=INVALID_HANDLE) IndicatorRelease(hYldEma);
}

//===================== OPTIMIZATION CRITERION ======================
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
   DailyReset();
   ManageAllPositions();                       // stateless: BE + trailing for EVERY position

   datetime t = iTime(_Symbol,_Period,0);
   if(t == g_lastBar) return;                  // signals only on a new bar
   g_lastBar = t;

   if(Bars(_Symbol,_Period) < MathMax(EmaTrend, DivLookback) + 10) return;

   UpdateRiskState();
   UpdateVWAP();

   if(g_halted){ Comment("HALTED: max drawdown reached."); return; }
   if(UseTimeFilter && !SessionOK())   return;
   if(DailyLossHit())                  return;
   if(g_tradesToday >= MaxDailyTrades) return;
   if(MinBarsBetween>0 && (t - g_lastEntryBar) < MinBarsBetween*PeriodSeconds(_Period)) return;

   // ---- gather engine votes ----------------------------------------
   int dEns=0, dReg=0, dQual=0;
   int regScoreL=0, regScoreR=0; string regime="";
   if(UseEnsemble) dEns  = EngineEnsemble();
   if(UseRegime)   dReg  = EngineRegime(regScoreL, regScoreR, regime);
   if(UseQuality)  dQual = EngineQuality();

   int netVote = dEns + dReg + dQual;
   int dir = 0;
   if(MathAbs(netVote) >= MinEnginesAgree) dir = (netVote>0 ? 1 : -1);

   if(DebugMode)
      PrintFormat("Votes A:%d B:%d C:%d  net:%d  regime:%s scoreL:%d scoreR:%d  -> %s",
                  dEns,dReg,dQual,netVote,regime,regScoreL,regScoreR,
                  (dir>0?"LONG":dir<0?"SHORT":"flat"));
   Comment(StringFormat("GoldMaster | A:%d B:%d C:%d net:%d | %s | open:%d risk:%.1f%%",
           dEns,dReg,dQual,netVote,(dir>0?"LONG":dir<0?"SHORT":"flat"),
           CountMyPositions(), OpenRiskPct()));

   if(dir==0) return;
   if(dir>0 && !TradeLong)  return;
   if(dir<0 && !TradeShort) return;

   // ---- concurrency + spread + REAL total-risk cap -----------------
   if(CountMyPositions() >= MaxConcurrent){ if(DebugMode) Print("Max concurrent reached"); return; }
   if(SpreadTooWide()){ if(DebugMode) Print("Spread too wide"); return; }

   double atr = GetBuf(hATR,0,1);
   if(Bad(atr) || atr<=0) return;
   double slDist = atr*SL_ATR_Mult;
   double minDist= SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(slDist < minDist) slDist = minDist;

   double lots = NormalizeLots(CalcLots(slDist));
   if(lots<=0){ if(DebugMode) Print("Lots=0, skip"); return; }

   double addRiskPct = RiskMoney(slDist,lots) / AccountInfoDouble(ACCOUNT_BALANCE) * 100.0;
   if(OpenRiskPct() + addRiskPct > MaxTotalRisk)
   {
      if(DebugMode) PrintFormat("Total-risk cap: %.1f%% + %.1f%% > %.1f%% -> skip",
                                OpenRiskPct(), addRiskPct, MaxTotalRisk);
      return;
   }

   OpenTrade(dir, lots, slDist);
}

//====================== ENGINE A: ENSEMBLE =========================
int EngineEnsemble()
{
   int v[12]; int n=0; double score=0;
   double c1=iClose(_Symbol,_Period,1);

   double emaF=GetBuf(hEmaF,0,1), emaS=GetBuf(hEmaS,0,1);
   v[n++] = (Bad(emaF)||Bad(emaS))?0:(emaF>emaS?1:(emaF<emaS?-1:0));

   double mMain=GetBuf(hMACD,0,1), mSig=GetBuf(hMACD,1,1);
   v[n++] = (Bad(mMain)||Bad(mSig))?0:(mMain>mSig?1:(mMain<mSig?-1:0));

   double adx=GetBuf(hADX,0,1), pDI=GetBuf(hADX,1,1), mDI=GetBuf(hADX,2,1);
   int adxVote=0;
   if(!Bad(adx)&&adx>=AdxRangeTh&&!Bad(pDI)&&!Bad(mDI)) adxVote=(pDI>mDI?1:-1);
   v[n++]=adxVote;

   double rsi=GetBuf(hRSI,0,1);
   v[n++] = Bad(rsi)?0:(rsi>50?1:(rsi<50?-1:0));

   double stK=GetBuf(hStoch,0,1), stD=GetBuf(hStoch,1,1);
   v[n++] = (Bad(stK)||Bad(stD))?0:(stK>stD?1:(stK<stD?-1:0));

   double cci=GetBuf(hCCI,0,1);
   v[n++] = Bad(cci)?0:(cci>0?1:(cci<0?-1:0));

   double wpr=GetBuf(hWPR,0,1);
   v[n++] = Bad(wpr)?0:(wpr>-50?1:(wpr<-50?-1:0));

   double mid=GetBuf(hBB,0,1);
   v[n++] = Bad(mid)?0:(c1>mid?1:(c1<mid?-1:0));

   double ten=GetBuf(hIchi,0,1), kij=GetBuf(hIchi,1,1);
   int ichi=0;
   if(!Bad(ten)&&!Bad(kij)){ if(ten>kij&&c1>kij) ichi=1; else if(ten<kij&&c1<kij) ichi=-1; }
   v[n++]=ichi;

   double sar=GetBuf(hSAR,0,1);
   v[n++] = Bad(sar)?0:(sar<c1?1:(sar>c1?-1:0));

   v[n++] = SuperTrendDir();

   double mfi=GetBuf(hMFI,0,1);
   v[n++] = Bad(mfi)?0:(mfi>50?1:(mfi<50?-1:0));

   for(int i=0;i<n;i++) score+=v[i];
   int dir=(score>0?1:(score<0?-1:0));
   int agree=0; if(dir!=0) for(int i=0;i<n;i++) if(v[i]==dir) agree++;

   if(MathAbs(score) < EnsMinScore || agree < EnsMinAgree) return 0;
   return dir;
}

int SuperTrendDir()
{
   double high[],low[],close[],atr[];
   ArraySetAsSeries(high,false); ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false);ArraySetAsSeries(atr,false);
   if(CopyHigh(_Symbol,_Period,1,ST_Look,high)  <= 0) return 0;
   if(CopyLow(_Symbol,_Period,1,ST_Look,low)    <= 0) return 0;
   if(CopyClose(_Symbol,_Period,1,ST_Look,close)<= 0) return 0;
   if(CopyBuffer(hST,0,1,ST_Look,atr)           <= 0) return 0;
   int cnt=ArraySize(close); if(cnt<2) return 0;
   double prevUp=0,prevLow=0; int trend=1,prevTrend=1;
   for(int i=0;i<cnt;i++){
      double hl2=(high[i]+low[i])/2.0;
      double up=hl2+ST_Mult*atr[i], dn=hl2-ST_Mult*atr[i];
      if(i==0){ prevUp=up; prevLow=dn; trend=1; prevTrend=1; continue; }
      double fUp =(up<prevUp ||close[i-1]>prevUp )?up:prevUp;
      double fLow=(dn>prevLow||close[i-1]<prevLow)?dn:prevLow;
      if(close[i]>prevUp)       trend=1;
      else if(close[i]<prevLow) trend=-1;
      else                      trend=prevTrend;
      prevUp=fUp; prevLow=fLow; prevTrend=trend;
   }
   return trend;
}

//====================== ENGINE B: REGIME ===========================
int EngineRegime(int &scoreLong, int &scoreShort, string &regimeStr)
{
   scoreLong=0; scoreShort=0; regimeStr="";
   double c1=iClose(_Symbol,_Period,1), c2=iClose(_Symbol,_Period,2);
   double emaF1=GetBuf(hEmaF,0,1), emaF2=GetBuf(hEmaF,0,2);
   double emaS1=GetBuf(hEmaS,0,1), emaT1=GetBuf(hEmaT,0,1);
   if(Bad(emaF1)||Bad(emaS1)||Bad(emaT1)) return 0;

   double htfF=GetBuf(hHtfF,0,0), htfS=GetBuf(hHtfS,0,0);
   bool htfBull=(!Bad(htfF)&&!Bad(htfS)&&htfF>htfS);
   bool htfBear=(!Bad(htfF)&&!Bad(htfS)&&htfF<htfS);

   double adx=GetBuf(hADX,0,1);
   bool isTrending=(!Bad(adx)&&adx>AdxTrendTh);
   bool isRanging =(!Bad(adx)&&adx<AdxRangeTh);
   regimeStr = isTrending?"TREND":isRanging?"RANGE":"TRANS";

   double mMain=GetBuf(hMACD,0,1), mSig=GetBuf(hMACD,1,1);
   bool macdBull=(!Bad(mMain)&&!Bad(mSig)&&mMain>mSig&&mMain>0);
   bool macdBear=(!Bad(mMain)&&!Bad(mSig)&&mMain<mSig&&mMain<0);

   double rsi=GetBuf(hRSI,0,1);
   double bbUp=GetBuf(hBB,1,1), bbDn=GetBuf(hBB,2,1);

   double donchUp1=HighestHigh(2,DonchLen), donchUp2=HighestHigh(3,DonchLen);
   double donchDn1=LowestLow(2,DonchLen),   donchDn2=LowestLow(3,DonchLen);

   double atrCur=GetBuf(hATR,0,1);
   double atrAvg=SmaOfBuffer(hATR,1,20), atrLong=SmaOfBuffer(hATR,1,100);
   bool volExp=(!Bad(atrCur)&&!Bad(atrAvg)&&atrCur>atrAvg);
   double volRatio=(atrLong>0?atrCur/atrLong:1.0);
   bool volLow=(volRatio<0.8);

   bool dxyFall=false,dxyRise=false,yldFall=false,yldRise=false;
   if(g_dxyOK) MacroState(hDXYema,DXYSymbol,dxyFall,dxyRise);
   if(g_yldOK) MacroState(hYldEma,YieldSymbol,yldFall,yldRise);

   double vwap=(g_cumVol>0?g_cumPV/g_cumVol:EMPTY_VALUE);
   bool vwapValid=!Bad(vwap);

   bool htfOkLong =(!UseHTF||htfBull);
   bool htfOkShort=(!UseHTF||htfBear);
   bool crUpEmaF=(c2<=emaF2&&c1>emaF1), crDnEmaF=(c2>=emaF2&&c1<emaF1);
   bool crUpDon =(c2<=donchUp2&&c1>donchUp1), crDnDon=(c2>=donchDn2&&c1<donchDn1);

   bool trendLong  = isTrending&&c1>emaT1&&emaF1>emaS1&&macdBull&&htfOkLong &&crUpEmaF;
   bool trendShort = isTrending&&c1<emaT1&&emaF1<emaS1&&macdBear&&htfOkShort&&crDnEmaF;
   bool mrLong     = isRanging&&!Bad(rsi)&&rsi<RsiOS&&!Bad(bbDn)&&c1<bbDn;
   bool mrShort    = isRanging&&!Bad(rsi)&&rsi>RsiOB&&!Bad(bbUp)&&c1>bbUp;
   bool brLong     = crUpDon&&volExp&&htfOkLong;
   bool brShort    = crDnDon&&volExp&&htfOkShort;

   bool bullDiv=false,bearDiv=false;
   if(UseDivergence) DetectDivergence(bullDiv,bearDiv);
   bool bullTrig=bullDiv&&!g_prevBull, bearTrig=bearDiv&&!g_prevBear;
   g_prevBull=bullDiv; g_prevBear=bearDiv;

   bool rawLong  = trendLong||mrLong||brLong||bullTrig;
   bool rawShort = trendShort||mrShort||brShort||bearTrig;

   int sL=0,sR=0;
   sL+=htfBull?1:0;                         sR+=htfBear?1:0;
   sL+=(c1>emaT1)?1:0;                       sR+=(c1<emaT1)?1:0;
   sL+=(emaF1>emaS1)?1:0;                    sR+=(emaF1<emaS1)?1:0;
   sL+=macdBull?1:0;                         sR+=macdBear?1:0;
   sL+=(!Bad(rsi)&&rsi>40&&rsi<70)?1:0;      sR+=(!Bad(rsi)&&rsi<60&&rsi>30)?1:0;
   sL+=dxyFall?1:0;                          sR+=dxyRise?1:0;
   sL+=yldFall?1:0;                          sR+=yldRise?1:0;
   sL+=(!Bad(adx)&&adx>20)?1:0;              sR+=(!Bad(adx)&&adx>20)?1:0;
   sL+=(vwapValid&&c1>vwap)?1:0;             sR+=(vwapValid&&c1<vwap)?1:0;
   sL+=(!volLow)?1:0;                        sR+=(!volLow)?1:0;
   scoreLong=sL; scoreShort=sR;

   bool dxyOkL=(!UseDXY||!g_dxyOK||dxyFall), dxyOkS=(!UseDXY||!g_dxyOK||dxyRise);
   bool yldOkL=(!UseYields||!g_yldOK||yldFall), yldOkS=(!UseYields||!g_yldOK||yldRise);

   bool longSig  = rawLong &&dxyOkL&&yldOkL&&sL>=RegMinScore;
   bool shortSig = rawShort&&dxyOkS&&yldOkS&&sR>=RegMinScore;

   if(longSig&&shortSig) return (sL>=sR?1:-1);
   if(longSig)  return 1;
   if(shortSig) return -1;
   return 0;
}

void DetectDivergence(bool &bullDiv, bool &bearDiv)
{
   bullDiv=false; bearDiv=false;
   double low[],high[],rsi[];
   ArraySetAsSeries(low,true); ArraySetAsSeries(high,true); ArraySetAsSeries(rsi,true);
   if(CopyLow(_Symbol,_Period,0,DivLookback,low)  <=0) return;
   if(CopyHigh(_Symbol,_Period,0,DivLookback,high)<=0) return;
   if(CopyBuffer(hRSI,0,0,DivLookback,rsi)        <=0) return;
   int n=MathMin(ArraySize(low),MathMin(ArraySize(high),ArraySize(rsi)));
   double lLP,pLP,lLR,pLR,lHP,pHP,lHR,pHR;
   bool a=LastTwoPivots(low ,n,PivotLeft,PivotRight,true ,lLP,pLP);
   bool b=LastTwoPivots(rsi ,n,PivotLeft,PivotRight,true ,lLR,pLR);
   bool c=LastTwoPivots(high,n,PivotLeft,PivotRight,false,lHP,pHP);
   bool d=LastTwoPivots(rsi ,n,PivotLeft,PivotRight,false,lHR,pHR);
   if(a&&b) bullDiv=(lLP<pLP&&lLR>pLR);
   if(c&&d) bearDiv=(lHP>pHP&&lHR<pHR);
}

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
      if(isPivot){ if(found==0) recent=arr[s]; else older=arr[s]; found++; s+=L; }
   }
   return (found==2);
}

//====================== ENGINE C: QUALITY ==========================
int EngineQuality()
{
   SignalData best; best.quality=0; best.direction=0;
   double pDI=GetBuf(hADX,1,1), mDI=GetBuf(hADX,2,1);
   double adx=GetBuf(hADX,0,1);

   if(EnableEMA)      ConsiderSignal(best, QualEMA());
   if(EnableRSIs)     ConsiderSignal(best, QualRSI(pDI,mDI));
   if(EnableBB)       ConsiderSignal(best, QualBB(adx));
   if(EnableMomentum) ConsiderSignal(best, QualMomentum(pDI,mDI));

   if(best.direction!=0 && best.quality>=MinQuality) return best.direction;
   return 0;
}

void ConsiderSignal(SignalData &best, SignalData s)
{
   if(s.direction!=0 && s.quality>best.quality){ best.quality=s.quality; best.direction=s.direction; }
}

SignalData QualEMA()
{
   SignalData r; r.quality=0; r.direction=0;
   double f1=GetBuf(hEmaQF,0,1), f2=GetBuf(hEmaQF,0,2);
   double s1=GetBuf(hEmaQS,0,1), s2=GetBuf(hEmaQS,0,2);
   if(Bad(f1)||Bad(f2)||Bad(s1)||Bad(s2)) return r;
   if(f2<=s2 && f1>s1){ r.direction=1;  r.quality=72.0; if((f1-f2)/_Point>20) r.quality+=8.0; }
   else if(f2>=s2 && f1<s1){ r.direction=-1; r.quality=72.0; if((f2-f1)/_Point>20) r.quality+=8.0; }
   return r;
}

SignalData QualRSI(double pDI, double mDI)
{
   SignalData r; r.quality=0; r.direction=0;
   double r1=GetBuf(hRSI,0,1), r2=GetBuf(hRSI,0,2);
   if(Bad(r1)||Bad(r2)) return r;
   if(r2<RsiOS && r1>RsiOS && r1<50){ r.direction=1; r.quality=75.0; if(!Bad(pDI)&&!Bad(mDI)&&pDI>mDI) r.quality+=10.0; }
   else if(r2>RsiOB && r1<RsiOB && r1>50){ r.direction=-1; r.quality=75.0; if(!Bad(pDI)&&!Bad(mDI)&&mDI>pDI) r.quality+=10.0; }
   return r;
}

SignalData QualBB(double adx)
{
   SignalData r; r.quality=0; r.direction=0;
   double c1=iClose(_Symbol,_Period,1);
   double up=GetBuf(hBB,1,1), dn=GetBuf(hBB,2,1);   // 1=upper, 2=lower (correct order)
   if(Bad(up)||Bad(dn)) return r;
   if(c1<=dn){ r.direction=1;  r.quality=68.0; if(!Bad(adx)&&adx<25) r.quality+=10.0; }
   else if(c1>=up){ r.direction=-1; r.quality=68.0; if(!Bad(adx)&&adx<25) r.quality+=10.0; }
   return r;
}

SignalData QualMomentum(double pDI, double mDI)
{
   SignalData r; r.quality=0; r.direction=0;
   double atr=GetBuf(hATR,0,1);
   if(Bad(atr)) return r;
   if(atr/_Point < 200*MomVolMult) return r;
   double pDI2=GetBuf(hADX,1,2), mDI2=GetBuf(hADX,2,2);
   if(Bad(pDI)||Bad(mDI)||Bad(pDI2)||Bad(mDI2)) return r;
   if(pDI>mDI && pDI>25 && pDI>pDI2){ r.direction=1;  r.quality=65.0; if(pDI>30) r.quality+=10.0; }
   else if(mDI>pDI && mDI>25 && mDI>mDI2){ r.direction=-1; r.quality=65.0; if(mDI>30) r.quality+=10.0; }
   return r;
}

//====================== TRADE EXECUTION ============================
void OpenTrade(int dir, double lots, double slDist)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=(dir>0?ask:bid);

   double sl,tp=0.0;
   if(dir>0){ sl=price-slDist; if(UseFixedTP) tp=price+slDist*RiskReward; }
   else     { sl=price+slDist; if(UseFixedTP) tp=price-slDist*RiskReward; }
   sl=NormalizeDouble(sl,_Digits);
   if(UseFixedTP) tp=NormalizeDouble(tp,_Digits);

   bool ok=(dir>0)?trade.Buy(lots,_Symbol,ask,sl,tp,TradeComment)
                  :trade.Sell(lots,_Symbol,bid,sl,tp,TradeComment);
   if(ok){
      g_tradesToday++;
      g_lastEntryBar=iTime(_Symbol,_Period,0);
      PrintFormat("OPEN %s %.2f lots @ %.2f SL=%.2f TP=%.2f (open now:%d)",
                  (dir>0?"BUY":"SELL"),lots,price,sl,tp,CountMyPositions());
   } else {
      PrintFormat("Order FAILED: %s (retcode %d)",
                  trade.ResultRetcodeDescription(),trade.ResultRetcode());
   }
}

//============ STATELESS MANAGEMENT FOR EVERY POSITION ==============
void ManageAllPositions()
{
   if(!UseBreakeven && !UseTrailing) return;
   double atr=GetBuf(hATR,0,1);
   if(Bad(atr)||atr<=0) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)   continue;

      long   type =PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double tp   =PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
      {
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double profit=bid-entry;
         double newSL=sl;
         if(UseBreakeven && profit>=atr*BE_ATR_Trigger) newSL=MathMax(newSL,entry);
         if(UseTrailing  && profit>=atr*Trail_ATR_Start) newSL=MathMax(newSL,bid-atr*Trail_ATR_Mult);
         newSL=NormalizeDouble(newSL,_Digits);
         if(newSL>sl+_Point && newSL<bid) trade.PositionModify(tk,newSL,tp);
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double profit=entry-ask;
         double newSL=sl;
         if(UseBreakeven && profit>=atr*BE_ATR_Trigger) newSL=(sl==0?entry:MathMin(newSL,entry));
         if(UseTrailing  && profit>=atr*Trail_ATR_Start){ double cand=ask+atr*Trail_ATR_Mult; newSL=(newSL==0?cand:MathMin(newSL,cand)); }
         newSL=NormalizeDouble(newSL,_Digits);
         if((sl==0 || newSL<sl-_Point) && newSL>ask) trade.PositionModify(tk,newSL,tp);
      }
   }
}

//====================== RISK MANAGEMENT ============================
void DailyReset()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   if(tm.day!=g_curDay)
   {
      g_curDay=tm.day;
      g_tradesToday=0;
      g_dayAnchor=AccountInfoDouble(ACCOUNT_EQUITY);
      if(DebugMode) Print("Daily reset: trades today -> 0");
   }
}

void UpdateRiskState()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_peakEq) g_peakEq=eq;
   if(g_peakEq>0 && eq<=g_peakEq*(1.0-MaxDrawdown/100.0)) g_halted=true;
}

void UpdateVWAP()
{
   datetime bt=iTime(_Symbol,_Period,1);
   MqlDateTime tm; TimeToStruct(bt,tm);
   double tp=(iHigh(_Symbol,_Period,1)+iLow(_Symbol,_Period,1)+iClose(_Symbol,_Period,1))/3.0;
   double vol=(double)iTickVolume(_Symbol,_Period,1); if(vol<=0) vol=1.0;
   if(tm.day!=g_vwapDay){ g_vwapDay=tm.day; g_cumPV=tp*vol; g_cumVol=vol; }
   else                 { g_cumPV+=tp*vol; g_cumVol+=vol; }
}

bool DailyLossHit()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   return (g_dayAnchor>0 && eq<=g_dayAnchor*(1.0-MaxDailyLoss/100.0));
}

bool SessionOK()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   int h=tm.hour;
   if(StartHour<=EndHour) return (h>=StartHour && h<EndHour);
   return (h>=StartHour || h<EndHour);
}

bool SpreadTooWide(){ return (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) > MaxSpreadPts); }

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

// Money risk of one prospective trade (price distance -> account currency).
double RiskMoney(double slDist, double lots)
{
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSz<=0||tickVal<=0) return 0;
   return (slDist/tickSz)*tickVal*lots;
}

// *** THE REAL CAP *** total open risk of all our positions, as % of balance.
double OpenRiskPct()
{
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<=0) return 0;
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSz<=0||tickVal<=0) return 0;
   double money=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)   continue;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double lots =PositionGetDouble(POSITION_VOLUME);
      double dist =(sl>0 ? MathAbs(entry-sl) : entry*0.01);   // no SL -> assume ~1% as risk proxy
      money += (dist/tickSz)*tickVal*lots;
   }
   return money/bal*100.0;
}

double CalcLots(double slDistance)
{
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSz<=0||tickVal<=0||slDistance<=0) return 0;
   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*RiskPerTrade/100.0;
   double lossPerLot=(slDistance/tickSz)*tickVal;
   if(lossPerLot<=0) return 0;
   return riskMoney/lossPerLot;
}

double NormalizeLots(double lots)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step>0) lots=MathFloor(lots/step)*step;
   if(lots<minLot) lots=minLot;
   if(lots>maxLot) lots=maxLot;
   return lots;
}

//============================ HELPERS ==============================
double GetBuf(int handle, int buf, int shift)
{
   double tmp[];
   if(CopyBuffer(handle,buf,shift,1,tmp)<=0) return EMPTY_VALUE;
   return tmp[0];
}

double SmaOfBuffer(int handle, int startShift, int period)
{
   double tmp[];
   if(CopyBuffer(handle,0,startShift,period,tmp)<period) return EMPTY_VALUE;
   double s=0; for(int i=0;i<period;i++) s+=tmp[i];
   return s/period;
}

double HighestHigh(int startShift, int count)
{
   double h[];
   if(CopyHigh(_Symbol,_Period,startShift,count,h)<count) return EMPTY_VALUE;
   double m=h[0]; for(int i=1;i<count;i++) if(h[i]>m) m=h[i];
   return m;
}

double LowestLow(int startShift, int count)
{
   double l[];
   if(CopyLow(_Symbol,_Period,startShift,count,l)<count) return EMPTY_VALUE;
   double m=l[0]; for(int i=1;i<count;i++) if(l[i]<m) m=l[i];
   return m;
}

void MacroState(int emaHandle, string sym, bool &falling, bool &rising)
{
   falling=false; rising=false;
   double cl[]; double em=GetBuf(emaHandle,0,1);
   if(Bad(em)) return;
   if(CopyClose(sym,_Period,1,1,cl)<=0) return;
   falling=(cl[0]<em); rising=(cl[0]>em);
}

bool Bad(double v){ return (v==EMPTY_VALUE); }
//+------------------------------------------------------------------+

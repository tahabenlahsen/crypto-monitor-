//+------------------------------------------------------------------+
//|                                          XAUUSD_Ensemble_EA.mq5   |
//|   Multi-indicator ensemble Expert Advisor for gold (XAUUSD)      |
//|                                                                  |
//|   12 indicators vote on every new bar; the EA only trades when   |
//|   enough of them AGREE. Every entry is filtered by a full risk-  |
//|   management layer (ATR sizing, SL/TP, trailing stop, daily-loss |
//|   and drawdown kill-switches, spread + session filters).         |
//|                                                                  |
//|   *** RISK WARNING ***                                           |
//|   No EA can guarantee profit. Trading XAUUSD with leverage can   |
//|   lose money quickly. ALWAYS test on a DEMO account first.       |
//|   This is educational software, not financial advice.            |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Ensemble EA"
#property version   "1.00"

#include <Trade/Trade.mqh>

//============================ INPUTS ================================
input group "=== General ==="
input long   Magic            = 990099;   // Magic number (unique per chart)
input int    Deviation        = 30;       // Max slippage (points)
input string TradeComment      = "Ensemble"; // Order comment

input group "=== Ensemble (how many indicators must agree) ==="
input int    MinScore         = 4;        // Min net score |bull-bear| to trade (max 12)
input int    MinAgree         = 6;        // Min number of indicators agreeing (max 12)
input bool   RequireADX       = true;     // Only trade when ADX confirms a trend
input double ADX_Min          = 20.0;     // Minimum ADX for a "real" trend

input group "=== Risk management ==="
input double RiskPercent      = 1.0;      // Risk per trade (% of balance)
input double SL_ATR_Mult      = 2.0;      // Stop-loss = ATR x this
input double TP_ATR_Mult      = 3.0;      // Take-profit = ATR x this
input bool   UseTrailing      = true;     // Trail the stop in profit
input double Trail_ATR_Mult   = 2.0;      // Trailing distance = ATR x this
input double MaxDailyLossPct  = 5.0;      // Stop new trades after -X% on the day
input double MaxDrawdownPct   = 20.0;     // HALT all new trades after -X% from peak
input int    MaxSpreadPoints  = 50;       // Skip entry if spread wider than this
input int    MaxPositions     = 1;        // Max simultaneous positions

input group "=== Trading session (BROKER/server time, 24h clock) ==="
input bool   UseSession       = true;     // Restrict trading hours
input int    StartHour        = 7;        // Session start hour (server time)
input int    EndHour          = 21;       // Session end hour (server time)

input group "=== Indicator periods ==="
input int    EmaFast          = 20;
input int    EmaSlow          = 50;
input int    MACD_Fast        = 12;
input int    MACD_Slow        = 26;
input int    MACD_Signal      = 9;
input int    ADX_Period       = 14;
input int    RSI_Period       = 14;
input int    Stoch_K          = 14;
input int    Stoch_D          = 3;
input int    Stoch_Slow       = 3;
input int    CCI_Period       = 20;
input int    WPR_Period       = 14;
input int    Bands_Period     = 20;
input double Bands_Dev        = 2.0;
input int    Ichi_Tenkan      = 9;
input int    Ichi_Kijun       = 26;
input int    Ichi_Senkou      = 52;
input double SAR_Step         = 0.02;
input double SAR_Max          = 0.2;
input int    MFI_Period       = 14;
input int    ATR_Period       = 14;
input int    SuperTrendPeriod = 10;
input double SuperTrendMult   = 3.0;
input int    SuperTrendLook   = 300;      // bars used to compute Supertrend

//========================== GLOBALS ================================
CTrade trade;

int hEmaFast, hEmaSlow, hMACD, hADX, hRSI, hStoch, hCCI, hWPR;
int hBands, hIchi, hSAR, hMFI, hATR, hST_ATR;

datetime g_lastBar  = 0;
double   g_peakEq   = 0.0;
double   g_dayAnchor= 0.0;
int      g_curDay   = -1;
bool     g_halted   = false;

//============================ INIT =================================
int OnInit()
{
   hEmaFast = iMA(_Symbol,_Period,EmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol,_Period,EmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hMACD    = iMACD(_Symbol,_Period,MACD_Fast,MACD_Slow,MACD_Signal,PRICE_CLOSE);
   hADX     = iADX(_Symbol,_Period,ADX_Period);
   hRSI     = iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);
   hStoch   = iStochastic(_Symbol,_Period,Stoch_K,Stoch_D,Stoch_Slow,MODE_SMA,STO_LOWHIGH);
   hCCI     = iCCI(_Symbol,_Period,CCI_Period,PRICE_TYPICAL);
   hWPR     = iWPR(_Symbol,_Period,WPR_Period);
   hBands   = iBands(_Symbol,_Period,Bands_Period,0,Bands_Dev,PRICE_CLOSE);
   hIchi    = iIchimoku(_Symbol,_Period,Ichi_Tenkan,Ichi_Kijun,Ichi_Senkou);
   hSAR     = iSAR(_Symbol,_Period,SAR_Step,SAR_Max);
   hMFI     = iMFI(_Symbol,_Period,MFI_Period,VOLUME_TICK);
   hATR     = iATR(_Symbol,_Period,ATR_Period);
   hST_ATR  = iATR(_Symbol,_Period,SuperTrendPeriod);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hMACD==INVALID_HANDLE ||
      hADX==INVALID_HANDLE || hRSI==INVALID_HANDLE || hStoch==INVALID_HANDLE ||
      hCCI==INVALID_HANDLE || hWPR==INVALID_HANDLE || hBands==INVALID_HANDLE ||
      hIchi==INVALID_HANDLE || hSAR==INVALID_HANDLE || hMFI==INVALID_HANDLE ||
      hATR==INVALID_HANDLE || hST_ATR==INVALID_HANDLE)
   {
      Print("Failed to create one or more indicator handles");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Deviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_peakEq   = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayAnchor= g_peakEq;

   Print("XAUUSD Ensemble EA initialised on ", _Symbol, " ", EnumToString(_Period));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hEmaFast); IndicatorRelease(hEmaSlow); IndicatorRelease(hMACD);
   IndicatorRelease(hADX);     IndicatorRelease(hRSI);     IndicatorRelease(hStoch);
   IndicatorRelease(hCCI);     IndicatorRelease(hWPR);     IndicatorRelease(hBands);
   IndicatorRelease(hIchi);    IndicatorRelease(hSAR);     IndicatorRelease(hMFI);
   IndicatorRelease(hATR);     IndicatorRelease(hST_ATR);
}

//============================ TICK =================================
void OnTick()
{
   // Trail open stops on every tick so they follow price closely.
   ManageTrailing();

   // Everything else happens only once per new bar.
   datetime t = iTime(_Symbol,_Period,0);
   if(t == g_lastBar) return;
   g_lastBar = t;

   if(Bars(_Symbol,_Period) < 120) return;

   UpdateRiskState();
   if(g_halted){ Comment("HALTED: max drawdown reached. No new trades."); return; }

   // ---- risk gates -------------------------------------------------
   if(UseSession && !SessionOK())       { Comment("Outside trading session."); return; }
   if(SpreadTooWide())                  { Comment("Spread too wide."); return; }
   if(DailyLossHit())                   { Comment("Daily loss limit reached."); return; }
   if(CountMyPositions() >= MaxPositions){ Comment("Max positions open."); return; }

   // ---- ensemble signal -------------------------------------------
   double score=0, adx=0; int agree=0;
   int dir = GetEnsembleSignal(score, agree, adx);

   Comment(StringFormat("Score: %.0f  Agree: %d  ADX: %.1f  Dir: %s",
           score, agree, adx, (dir>0?"BUY":dir<0?"SELL":"FLAT")));

   if(dir==0) return;
   if(MathAbs(score) < MinScore || agree < MinAgree) return;
   if(RequireADX && adx < ADX_Min) return;

   // ---- size & execute --------------------------------------------
   double atr = GetBuf(hATR,0,1);
   if(atr<=0 || atr==EMPTY_VALUE) return;
   OpenTrade(dir, atr);
}

//====================== ENSEMBLE LOGIC =============================
int GetEnsembleSignal(double &score, int &agree, double &adxOut)
{
   score=0; agree=0;
   int v[12]; int n=0;
   double c1 = iClose(_Symbol,_Period,1);

   // 1. EMA trend regime
   double emaF=GetBuf(hEmaFast,0,1), emaS=GetBuf(hEmaSlow,0,1);
   v[n++] = (Bad(emaF)||Bad(emaS)) ? 0 : (emaF>emaS?1:(emaF<emaS?-1:0));

   // 2. MACD main vs signal
   double mMain=GetBuf(hMACD,0,1), mSig=GetBuf(hMACD,1,1);
   v[n++] = (Bad(mMain)||Bad(mSig)) ? 0 : (mMain>mSig?1:(mMain<mSig?-1:0));

   // 3. ADX direction (+DI vs -DI), only when a trend exists
   double adx=GetBuf(hADX,0,1), pDI=GetBuf(hADX,1,1), mDI=GetBuf(hADX,2,1);
   adxOut = Bad(adx)?0:adx;
   int adxVote=0;
   if(!Bad(adx) && adx>=ADX_Min && !Bad(pDI) && !Bad(mDI))
      adxVote = (pDI>mDI?1:-1);
   v[n++] = adxVote;

   // 4. RSI above/below 50
   double rsi=GetBuf(hRSI,0,1);
   v[n++] = Bad(rsi)?0:(rsi>50?1:(rsi<50?-1:0));

   // 5. Stochastic %K vs %D
   double stK=GetBuf(hStoch,0,1), stD=GetBuf(hStoch,1,1);
   v[n++] = (Bad(stK)||Bad(stD)) ? 0 : (stK>stD?1:(stK<stD?-1:0));

   // 6. CCI sign
   double cci=GetBuf(hCCI,0,1);
   v[n++] = Bad(cci)?0:(cci>0?1:(cci<0?-1:0));

   // 7. Williams %R above/below -50
   double wpr=GetBuf(hWPR,0,1);
   v[n++] = Bad(wpr)?0:(wpr>-50?1:(wpr<-50?-1:0));

   // 8. Bollinger: price vs middle band
   double mid=GetBuf(hBands,0,1);
   v[n++] = Bad(mid)?0:(c1>mid?1:(c1<mid?-1:0));

   // 9. Ichimoku: Tenkan/Kijun cross confirmed by price vs Kijun
   double ten=GetBuf(hIchi,0,1), kij=GetBuf(hIchi,1,1);
   int ichi=0;
   if(!Bad(ten)&&!Bad(kij)){
      if(ten>kij && c1>kij) ichi=1;
      else if(ten<kij && c1<kij) ichi=-1;
   }
   v[n++]=ichi;

   // 10. Parabolic SAR position
   double sar=GetBuf(hSAR,0,1);
   v[n++] = Bad(sar)?0:(sar<c1?1:(sar>c1?-1:0));

   // 11. Supertrend direction (the indicator most retail traders skip)
   v[n++] = SuperTrendDirection(SuperTrendPeriod, SuperTrendMult, SuperTrendLook);

   // 12. Money Flow Index above/below 50
   double mfi=GetBuf(hMFI,0,1);
   v[n++] = Bad(mfi)?0:(mfi>50?1:(mfi<50?-1:0));

   for(int i=0;i<n;i++) score += v[i];
   int dir = (score>0?1:(score<0?-1:0));
   if(dir!=0) for(int i=0;i<n;i++) if(v[i]==dir) agree++;
   return dir;
}

// Stateless Supertrend: recompute over a window and return +1/-1.
int SuperTrendDirection(int period, double mult, int lookback)
{
   double high[],low[],close[],atr[];
   ArraySetAsSeries(high,false);  ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false); ArraySetAsSeries(atr,false);
   if(CopyHigh(_Symbol,_Period,1,lookback,high)  <= 0) return 0;
   if(CopyLow(_Symbol,_Period,1,lookback,low)    <= 0) return 0;
   if(CopyClose(_Symbol,_Period,1,lookback,close)<= 0) return 0;
   if(CopyBuffer(hST_ATR,0,1,lookback,atr)       <= 0) return 0;

   int cnt = ArraySize(close);
   if(cnt < 2) return 0;

   double prevUp=0, prevLow=0;
   int trend=1, prevTrend=1;
   for(int i=0;i<cnt;i++){
      double hl2=(high[i]+low[i])/2.0;
      double up =hl2+mult*atr[i];
      double dn =hl2-mult*atr[i];
      if(i==0){ prevUp=up; prevLow=dn; trend=1; prevTrend=1; continue; }
      double fUp = (up<prevUp  || close[i-1]>prevUp)  ? up : prevUp;
      double fLow= (dn>prevLow || close[i-1]<prevLow) ? dn : prevLow;
      if(close[i]>prevUp)      trend=1;
      else if(close[i]<prevLow)trend=-1;
      else                     trend=prevTrend;
      prevUp=fUp; prevLow=fLow; prevTrend=trend;
   }
   return trend;
}

//====================== RISK MANAGEMENT ============================
void UpdateRiskState()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   if(tm.day != g_curDay){ g_curDay=tm.day; g_dayAnchor=eq; }
   if(eq > g_peakEq) g_peakEq = eq;
   if(g_peakEq>0 && eq <= g_peakEq*(1.0-MaxDrawdownPct/100.0)) g_halted=true;
}

bool DailyLossHit()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (g_dayAnchor>0 && eq <= g_dayAnchor*(1.0-MaxDailyLossPct/100.0));
}

bool SessionOK()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   int h=tm.hour;
   if(StartHour<=EndHour) return (h>=StartHour && h<EndHour);
   return (h>=StartHour || h<EndHour);   // session wraps past midnight
}

bool SpreadTooWide()
{
   long spread = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   return (spread > MaxSpreadPoints);
}

int CountMyPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
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

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent/100.0;
   double lossPerLot= (slDistance/tickSz) * tickVal;
   if(lossPerLot<=0) return 0;

   double lots = riskMoney / lossPerLot;

   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step>0) lots = MathFloor(lots/step)*step;
   if(lots<minLot) lots=minLot;
   if(lots>maxLot) lots=maxLot;
   return lots;
}

void OpenTrade(int dir, double atr)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=(dir>0?ask:bid);

   double slDist=atr*SL_ATR_Mult;
   double tpDist=atr*TP_ATR_Mult;
   double minDist=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(slDist<minDist) slDist=minDist;
   if(tpDist<minDist) tpDist=minDist;

   double sl,tp;
   if(dir>0){ sl=NormalizeDouble(price-slDist,_Digits); tp=NormalizeDouble(price+tpDist,_Digits); }
   else     { sl=NormalizeDouble(price+slDist,_Digits); tp=NormalizeDouble(price-tpDist,_Digits); }

   double lots=CalcLots(slDist);
   if(lots<=0){ Print("Lot size came out 0 - skipping trade"); return; }

   bool ok = (dir>0) ? trade.Buy(lots,_Symbol,ask,sl,tp,TradeComment)
                     : trade.Sell(lots,_Symbol,bid,sl,tp,TradeComment);
   if(ok)
      PrintFormat("OPEN %s %.2f lots @ %.2f  SL=%.2f  TP=%.2f",
                  (dir>0?"BUY":"SELL"), lots, price, sl, tp);
   else
      PrintFormat("Order FAILED: %s (retcode %d)",
                  trade.ResultRetcodeDescription(), trade.ResultRetcode());
}

void ManageTrailing()
{
   if(!UseTrailing) return;
   double atr=GetBuf(hATR,0,1);
   if(atr<=0 || atr==EMPTY_VALUE) return;
   double dist=atr*Trail_ATR_Mult;

   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)   continue;

      long   type=PositionGetInteger(POSITION_TYPE);
      double sl  =PositionGetDouble(POSITION_SL);
      double tp  =PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY){
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double newSL=NormalizeDouble(bid-dist,_Digits);
         if(newSL>sl+_Point && newSL<bid)
            trade.PositionModify(tk,newSL,tp);
      } else if(type==POSITION_TYPE_SELL){
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double newSL=NormalizeDouble(ask+dist,_Digits);
         if((sl==0 || newSL<sl-_Point) && newSL>ask)
            trade.PositionModify(tk,newSL,tp);
      }
   }
}

//============================ HELPERS ==============================
// Read one indicator value at a given bar shift (1 = last closed bar).
double GetBuf(int handle, int bufferIndex, int shift)
{
   double tmp[];
   if(CopyBuffer(handle, bufferIndex, shift, 1, tmp) <= 0) return EMPTY_VALUE;
   return tmp[0];
}

bool Bad(double v){ return (v==EMPTY_VALUE); }
//+------------------------------------------------------------------+

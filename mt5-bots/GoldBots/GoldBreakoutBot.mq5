//+------------------------------------------------------------------+
//|                                              GoldBreakoutBot.mq5 |
//|  GoldBots family - Strategy 2: LONDON SESSION BREAKOUT           |
//|                                                                  |
//|  Idea: gold is usually quiet during the Asian session and then   |
//|  makes its move when London (and later New York) opens. Measure  |
//|  the Asian range, then trade the first clean break of it.        |
//|                                                                  |
//|  Range  : high/low between AsiaStartHour and AsiaEndHour         |
//|  Entry  : price closes beyond the range during the trade window  |
//|  SL     : the opposite side of the range (capped by ATR mult)    |
//|  TP     : range height x TpRangeMult                             |
//|  Limit  : max one long and one short attempt per day             |
//|                                                                  |
//|  Attach to: XAUUSD, M15                                          |
//|  NOTE: hours are SERVER time - check your broker's clock and     |
//|  adjust so the Asian window really covers the quiet hours.       |
//+------------------------------------------------------------------+
#property copyright "GoldBots"
#property version   "1.00"
#property description "Asian-range breakout EA for XAUUSD, trades the London open"

#include <Trade\Trade.mqh>
#include "Include/RiskManager.mqh"
#include "Include/TradeUtils.mqh"

//--- inputs: strategy
input int    InpAsiaStartHour   = 1;      // Asian range start hour (server time)
input int    InpAsiaEndHour     = 8;      // Asian range end hour (server time)
input int    InpTradeEndHour    = 14;     // Stop looking for breakouts after this hour
input double InpBreakBufferPts  = 150;    // Extra points beyond the range to confirm a break
input double InpTpRangeMult     = 1.5;    // Take-profit = range height x this
input int    InpAtrPeriod       = 14;     // ATR period (SL cap)
input double InpMaxSlAtrMult    = 3.0;    // Cap SL distance at ATR x this
input double InpMinRangePts     = 200;    // Skip days with a range smaller than this (points)
input double InpMaxRangePts     = 3000;   // Skip days with a range larger than this (points)
//--- inputs: risk (shared rules with the other GoldBots)
input double InpRiskPercent     = 0.5;    // Risk per trade, % of balance
input double InpMaxDailyLossPct = 3.0;    // Daily loss circuit breaker, % (all bots)
input int    InpMaxFamilyPos    = 3;      // Max open positions across all GoldBots
input int    InpMaxSpreadPoints = 50;     // Max allowed spread in points
input long   InpMagic           = 77702;  // Magic number (keep in 77701-77799)

CTrade   g_trade;
int      g_atrHandle    = INVALID_HANDLE;
datetime g_lastBarTime  = 0;
int      g_longTradeDay = -1;   // day-of-year of the last long attempt
int      g_shortTradeDay = -1;  // day-of-year of the last short attempt

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpAsiaStartHour >= InpAsiaEndHour || InpAsiaEndHour > InpTradeEndHour)
   {
      Print("GoldBreakoutBot: invalid session hours (need start < end <= trade end)");
      return INIT_PARAMETERS_INCORRECT;
   }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle = iATR(_Symbol, _Period, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("GoldBreakoutBot: failed to create ATR handle");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
//| Today's Asian-session high/low from M15 bars. False if the       |
//| session isn't finished yet or data is missing.                   |
//+------------------------------------------------------------------+
bool GetAsianRange(double &rangeHigh, double &rangeLow)
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < InpAsiaEndHour)
      return false;                       // session still running

   string day = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);
   datetime from = StringToTime(day + StringFormat(" %02d:00", InpAsiaStartHour));
   datetime to   = StringToTime(day + StringFormat(" %02d:00", InpAsiaEndHour));

   int fromBar = iBarShift(_Symbol, PERIOD_M15, from);
   int toBar   = iBarShift(_Symbol, PERIOD_M15, to);
   if(fromBar < 0 || toBar < 0 || fromBar <= toBar)
      return false;

   int count   = fromBar - toBar;         // bars fully inside the window
   int highIdx = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, count, toBar + 1);
   int lowIdx  = iLowest(_Symbol, PERIOD_M15, MODE_LOW, count, toBar + 1);
   if(highIdx < 0 || lowIdx < 0)
      return false;

   rangeHigh = iHigh(_Symbol, PERIOD_M15, highIdx);
   rangeLow  = iLow(_Symbol, PERIOD_M15, lowIdx);
   return rangeHigh > rangeLow;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar(_Symbol, _Period, g_lastBarTime))
      return;

   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < InpAsiaEndHour || dt.hour >= InpTradeEndHour)
      return;                             // outside the breakout window

   if(!RiskManagerAllowsEntry(_Symbol, InpMagic, InpMaxDailyLossPct, InpMaxFamilyPos))
      return;
   if(!SpreadOK(_Symbol, InpMaxSpreadPoints))
      return;

   double rangeHigh = 0, rangeLow = 0;
   if(!GetAsianRange(rangeHigh, rangeLow))
      return;

   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double rangePts = (rangeHigh - rangeLow) / point;
   if(rangePts < InpMinRangePts || rangePts > InpMaxRangePts)
      return;                             // dead day or crazy news day - skip

   double atr = GetAtr(g_atrHandle);
   if(atr <= 0)
      return;

   // last closed bar on the chart timeframe
   double closePrev = iClose(_Symbol, _Period, 1);
   double buffer    = InpBreakBufferPts * point;
   int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   bool breakUp   = closePrev > rangeHigh + buffer && g_longTradeDay  != dt.day_of_year;
   bool breakDown = closePrev < rangeLow  - buffer && g_shortTradeDay != dt.day_of_year;
   if(!breakUp && !breakDown)
      return;

   double rangeHeight = rangeHigh - rangeLow;
   double maxSlDist   = atr * InpMaxSlAtrMult;

   if(breakUp)
   {
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double slDist = MathMin(ask - rangeLow, maxSlDist);
      double lots   = CalcLotByRisk(_Symbol, InpRiskPercent, slDist / point);
      if(lots <= 0)
         return;
      double sl = NormalizeDouble(ask - slDist, digits);
      double tp = NormalizeDouble(ask + rangeHeight * InpTpRangeMult, digits);
      if(g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "GoldBreakoutBot buy"))
         g_longTradeDay = dt.day_of_year; // one long attempt per day
      else
         Print("GoldBreakoutBot: buy failed, retcode=", g_trade.ResultRetcode());
   }
   else // breakDown
   {
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = MathMin(rangeHigh - bid, maxSlDist);
      double lots   = CalcLotByRisk(_Symbol, InpRiskPercent, slDist / point);
      if(lots <= 0)
         return;
      double sl = NormalizeDouble(bid + slDist, digits);
      double tp = NormalizeDouble(bid - rangeHeight * InpTpRangeMult, digits);
      if(g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "GoldBreakoutBot sell"))
         g_shortTradeDay = dt.day_of_year; // one short attempt per day
      else
         Print("GoldBreakoutBot: sell failed, retcode=", g_trade.ResultRetcode());
   }
}
//+------------------------------------------------------------------+

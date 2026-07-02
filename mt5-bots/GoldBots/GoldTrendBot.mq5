//+------------------------------------------------------------------+
//|                                                 GoldTrendBot.mq5 |
//|  GoldBots family - Strategy 1: TREND FOLLOWING                   |
//|                                                                  |
//|  Idea: gold trends hard when it trends. Enter on an EMA cross    |
//|  confirmed by ADX strength, ride the move with an ATR trailing   |
//|  stop.                                                           |
//|                                                                  |
//|  Entry  : fast EMA crosses slow EMA on a closed bar, ADX > min   |
//|  SL     : ATR * SlAtrMult                                        |
//|  TP     : ATR * TpAtrMult                                        |
//|  Manage : ATR trailing stop once in profit                       |
//|                                                                  |
//|  Attach to: XAUUSD, H1 (chart timeframe is used for signals)     |
//+------------------------------------------------------------------+
#property copyright "GoldBots"
#property version   "1.00"
#property description "Trend-following EA for XAUUSD: EMA cross + ADX filter, ATR stops"

#include <Trade\Trade.mqh>
#include "Include/RiskManager.mqh"
#include "Include/TradeUtils.mqh"

//--- inputs: strategy
input int    InpFastEmaPeriod   = 21;     // Fast EMA period
input int    InpSlowEmaPeriod   = 55;     // Slow EMA period
input int    InpAdxPeriod       = 14;     // ADX period
input double InpAdxMin          = 25.0;   // Minimum ADX to confirm a trend
input int    InpAtrPeriod       = 14;     // ATR period
input double InpSlAtrMult       = 2.0;    // Stop-loss = ATR x this
input double InpTpAtrMult       = 4.0;    // Take-profit = ATR x this
input double InpTrailAtrMult    = 1.5;    // Trailing distance = ATR x this
//--- inputs: risk (shared rules with the other GoldBots)
input double InpRiskPercent     = 0.5;    // Risk per trade, % of balance
input double InpMaxDailyLossPct = 3.0;    // Daily loss circuit breaker, % (all bots)
input int    InpMaxFamilyPos    = 3;      // Max open positions across all GoldBots
input int    InpMaxSpreadPoints = 50;     // Max allowed spread in points
input long   InpMagic           = 77701;  // Magic number (keep in 77701-77799)

CTrade   g_trade;
int      g_emaFastHandle = INVALID_HANDLE;
int      g_emaSlowHandle = INVALID_HANDLE;
int      g_adxHandle     = INVALID_HANDLE;
int      g_atrHandle     = INVALID_HANDLE;
datetime g_lastBarTime   = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_emaFastHandle = iMA(_Symbol, _Period, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, _Period, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_adxHandle     = iADX(_Symbol, _Period, InpAdxPeriod);
   g_atrHandle     = iATR(_Symbol, _Period, InpAtrPeriod);

   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE ||
      g_adxHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("GoldTrendBot: failed to create indicator handles");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_emaFastHandle);
   IndicatorRelease(g_emaSlowHandle);
   IndicatorRelease(g_adxHandle);
   IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // manage the open position on every tick
   double atr = GetAtr(g_atrHandle);
   if(atr > 0)
      ApplyTrailing(g_trade, _Symbol, InpMagic, atr * InpTrailAtrMult);

   // evaluate entries only once per closed bar
   if(!IsNewBar(_Symbol, _Period, g_lastBarTime))
      return;
   if(!RiskManagerAllowsEntry(_Symbol, InpMagic, InpMaxDailyLossPct, InpMaxFamilyPos))
      return;
   if(!SpreadOK(_Symbol, InpMaxSpreadPoints))
      return;

   // closed-bar values: index 1 = last closed bar, index 2 = the one before
   double fast[2], slow[2], adx[1];
   if(CopyBuffer(g_emaFastHandle, 0, 1, 2, fast) != 2) return;
   if(CopyBuffer(g_emaSlowHandle, 0, 1, 2, slow) != 2) return;
   if(CopyBuffer(g_adxHandle, MAIN_LINE, 1, 1, adx) != 1) return;
   if(atr <= 0) return;

   // CopyBuffer returns series oldest-first: [0] = bar 2, [1] = bar 1
   bool crossedUp   = fast[0] <= slow[0] && fast[1] > slow[1];
   bool crossedDown = fast[0] >= slow[0] && fast[1] < slow[1];
   bool trending    = adx[0] >= InpAdxMin;

   if(!trending || (!crossedUp && !crossedDown))
      return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slDist = atr * InpSlAtrMult;
   double tpDist = atr * InpTpAtrMult;
   double lots   = CalcLotByRisk(_Symbol, InpRiskPercent, slDist / point);
   if(lots <= 0)
   {
      Print("GoldTrendBot: lot calculation failed or below broker minimum");
      return;
   }

   if(crossedUp)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = NormalizeDouble(ask + tpDist, digits);
      if(!g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "GoldTrendBot buy"))
         Print("GoldTrendBot: buy failed, retcode=", g_trade.ResultRetcode());
   }
   else // crossedDown
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = NormalizeDouble(bid - tpDist, digits);
      if(!g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "GoldTrendBot sell"))
         Print("GoldTrendBot: sell failed, retcode=", g_trade.ResultRetcode());
   }
}
//+------------------------------------------------------------------+

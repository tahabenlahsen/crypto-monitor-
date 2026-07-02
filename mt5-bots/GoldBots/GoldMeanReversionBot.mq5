//+------------------------------------------------------------------+
//|                                         GoldMeanReversionBot.mq5 |
//|  GoldBots family - Strategy 3: MEAN REVERSION (range days)       |
//|                                                                  |
//|  Idea: when gold is NOT trending (low ADX) it tends to oscillate |
//|  around its average. Fade stretched moves: buy at the lower      |
//|  Bollinger band with RSI oversold, sell at the upper band with   |
//|  RSI overbought, and exit at the middle band.                    |
//|                                                                  |
//|  This bot is the counterweight to GoldTrendBot: it only trades   |
//|  when ADX is LOW, so the two rarely fight over the same market.  |
//|                                                                  |
//|  Entry  : close beyond a Bollinger band + RSI extreme + ADX low  |
//|  SL     : ATR * SlAtrMult beyond the entry                       |
//|  Exit   : price returns to the middle band (or the SL)           |
//|                                                                  |
//|  Attach to: XAUUSD, M30                                          |
//+------------------------------------------------------------------+
#property copyright "GoldBots"
#property version   "1.00"
#property description "Mean-reversion EA for XAUUSD: Bollinger + RSI fades in quiet markets"

#include <Trade\Trade.mqh>
#include "Include/RiskManager.mqh"
#include "Include/TradeUtils.mqh"

//--- inputs: strategy
input int    InpBbPeriod        = 20;     // Bollinger period
input double InpBbDeviation     = 2.0;    // Bollinger deviation
input int    InpRsiPeriod       = 14;     // RSI period
input double InpRsiOversold     = 30.0;   // RSI oversold level (buy zone)
input double InpRsiOverbought   = 70.0;   // RSI overbought level (sell zone)
input int    InpAdxPeriod       = 14;     // ADX period
input double InpAdxMax          = 20.0;   // Only trade when ADX is BELOW this (ranging)
input int    InpAtrPeriod       = 14;     // ATR period
input double InpSlAtrMult       = 1.5;    // Stop-loss = ATR x this
//--- inputs: risk (shared rules with the other GoldBots)
input double InpRiskPercent     = 0.5;    // Risk per trade, % of balance
input double InpMaxDailyLossPct = 3.0;    // Daily loss circuit breaker, % (all bots)
input int    InpMaxFamilyPos    = 3;      // Max open positions across all GoldBots
input int    InpMaxSpreadPoints = 50;     // Max allowed spread in points
input long   InpMagic           = 77703;  // Magic number (keep in 77701-77799)

CTrade   g_trade;
int      g_bbHandle    = INVALID_HANDLE;
int      g_rsiHandle   = INVALID_HANDLE;
int      g_adxHandle   = INVALID_HANDLE;
int      g_atrHandle   = INVALID_HANDLE;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_bbHandle  = iBands(_Symbol, _Period, InpBbPeriod, 0, InpBbDeviation, PRICE_CLOSE);
   g_rsiHandle = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   g_adxHandle = iADX(_Symbol, _Period, InpAdxPeriod);
   g_atrHandle = iATR(_Symbol, _Period, InpAtrPeriod);

   if(g_bbHandle == INVALID_HANDLE || g_rsiHandle == INVALID_HANDLE ||
      g_adxHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("GoldMeanReversionBot: failed to create indicator handles");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_bbHandle);
   IndicatorRelease(g_rsiHandle);
   IndicatorRelease(g_adxHandle);
   IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
//| Exit management: close when price tags the middle band.          |
//+------------------------------------------------------------------+
void ManageExit(const double bbMiddle)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY &&
         SymbolInfoDouble(_Symbol, SYMBOL_BID) >= bbMiddle)
         g_trade.PositionClose(ticket);
      else if(type == POSITION_TYPE_SELL &&
              SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= bbMiddle)
         g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Bollinger buffers: 0 = middle, 1 = upper, 2 = lower (bar 1 = closed)
   double bbMid[1], bbUp[1], bbLow[1];
   if(CopyBuffer(g_bbHandle, BASE_LINE,  1, 1, bbMid) != 1) return;
   if(CopyBuffer(g_bbHandle, UPPER_BAND, 1, 1, bbUp)  != 1) return;
   if(CopyBuffer(g_bbHandle, LOWER_BAND, 1, 1, bbLow) != 1) return;

   // manage exits on every tick so we don't overstay the reversion
   ManageExit(bbMid[0]);

   if(!IsNewBar(_Symbol, _Period, g_lastBarTime))
      return;
   if(!RiskManagerAllowsEntry(_Symbol, InpMagic, InpMaxDailyLossPct, InpMaxFamilyPos))
      return;
   if(!SpreadOK(_Symbol, InpMaxSpreadPoints))
      return;

   double rsi[1], adx[1];
   if(CopyBuffer(g_rsiHandle, 0, 1, 1, rsi) != 1) return;
   if(CopyBuffer(g_adxHandle, MAIN_LINE, 1, 1, adx) != 1) return;
   if(adx[0] >= InpAdxMax)
      return;                             // market is trending - stand aside

   double atr = GetAtr(g_atrHandle);
   if(atr <= 0)
      return;

   double closePrev = iClose(_Symbol, _Period, 1);
   int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slDist    = atr * InpSlAtrMult;
   double lots      = CalcLotByRisk(_Symbol, InpRiskPercent, slDist / point);
   if(lots <= 0)
      return;

   bool buySignal  = closePrev <= bbLow[0] && rsi[0] <= InpRsiOversold;
   bool sellSignal = closePrev >= bbUp[0]  && rsi[0] >= InpRsiOverbought;

   if(buySignal)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = NormalizeDouble(bbMid[0], digits);   // target the mean
      if(!g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "GoldMeanReversionBot buy"))
         Print("GoldMeanReversionBot: buy failed, retcode=", g_trade.ResultRetcode());
   }
   else if(sellSignal)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = NormalizeDouble(bbMid[0], digits);
      if(!g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "GoldMeanReversionBot sell"))
         Print("GoldMeanReversionBot: sell failed, retcode=", g_trade.ResultRetcode());
   }
}
//+------------------------------------------------------------------+

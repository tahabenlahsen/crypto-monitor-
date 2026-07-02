//+------------------------------------------------------------------+
//|                                                   TradeUtils.mqh |
//|  Small helpers shared by the GoldBots family.                    |
//+------------------------------------------------------------------+
#ifndef GOLDBOTS_TRADEUTILS_MQH
#define GOLDBOTS_TRADEUTILS_MQH

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| True exactly once per new bar of the given timeframe.            |
//| Keep `lastBarTime` as a static/global in the calling EA.         |
//+------------------------------------------------------------------+
bool IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime t = iTime(symbol, tf, 0);
   if(t == 0 || t == lastBarTime)
      return false;
   lastBarTime = t;
   return true;
}

//+------------------------------------------------------------------+
//| Spread filter - gold spreads blow out around news; skip then.    |
//+------------------------------------------------------------------+
bool SpreadOK(const string symbol, const int maxSpreadPoints)
{
   long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   return spread > 0 && spread <= maxSpreadPoints;
}

//+------------------------------------------------------------------+
//| Is the current server time inside [startHour, endHour) ?         |
//+------------------------------------------------------------------+
bool InSession(const int startHour, const int endHour)
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(startHour <= endHour)
      return dt.hour >= startHour && dt.hour < endHour;
   // overnight session (e.g. 22 -> 6)
   return dt.hour >= startHour || dt.hour < endHour;
}

//+------------------------------------------------------------------+
//| Latest ATR value from an indicator handle (0 on failure).        |
//+------------------------------------------------------------------+
double GetAtr(const int atrHandle, const int shift = 1)
{
   double buf[1];
   if(CopyBuffer(atrHandle, 0, shift, 1, buf) != 1)
      return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Trail the SL of this bot's position by `trailDistance` (price    |
//| units) once the trade is in profit by at least that distance.    |
//+------------------------------------------------------------------+
void ApplyTrailing(CTrade &trade, const string symbol, const long magic,
                   const double trailDistance)
{
   if(trailDistance <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol ||
         PositionGetInteger(POSITION_MAGIC) != magic)
         continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      if(type == POSITION_TYPE_BUY)
      {
         double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDistance, digits);
         // only trail once in profit, only move SL up
         if(bid - openPrice >= trailDistance &&
            (curSL == 0 || newSL > curSL))
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDistance, digits);
         if(openPrice - ask >= trailDistance &&
            (curSL == 0 || newSL < curSL))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Close this bot's position at market (used for signal exits).     |
//+------------------------------------------------------------------+
void CloseBotPosition(CTrade &trade, const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == magic)
         trade.PositionClose(ticket);
   }
}

#endif // GOLDBOTS_TRADEUTILS_MQH

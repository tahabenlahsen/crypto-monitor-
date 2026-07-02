//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  Shared risk management for the GoldBots family (XAUUSD).        |
//|                                                                  |
//|  Every bot in the family includes this file, so they all obey    |
//|  the same rules:                                                 |
//|    - position size is calculated from a fixed % of balance      |
//|    - a daily-loss circuit breaker halts ALL bots for the day    |
//|    - a cap on total open positions across the whole family      |
//|                                                                  |
//|  Family magic-number range: 77701 .. 77799                      |
//+------------------------------------------------------------------+
#ifndef GOLDBOTS_RISKMANAGER_MQH
#define GOLDBOTS_RISKMANAGER_MQH

#define GOLDBOTS_MAGIC_FROM 77701
#define GOLDBOTS_MAGIC_TO   77799

//+------------------------------------------------------------------+
//| Lot size so that hitting the SL loses ~riskPercent of balance.   |
//| slDistancePoints = stop-loss distance in points (not pips).      |
//| Returns 0 if the size cannot be computed or is below broker min. |
//+------------------------------------------------------------------+
double CalcLotByRisk(const string symbol, const double riskPercent,
                     const double slDistancePoints)
{
   if(riskPercent <= 0 || slDistancePoints <= 0)
      return 0.0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * riskPercent / 100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tickValue <= 0 || tickSize <= 0 || point <= 0)
      return 0.0;

   // money lost per 1.0 lot if the SL is hit
   double lossPerLot = slDistancePoints * point / tickSize * tickValue;
   if(lossPerLot <= 0)
      return 0.0;

   double lots = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step > 0)
      lots = MathFloor(lots / step) * step;

   if(lots < minLot)
      return 0.0;            // risk budget too small for even the minimum lot
   if(lots > maxLot)
      lots = maxLot;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Daily-loss circuit breaker, shared by every bot in the family.   |
//| The first bot to run each day records the starting equity in a   |
//| terminal global variable; afterwards every bot compares current  |
//| equity against that anchor. When breached, all bots stop opening |
//| new trades until the next day.                                   |
//+------------------------------------------------------------------+
bool DailyLossBreached(const double maxDailyLossPercent)
{
   if(maxDailyLossPercent <= 0)
      return false;

   MqlDateTime dt;
   TimeCurrent(dt);
   string key = StringFormat("GOLDBOTS_DAYSTART_%04d%02d%02d",
                             dt.year, dt.mon, dt.day);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(key))
      GlobalVariableSet(key, equity);

   double dayStartEquity = GlobalVariableGet(key);
   if(dayStartEquity <= 0)
      return false;

   return equity <= dayStartEquity * (1.0 - maxDailyLossPercent / 100.0);
}

//+------------------------------------------------------------------+
//| Number of open positions on `symbol` belonging to any GoldBot.   |
//+------------------------------------------------------------------+
int FamilyPositionsTotal(const string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic >= GOLDBOTS_MAGIC_FROM && magic <= GOLDBOTS_MAGIC_TO)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Does this specific bot (magic) already hold a position?          |
//+------------------------------------------------------------------+
bool HasOpenPosition(const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Master pre-trade check every bot calls before opening anything.  |
//| Returns true when it is OK to open a new trade.                  |
//+------------------------------------------------------------------+
bool RiskManagerAllowsEntry(const string symbol, const long magic,
                            const double maxDailyLossPercent,
                            const int maxFamilyPositions)
{
   if(DailyLossBreached(maxDailyLossPercent))
   {
      Print("RiskManager: daily loss limit hit - all GoldBots paused for today");
      return false;
   }
   if(HasOpenPosition(symbol, magic))
      return false;                       // one position per bot
   if(FamilyPositionsTotal(symbol) >= maxFamilyPositions)
   {
      Print("RiskManager: family position cap reached (",
            maxFamilyPositions, ") - entry skipped");
      return false;
   }
   return true;
}

#endif // GOLDBOTS_RISKMANAGER_MQH

//+------------------------------------------------------------------+
//|                                          XAUUSD_CRT_Indicator.mq5 |
//|   CRT — Candle Range Theory marker for gold (or any symbol).      |
//|                                                                  |
//|   The 3-candle model:                                            |
//|     1) RANGE candle      -> its high/low define the range         |
//|     2) MANIPULATION      -> next candle sweeps the range high OR  |
//|                             low, then CLOSES back inside          |
//|     3) DISTRIBUTION      -> price is expected to reverse to the   |
//|                             opposite side of the range            |
//|                                                                  |
//|   Swept the HIGH + closed back inside -> SELL (target = range low)|
//|   Swept the LOW  + closed back inside -> BUY  (target = range high)|
//|                                                                  |
//|   It DRAWS only (box + arrow + target) and ALERTS. It does NOT    |
//|   place trades — you decide. Educational tool, not advice.        |
//+------------------------------------------------------------------+
#property copyright "CRT Indicator"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//============================ INPUTS ================================
input ENUM_TIMEFRAMES RangeTF        = PERIOD_H4;   // Timeframe of the RANGE candle
input bool            RequireCloseInside = true;    // Sweep candle must close back INSIDE the range
input bool            UseTrendFilter   = false;     // Only take setups in the EMA trend direction
input int             TrendEMA         = 50;        // Trend EMA period (on RangeTF)
input int             HistoryBars      = 300;       // How many range candles to scan on load
input int             BoxExtendBars    = 3;         // Extend box/target this many range bars to the right

input group "=== Visuals & alerts ==="
input bool            ShowRangeBox     = true;      // Draw the range box
input bool            ShowTarget       = true;      // Draw the target line (opposite side)
input bool            ShowArrows       = true;      // Draw BUY/SELL arrows
input bool            AlertPopup       = true;      // Popup alert on a NEW setup
input bool            AlertPush        = false;     // Phone push notification on a NEW setup
input color           BuyColor         = clrLime;   // Bullish CRT colour
input color           SellColor        = clrRed;    // Bearish CRT colour
input color           BoxColor         = clrSlateGray; // Range box colour

//========================== GLOBALS ================================
string   PFX = "CRT_";
datetime g_lastRangeBar = 0;
int      hTrend = INVALID_HANDLE;

//============================ INIT =================================
int OnInit()
{
   if(UseTrendFilter)
   {
      hTrend = iMA(_Symbol, RangeTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(hTrend == INVALID_HANDLE){ Print("CRT: failed to create trend EMA handle"); return(INIT_FAILED); }
   }
   IndicatorSetString(INDICATOR_SHORTNAME, "CRT (" + EnumToString(RangeTF) + ")");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PFX);
   if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend);
}

//============================ CALC =================================
int OnCalculate(const int        rates_total,
                const int        prev_calculated,
                const datetime  &time[],
                const double    &open[],
                const double    &high[],
                const double    &low[],
                const double    &close[],
                const long      &tick_volume[],
                const long      &volume[],
                const int       &spread[])
{
   // First load: paint past setups so the chart is useful immediately (no alerts).
   if(prev_calculated == 0)
      ScanHistory();

   // On every NEW range-TF candle, evaluate the candle that just closed.
   datetime rt = iTime(_Symbol, RangeTF, 0);
   if(rt != g_lastRangeBar)
   {
      g_lastRangeBar = rt;
      EvaluateCRT(1, true);          // shift 1 = the just-closed candle (the "manipulation")
   }
   return(rates_total);
}

//========================= CRT ENGINE =============================
void ScanHistory()
{
   int avail = Bars(_Symbol, RangeTF);
   if(avail < 5) return;
   int maxs = MathMin(HistoryBars, avail - 3);
   for(int s = maxs; s >= 1; s--)
      EvaluateCRT(s, false);
   g_lastRangeBar = iTime(_Symbol, RangeTF, 0);
}

// c2shift = shift of the "manipulation" candle; the range candle is c2shift+1.
void EvaluateCRT(int c2shift, bool live)
{
   int c1shift = c2shift + 1;
   double c1H = iHigh(_Symbol, RangeTF, c1shift), c1L = iLow(_Symbol, RangeTF, c1shift);
   double c2H = iHigh(_Symbol, RangeTF, c2shift), c2L = iLow(_Symbol, RangeTF, c2shift);
   double c2C = iClose(_Symbol, RangeTF, c2shift);
   datetime c1t = iTime(_Symbol, RangeTF, c1shift), c2t = iTime(_Symbol, RangeTF, c2shift);
   if(c1H <= 0 || c2H <= 0 || c1t == 0 || c2t == 0 || c1H <= c1L) return;

   bool sweptHigh = (c2H > c1H);
   bool sweptLow  = (c2L < c1L);

   // bearish: swept the high then closed back below it; bullish: swept the low then closed back above it
   bool bearish = sweptHigh && (c2C < c1H);
   bool bullish = sweptLow  && (c2C > c1L);
   if(RequireCloseInside)
   {
      bearish = bearish && (c2C > c1L);   // closed fully inside the range
      bullish = bullish && (c2C < c1H);
   }

   // If the candle swept BOTH sides, keep the side with the larger liquidity grab.
   if(bearish && bullish)
   {
      double upWick = c2H - c1H, dnWick = c1L - c2L;
      if(upWick >= dnWick) bullish = false; else bearish = false;
   }
   if(!bearish && !bullish) return;

   // Optional higher-timeframe EMA trend filter
   if(UseTrendFilter && hTrend != INVALID_HANDLE)
   {
      double ema = MAval(c2shift);
      if(ema != EMPTY_VALUE)
      {
         if(bullish && c2C < ema) return;
         if(bearish && c2C > ema) return;
      }
   }

   int      dir    = bullish ? 1 : -1;
   double   target = bullish ? c1H : c1L;          // opposite side of the range
   double   sweep  = bullish ? c2L : c2H;          // where the liquidity grab happened
   datetime tEnd   = c2t + (datetime)(BoxExtendBars * PeriodSeconds(RangeTF));
   string   id     = (string)(long)c2t;
   color    col    = (dir > 0) ? BuyColor : SellColor;

   if(ShowRangeBox) MakeBox (PFX + "box_" + id, c1t, c1H, tEnd, c1L, BoxColor);
   if(ShowTarget)   MakeLine(PFX + "tgt_" + id, c2t, target, tEnd, target, col);
   if(ShowArrows)   MakeArrow(PFX + "arr_" + id, c2t, sweep, dir > 0);
   MakeText(PFX + "txt_" + id, c2t, (dir > 0 ? c2L : c2H), (dir > 0 ? "CRT BUY" : "CRT SELL"), col, dir > 0);

   if(live && AlertPopup)
      Alert(_Symbol + " CRT " + (dir > 0 ? "BUY" : "SELL") + " (" + EnumToString(RangeTF) +
            ")  target " + DoubleToString(target, _Digits));
   if(live && AlertPush)
      SendNotification(_Symbol + " CRT " + (dir > 0 ? "BUY" : "SELL") + " " + EnumToString(RangeTF));
}

//========================= DRAW HELPERS ==========================
void MakeBox(string name, datetime t1, double p1, datetime t2, double p2, color col)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetInteger(0, name, OBJPROP_FILL,  false);
}

void MakeLine(string name, datetime t1, double p1, datetime t2, double p2, color col)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
}

void MakeArrow(string name, datetime t, double price, bool buy)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, buy ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, buy ? BuyColor : SellColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

void MakeText(string name, datetime t, double price, string txt, color col, bool buy)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, buy ? ANCHOR_UPPER : ANCHOR_LOWER);
}

double MAval(int shift)
{
   double t[];
   if(CopyBuffer(hTrend, 0, shift, 1, t) <= 0) return EMPTY_VALUE;
   return t[0];
}
//+------------------------------------------------------------------+

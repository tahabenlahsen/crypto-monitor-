//+------------------------------------------------------------------+
//|                                                  SMC_CRT_EA.mq5  |
//|        Smart Money Concepts engine: CRT + RCT + ICT (MSS/BOS)    |
//|                                                                  |
//|  ARCHITECTURE (read the README): the logic is a SEQUENTIAL state |
//|  machine. A trade only fires when EVERY layer agrees, in order:  |
//|                                                                  |
//|   1) HTF BIAS      (D1/H4 market structure)                      |
//|   2) CRT TRIGGER   (timing candle at NY 01/05/09/13/17/21 that   |
//|                     touches a Key Level AND sweeps liquidity)    |
//|   3) RCT FILTER    (entry must be in Discount for longs /        |
//|                     Premium for shorts -- 50% equilibrium)       |
//|   4) LTF CONFIRM   (M5 Market Structure Shift / BOS after sweep) |
//|   5) ENTRY         (retest of the FVG / Order Block)             |
//|                                                                  |
//|  Risk: SL beyond the manipulation wick. TP1 = 50% of CRT body,   |
//|        TP2 = opposite liquidity.                                 |
//|                                                                  |
//|  This is an ENGINE / STRUCTURE to build on. Detection thresholds |
//|  are deliberately explicit so you can tune them. Test on demo.   |
//+------------------------------------------------------------------+
#property copyright "SMC CRT Engine"
#property version   "0.92"
#property description "Smart Money Concepts: CRT timing + Premium/Discount + MSS/BOS + FVG/OB."

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================//
//                           INPUTS                                 //
//==================================================================//
input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H4;   // HTF: directional bias
input ENUM_TIMEFRAMES InpStructTF  = PERIOD_H1;   // Structure TF (CRT / sweep / zones)
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M5;   // LTF: MSS/BOS confirmation

input group "=== CRT timing (New York) ==="
input string InpCRThours    = "1,5,9,13,17,21";   // CRT candle open hours (NY time)
input int    InpServerToGMT = 3;                  // Broker server time minus GMT (hours): most are +2/+3
input bool   InpAutoDST     = true;               // Auto US DST (NY = GMT-4 summer / GMT-5 winter)
input int    InpNYoffsetGMT = -4;                 // NY offset from GMT if AutoDST is OFF

input group "=== Structure / Zones ==="
input int    InpSwingDepth   = 2;                 // Fractal swing depth (bars each side)
input int    InpScanBars     = 300;               // Bars to scan for structure
input double InpFVGminATR    = 0.10;              // Min FVG size as fraction of ATR
input int    InpZoneExpiry   = 120;               // Discard zones older than N struct-bars
input bool   InpRequireKeyLevel = false;          // CRT must touch an FVG/OB zone (TRUE=stricter, fewer trades)
input bool   InpRequireHTFbias  = true;           // Require clear HTF trend (FALSE=allow ranging both ways)
input int    InpMaxBarsToMSS = 20;                // Sweep must be confirmed by MSS within N LTF bars
input int    InpMaxBarsRetest= 40;                // MSS must be retested within N LTF bars

input group "=== Risk ==="
input double InpRiskPercent  = 0.50;              // Risk per trade (% balance)
input double InpSLbufferATR  = 0.20;              // Extra SL buffer beyond wick (x ATR)
input bool   InpUsePartialTP1= true;              // Take 50% at TP1 (mid of CRT body)
input double InpTP1ClosePct  = 50.0;              // % closed at TP1
input ulong  InpMagic        = 530077;            // Magic number
input bool   InpVerbose      = true;              // Log decisions to Experts tab

//==================================================================//
//                       TYPES & STATE                              //
//==================================================================//
enum ENUM_BIAS { BIAS_NONE=0, BIAS_BULL=1, BIAS_BEAR=-1 };

enum ENUM_ZONE_TYPE { Z_FVG_BULL, Z_FVG_BEAR, Z_OB_BULL, Z_OB_BEAR };

struct SZone
  {
   double         top;
   double         bottom;
   datetime       time;
   ENUM_ZONE_TYPE type;
   bool           mitigated;
   bool           valid;
  };

#define MAX_ZONES 200
SZone g_zones[MAX_ZONES];
int   g_zoneCount = 0;

// --- sequential setup state machine ---
enum ENUM_STATE { ST_IDLE, ST_SWEPT, ST_MSS };
struct SSetup
  {
   ENUM_STATE state;
   int        dir;          // +1 long / -1 short
   double     crtOpen, crtHigh, crtLow, crtClose;
   double     manipWick;    // extreme of manipulation (sweep) candle
   double     rangeHigh, rangeLow;  // dealing range for premium/discount
   int        zoneIndex;    // FVG/OB to retest
   datetime   sweepTime;
   int        barsWaited;   // LTF bars since state change
  };
SSetup g_su;

int      g_atrHandle = INVALID_HANDLE;
int      g_crtHours[];
datetime g_lastStructBar = 0;
datetime g_lastEntryBar  = 0;
datetime g_lastCRTwindow = 0;
double   g_openTP1 = 0;        // persisted TP1 of the live position (setup resets after entry)
double   g_point;
int      g_digits;

//==================================================================//
//                            INIT                                  //
//==================================================================//
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(!ParseHours(InpCRThours, g_crtHours) || ArraySize(g_crtHours)==0)
     {
      Print("ERROR: invalid InpCRThours");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_atrHandle = iATR(_Symbol, InpStructTF, 14);
   if(g_atrHandle==INVALID_HANDLE) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetSetup();
   if(InpVerbose) Print("SMC CRT Engine initialized. CRT hours (NY): ", InpCRThours);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   Comment("");
  }

//==================================================================//
//                            TICK                                  //
//==================================================================//
void OnTick()
  {
   ManageOpenTrade();

   // --- Layer driven by STRUCTURE timeframe new bar ---
   datetime sBar = iTime(_Symbol, InpStructTF, 0);
   if(sBar != g_lastStructBar)
     {
      g_lastStructBar = sBar;
      DetectFVG();              // build / refresh imbalance zones
      ExpireZones();
      CheckCRTtrigger();        // CRT timing + key level + liquidity sweep  (-> ST_SWEPT)
     }

   // --- Layers driven by ENTRY timeframe new bar ---
   static datetime lastEntryTFbar = 0;
   datetime eBar = iTime(_Symbol, InpEntryTF, 0);
   if(eBar != lastEntryTFbar)
     {
      lastEntryTFbar = eBar;
      RunStateMachine();        // MSS confirmation -> retest -> ENTRY
     }

   ShowDashboard();
  }

//==================================================================//
//   LAYER 1: HTF BIAS  (Daily/H4 market structure)                 //
//==================================================================//
ENUM_BIAS HTFBias()
  {
   double h1,h2,l1,l2;
   bool okH = LastTwoSwingHighs(InpTrendTF, InpSwingDepth, InpScanBars, h1, h2);
   bool okL = LastTwoSwingLows (InpTrendTF, InpSwingDepth, InpScanBars, l1, l2);
   if(okH && okL)
     {
      if(h1>h2 && l1>l2) return BIAS_BULL;   // higher highs + higher lows
      if(h1<h2 && l1<l2) return BIAS_BEAR;   // lower highs  + lower lows
     }
   return BIAS_NONE;
  }

//==================================================================//
//   LAYER 2: CRT TRIGGER (timing + key level + liquidity sweep)    //
//==================================================================//
void CheckCRTtrigger()
  {
   if(g_su.state != ST_IDLE) return;          // one setup at a time

   // Has a NEW CRT window just opened? If so, the previous window IS the CRT candle.
   datetime winStart, winEnd;
   if(!JustOpenedCRTwindow(winStart, winEnd)) return;

   double o,h,l,c;
   if(!WindowOHLC(winStart, winEnd, o,h,l,c)) return;

   ENUM_BIAS bias = HTFBias();
   if(InpRequireHTFbias && bias == BIAS_NONE) { if(InpVerbose) Print("CRT: no HTF bias, skip."); return; }
   bool allowLong  = (bias != BIAS_BEAR);   // bull or (none when bias not required)
   bool allowShort = (bias != BIAS_BULL);   // bear or (none when bias not required)

   double atr = ATR();
   // --- Liquidity sweep: CRT candle wicks beyond a prior swing then closes back ---
   double sh1,sh2, sl1,sl2;
   LastTwoSwingHighs(InpStructTF, InpSwingDepth, InpScanBars, sh1, sh2);
   LastTwoSwingLows (InpStructTF, InpSwingDepth, InpScanBars, sl1, sl2);

   // dealing range for premium/discount (RCT)
   double rngHi = MathMax(sh1, h);
   double rngLo = MathMin(sl1, l);
   double eq    = (rngHi + rngLo) / 2.0;

   // BULLISH setup: sweep of SELL-side liquidity (took prior low, closed back above) + bias bull + price in DISCOUNT
   if(allowLong)
     {
      bool sweptSell = (l < sl1 && c > sl1);            // liquidity sweep down
      bool keyLevel  = (!InpRequireKeyLevel || TouchedBullKeyLevel(l, atr)); // touched FVG/OB
      bool discount  = (c < eq);                        // RCT: only buy in discount
      if(sweptSell && keyLevel && discount)
        {
         ArmSetup(+1, o,h,l,c, l, rngHi, rngLo);
         if(InpVerbose) Print("CRT TRIGGER (LONG): swept sell-side @", DoubleToString(sl1,g_digits));
         return;
        }
     }
   // BEARISH setup
   if(allowShort)
     {
      bool sweptBuy = (h > sh1 && c < sh1);
      bool keyLevel = (!InpRequireKeyLevel || TouchedBearKeyLevel(h, atr));
      bool premium  = (c > eq);
      if(sweptBuy && keyLevel && premium)
        {
         ArmSetup(-1, o,h,l,c, h, rngHi, rngLo);
         if(InpVerbose) Print("CRT TRIGGER (SHORT): swept buy-side @", DoubleToString(sh1,g_digits));
         return;
        }
     }
  }

void ArmSetup(int dir,double o,double h,double l,double c,double wick,double rngHi,double rngLo)
  {
   g_su.state     = ST_SWEPT;
   g_su.dir       = dir;
   g_su.crtOpen   = o;  g_su.crtHigh = h;  g_su.crtLow = l;  g_su.crtClose = c;
   g_su.manipWick = wick;
   g_su.rangeHigh = rngHi;  g_su.rangeLow = rngLo;
   g_su.zoneIndex = -1;
   g_su.sweepTime = TimeCurrent();
   g_su.barsWaited= 0;
  }

//==================================================================//
//   LAYERS 4 & 5: MSS confirmation -> retest -> ENTRY              //
//==================================================================//
void RunStateMachine()
  {
   if(g_su.state == ST_IDLE) return;
   g_su.barsWaited++;

   if(g_su.state == ST_SWEPT)
     {
      if(g_su.barsWaited > InpMaxBarsToMSS) { if(InpVerbose) Print("MSS timeout -> reset"); ResetSetup(); return; }

      bool mss = (g_su.dir>0) ? BullishMSS(InpEntryTF) : BearishMSS(InpEntryTF);
      if(mss)
        {
         int zi = FindRetestZone(g_su.dir);   // FVG/OB created by the MSS leg
         g_su.zoneIndex = zi;
         g_su.state     = ST_MSS;
         g_su.barsWaited= 0;
         if(InpVerbose) Print("MSS confirmed on LTF. Waiting retest. zone=", zi);
        }
      return;
     }

   if(g_su.state == ST_MSS)
     {
      if(g_su.barsWaited > InpMaxBarsRetest) { if(InpVerbose) Print("Retest timeout -> reset"); ResetSetup(); return; }

      double price = (g_su.dir>0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double eq = (g_su.rangeHigh + g_su.rangeLow)/2.0;

      // RCT re-check at entry: long only in discount, short only in premium
      bool rctOK = (g_su.dir>0) ? (price < eq) : (price > eq);
      bool retest = PriceInRetestZone(price, g_su.zoneIndex, g_su.dir);

      if(retest && rctOK)
        {
         ExecuteSMCTrade();
         ResetSetup();
        }
     }
  }

//==================================================================//
//   ENTRY + RISK  (SL beyond manipulation wick; TP1 50% CRT body)  //
//==================================================================//
void ExecuteSMCTrade()
  {
   if(g_lastEntryBar == iTime(_Symbol, InpEntryTF, 0)) return;  // one entry/bar
   double atr = ATR();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buf = InpSLbufferATR * atr;

   double entry, sl, tp1, tp2;
   if(g_su.dir > 0)
     {
      entry = ask;
      sl    = g_su.manipWick - buf;                       // below manipulation wick
      tp1   = (g_su.crtOpen + g_su.crtClose)/2.0;          // 50% of CRT body
      tp2   = OppositeLiquidity(+1);                       // buy-side liquidity above
     }
   else
     {
      entry = bid;
      sl    = g_su.manipWick + buf;                       // above manipulation wick
      tp1   = (g_su.crtOpen + g_su.crtClose)/2.0;
      tp2   = OppositeLiquidity(-1);
     }

   double slDist = MathAbs(entry - sl);
   if(slDist <= 0) { if(InpVerbose) Print("Invalid SL distance"); return; }

   // primary target = TP2 (opposite liquidity); TP1 used for partial close in management
   double finalTP = (g_su.dir>0) ? MathMax(tp2, entry + slDist) : MathMin(tp2, entry - slDist);
   double lots = LotsByRisk(slDist);
   if(lots <= 0) { if(InpVerbose) Print("Lots=0, skip"); return; }

   bool ok = (g_su.dir>0)
             ? trade.Buy (lots, _Symbol, 0.0, Norm(sl), Norm(finalTP), "SMC_CRT")
             : trade.Sell(lots, _Symbol, 0.0, Norm(sl), Norm(finalTP), "SMC_CRT");
   if(ok)
     {
      g_lastEntryBar = iTime(_Symbol, InpEntryTF, 0);
      g_openTP1 = tp1;     // persist for partial-close management
      if(InpVerbose) PrintFormat("ENTRY %s lots=%.2f SL=%s TP1=%s TP2=%s",
                                 (g_su.dir>0?"BUY":"SELL"), lots,
                                 DoubleToString(sl,g_digits), DoubleToString(tp1,g_digits),
                                 DoubleToString(finalTP,g_digits));
     }
   else if(InpVerbose) Print("Order failed: ", trade.ResultRetcode());
  }

void ManageOpenTrade()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)  continue;

      bool isBuy = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double curSL = PositionGetDouble(POSITION_SL);
      double cur   = isBuy ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      // Partial TP1 + move SL to breakeven (once). Skip if SL already at breakeven.
      bool beAlready = (MathAbs(curSL - open) < g_point*2);
      if(InpUsePartialTP1 && g_openTP1>0 && !beAlready)
        {
         bool hitTP1 = isBuy ? (cur >= g_openTP1) : (cur <= g_openTP1);
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(hitTP1 && vol > minLot)
           {
            double closeVol = NormalizeVol(vol * InpTP1ClosePct/100.0);
            if(closeVol >= minLot) trade.PositionClosePartial(tk, closeVol);
            trade.PositionModify(tk, Norm(open), PositionGetDouble(POSITION_TP)); // SL -> breakeven
           }
        }
     }
  }

//==================================================================//
//   LIQUIDITY / STRUCTURE / ZONE  HELPERS                          //
//==================================================================//

// ---- fractal swing detection (most recent two) ----
bool LastTwoSwingHighs(ENUM_TIMEFRAMES tf,int depth,int scan,double &h1,double &h2)
  {
   int found=0; double tmp[2];
   for(int i=depth; i<scan-depth && found<2; i++)
     {
      double hi=iHigh(_Symbol,tf,i);
      bool isSwing=true;
      for(int k=1;k<=depth;k++)
         if(iHigh(_Symbol,tf,i+k)>hi || iHigh(_Symbol,tf,i-k)>hi){ isSwing=false; break; }
      if(isSwing){ tmp[found]=hi; found++; }
     }
   if(found<2) return false;
   h1=tmp[0]; h2=tmp[1]; return true;
  }

bool LastTwoSwingLows(ENUM_TIMEFRAMES tf,int depth,int scan,double &l1,double &l2)
  {
   int found=0; double tmp[2];
   for(int i=depth; i<scan-depth && found<2; i++)
     {
      double lo=iLow(_Symbol,tf,i);
      bool isSwing=true;
      for(int k=1;k<=depth;k++)
         if(iLow(_Symbol,tf,i+k)<lo || iLow(_Symbol,tf,i-k)<lo){ isSwing=false; break; }
      if(isSwing){ tmp[found]=lo; found++; }
     }
   if(found<2) return false;
   l1=tmp[0]; l2=tmp[1]; return true;
  }

// ---- LTF Market Structure Shift / Break of Structure ----
bool BullishMSS(ENUM_TIMEFRAMES tf)
  {
   double h1,h2;
   if(!LastTwoSwingHighs(tf, 1, 100, h1, h2)) return false;
   return (iClose(_Symbol,tf,1) > h1);   // closed above last LTF swing high
  }
bool BearishMSS(ENUM_TIMEFRAMES tf)
  {
   double l1,l2;
   if(!LastTwoSwingLows(tf, 1, 100, l1, l2)) return false;
   return (iClose(_Symbol,tf,1) < l1);
  }

// ---- opposite liquidity (TP2) ----
double OppositeLiquidity(int dir)
  {
   double h1,h2,l1,l2;
   if(dir>0){ if(LastTwoSwingHighs(InpStructTF,InpSwingDepth,InpScanBars,h1,h2)) return h1; }
   else     { if(LastTwoSwingLows (InpStructTF,InpSwingDepth,InpScanBars,l1,l2)) return l1; }
   return 0.0;
  }

// ---- Fair Value Gap detection on structure TF (3-candle imbalance) ----
void DetectFVG()
  {
   double atr = ATR();
   double minSize = InpFVGminATR * atr;

   double h3=iHigh(_Symbol,InpStructTF,3), l3=iLow(_Symbol,InpStructTF,3);
   double h1=iHigh(_Symbol,InpStructTF,1), l1=iLow(_Symbol,InpStructTF,1);

   // bullish FVG: gap between high[3] and low[1]
   if(l1 > h3 && (l1 - h3) >= minSize) AddZone(h3, l1, Z_FVG_BULL);
   // bearish FVG: gap between low[3] and high[1]
   if(h1 < l3 && (l3 - h1) >= minSize) AddZone(h1, l3, Z_FVG_BEAR);
  }

void AddZone(double bottom,double top,ENUM_ZONE_TYPE type)
  {
   if(top < bottom){ double t=top; top=bottom; bottom=t; }
   // avoid duplicates
   for(int i=0;i<g_zoneCount;i++)
      if(g_zones[i].valid && g_zones[i].type==type &&
         MathAbs(g_zones[i].top-top)<g_point && MathAbs(g_zones[i].bottom-bottom)<g_point)
         return;

   int idx;
   if(g_zoneCount < MAX_ZONES) idx = g_zoneCount++;
   else { // shift out oldest
      for(int i=1;i<MAX_ZONES;i++) g_zones[i-1]=g_zones[i];
      idx = MAX_ZONES-1;
   }
   g_zones[idx].top=top; g_zones[idx].bottom=bottom; g_zones[idx].time=iTime(_Symbol,InpStructTF,1);
   g_zones[idx].type=type; g_zones[idx].mitigated=false; g_zones[idx].valid=true;
  }

void ExpireZones()
  {
   datetime cutoff = iTime(_Symbol, InpStructTF, InpZoneExpiry);
   for(int i=0;i<g_zoneCount;i++)
      if(g_zones[i].valid && g_zones[i].time < cutoff) g_zones[i].valid=false;
  }

// ---- did the CRT low/high touch a bullish/bearish zone or key level? ----
bool TouchedBullKeyLevel(double crtLow,double atr)
  {
   for(int i=0;i<g_zoneCount;i++)
     {
      if(!g_zones[i].valid || g_zones[i].mitigated) continue;
      if(g_zones[i].type==Z_FVG_BULL || g_zones[i].type==Z_OB_BULL)
         if(crtLow <= g_zones[i].top + atr*0.1 && crtLow >= g_zones[i].bottom - atr*0.5)
            return true;
     }
   return false;
  }
bool TouchedBearKeyLevel(double crtHigh,double atr)
  {
   for(int i=0;i<g_zoneCount;i++)
     {
      if(!g_zones[i].valid || g_zones[i].mitigated) continue;
      if(g_zones[i].type==Z_FVG_BEAR || g_zones[i].type==Z_OB_BEAR)
         if(crtHigh >= g_zones[i].bottom - atr*0.1 && crtHigh <= g_zones[i].top + atr*0.5)
            return true;
     }
   return false;
  }

// ---- find a zone to retest after the MSS ----
int FindRetestZone(int dir)
  {
   for(int i=g_zoneCount-1;i>=0;i--)
     {
      if(!g_zones[i].valid || g_zones[i].mitigated) continue;
      if(dir>0 && (g_zones[i].type==Z_FVG_BULL || g_zones[i].type==Z_OB_BULL)) return i;
      if(dir<0 && (g_zones[i].type==Z_FVG_BEAR || g_zones[i].type==Z_OB_BEAR)) return i;
     }
   return -1;
  }

bool PriceInRetestZone(double price,int zi,int dir)
  {
   if(zi<0 || zi>=g_zoneCount || !g_zones[zi].valid) return false;
   bool inside = (price <= g_zones[zi].top && price >= g_zones[zi].bottom);
   if(inside) g_zones[zi].mitigated=true;
   return inside;
  }

//==================================================================//
//   CRT TIMING (New York hours, DST aware)                         //
//==================================================================//
bool ParseHours(string csv, int &arr[])
  {
   string parts[];
   int n = StringSplit(csv, ',', parts);
   if(n<=0) return false;
   ArrayResize(arr, n);
   for(int i=0;i<n;i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      arr[i] = (int)StringToInteger(s);
     }
   return true;
  }

int NYoffsetFromGMT(datetime gmt)
  {
   if(!InpAutoDST) return InpNYoffsetGMT;
   return IsUSDST(gmt) ? -4 : -5;
  }

// US DST: 2nd Sunday of March 02:00 -> 1st Sunday of November 02:00
bool IsUSDST(datetime gmt)
  {
   MqlDateTime t; TimeToStruct(gmt, t);
   int y=t.year, mo=t.mon, d=t.day;
   if(mo>3 && mo<11) return true;
   if(mo<3 || mo>11) return false;
   // compute the changeover Sundays
   int marSun = SecondSundayMarch(y);
   int novSun = FirstSundayNov(y);
   if(mo==3)  return (d>marSun || (d==marSun && t.hour>=2));
   if(mo==11) return (d<novSun || (d==novSun && t.hour<2));
   return false;
  }
int SecondSundayMarch(int year)
  {
   MqlDateTime t; t.year=year; t.mon=3; t.day=1; t.hour=0; t.min=0; t.sec=0;
   datetime d1=StructToTime(t);
   MqlDateTime w; TimeToStruct(d1,w);
   int firstSun = 1 + ((7 - w.day_of_week) % 7);
   return firstSun + 7;
  }
int FirstSundayNov(int year)
  {
   MqlDateTime t; t.year=year; t.mon=11; t.day=1; t.hour=0; t.min=0; t.sec=0;
   datetime d1=StructToTime(t);
   MqlDateTime w; TimeToStruct(d1,w);
   return 1 + ((7 - w.day_of_week) % 7);
  }

// current NY hour from server time
int CurrentNYHour()
  {
   datetime gmt = TimeCurrent() - (long)InpServerToGMT*3600;   // server -> GMT
   datetime ny  = gmt + (long)NYoffsetFromGMT(gmt)*3600;
   MqlDateTime t; TimeToStruct(ny, t);
   return t.hour;
  }

// Detect that a NEW CRT window just opened; return the PREVIOUS window [start,end) in server time.
bool JustOpenedCRTwindow(datetime &winStart, datetime &winEnd)
  {
   int nyHour = CurrentNYHour();
   bool isCRT=false;
   for(int i=0;i<ArraySize(g_crtHours);i++) if(g_crtHours[i]==nyHour){ isCRT=true; break; }
   if(!isCRT) return false;

   // align to the current struct bar; only fire once per window
   datetime now = iTime(_Symbol, InpStructTF, 0);
   if(now == g_lastCRTwindow) return false;
   g_lastCRTwindow = now;

   // previous CRT window = [now-4h, now)  (CRT cadence is 4h)
   winEnd   = now;
   winStart = now - 4*3600;
   return true;
  }

bool WindowOHLC(datetime startT,datetime endT,double &o,double &h,double &l,double &c)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, InpStructTF, startT, endT, r);
   if(n<=0) return false;
   o=r[0].open; c=r[n-1].close; h=-DBL_MAX; l=DBL_MAX;
   for(int i=0;i<n;i++){ if(r[i].high>h) h=r[i].high; if(r[i].low<l) l=r[i].low; }
   return true;
  }

//==================================================================//
//                      RISK / UTILITIES                            //
//==================================================================//
double ATR()
  {
   double a[1];
   if(CopyBuffer(g_atrHandle,0,1,1,a)<1) return 0.0;
   return a[0];
  }

double LotsByRisk(double slDist)
  {
   double risk = AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskPercent/100.0;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||slDist<=0) return 0;
   double lossPerLot = slDist/ts*tv;
   if(lossPerLot<=0) return 0;
   return NormalizeVol(risk/lossPerLot);
  }

double NormalizeVol(double lots)
  {
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); if(st<=0) st=0.01;
   lots=MathFloor(lots/st)*st;
   lots=MathMax(lots,mn); lots=MathMin(lots,mx);
   return lots;
  }

double Norm(double price){ return NormalizeDouble(price, g_digits); }

void ResetSetup()
  {
   g_su.state=ST_IDLE; g_su.dir=0; g_su.zoneIndex=-1; g_su.barsWaited=0;
   g_su.crtOpen=g_su.crtHigh=g_su.crtLow=g_su.crtClose=0;
   g_su.manipWick=g_su.rangeHigh=g_su.rangeLow=0;
  }

void ShowDashboard()
  {
   string st = (g_su.state==ST_IDLE?"IDLE": g_su.state==ST_SWEPT?"SWEPT (await MSS)":"MSS (await retest)");
   string bias = (HTFBias()==BIAS_BULL?"BULL": HTFBias()==BIAS_BEAR?"BEAR":"NONE");
   Comment(StringFormat(
      "SMC CRT Engine  |  %s\n"
      "----------------------------------\n"
      "HTF bias:   %s\n"
      "Setup:      %s  (dir %d)\n"
      "Zones:      %d\n"
      "NY hour:    %d\n",
      _Symbol, bias, st, g_su.dir, CountValidZones(), CurrentNYHour()));
  }
int CountValidZones(){ int n=0; for(int i=0;i<g_zoneCount;i++) if(g_zones[i].valid) n++; return n; }
//+------------------------------------------------------------------+

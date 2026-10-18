// PairsSpread (L4): a two symbol spread trade. Hedge ratio by least squares of the log prices over InpLookback closed bars,
// z score of the spread over the same window; short the spread above +InpEntryZ, long it below -InpEntryZ, out inside +-InpExitZ,
// at +-InpStopZ, or after InpMaxBars bars. Long the spread = buy Y and sell X; the X leg is beta times the value of the Y leg.
// Optional check that the spread still mean reverts: AR(1) fit of its changes, half life and t value. Educational bot, no claim of any edge.
// Run it on the chart (and in the tester on the symbol) of InpSymbolY. Both symbols need history on the chart timeframe.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "Pairs spread: hedge ratio, z score, value neutral legs. Educational bot, no claim of any edge."
#include <Trade\Trade.mqh>

input string         InpSymbolX    = "AUDUSD";         // Symbol X (the hedge leg)
input string         InpSymbolY    = "";               // Symbol Y (the main leg), empty = the chart symbol
input int            InpLookback   = 200;              // Bars for the hedge ratio and the z score
input double         InpEntryZ     = 2.0;              // Enter beyond this z
input double         InpExitZ      = 0.5;              // Exit inside this z
input double         InpStopZ      = 4.0;              // Stop beyond this z
input int            InpMaxBars    = 100;              // Close after N bars, 0 = off
input int            InpRecalcBars = 1;                // Recompute the hedge ratio every N bars (the z score is updated every bar)
input bool           InpUseCointCheck = true;          // Enter only while the spread mean reverts (half life and t value)
input double         InpMaxHalfLife = 50.0;            // Maximum half life in bars
input double         InpMaxTValue  = -2.0;             // AR(1) t value must be below this
input double         InpLegValuePct = 50.0;            // Value of the Y leg in % of the balance
input long           InpMagic      = 4747;             // Magic number

CTrade   trade;
string   g_x, g_y;
datetime lastBar = 0;
double   g_alpha = 0, g_beta = 0;        // hedge fit ln Y = alpha + beta ln X
int      g_fitAge = 1000000;
double   g_z = 0, g_half = 0, g_t = 0;
bool     g_coint = false;
int      g_side = 0;                     // 1 long spread, -1 short spread, 0 flat
datetime g_entryBar = 0;
bool     g_closing = false;              // an exit decided on this bar is still going through
int      g_pending = 0;                  // entry decided on this bar, tried on every tick while the market refuses it
int      g_tries = 0;

bool HaveLeg(string sym, long &type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      type = PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

bool HaveAnyLeg()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic) return true;
   }
   return false;
}

// Closes both legs; true when nothing is left (a refused close, at the daily break for example, is tried again on the next tick)
bool CloseLegs()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      trade.PositionClose(t);
   }
   if(HaveAnyLeg()) return false;
   g_side = 0;
   return true;
}

// Closes of both symbols on the same closed bar times, newest first: y[0], x[0] = shift 1 of Y. Returns the number of aligned bars.
// X is read from its current bar too: at the first tick of a new Y bar, X may not have ticked into the new bar yet, so its last bar
// before the new Y bar can still be marked as forming even though it is complete. Only X bars older than the new Y bar are used.
int Aligned(double &y[], double &x[], int need)
{
   MqlRates ry[], rx[];
   ArraySetAsSeries(ry, true);
   ArraySetAsSeries(rx, true);
   int ny = CopyRates(g_y, _Period, 1, need + 50, ry), nx = CopyRates(g_x, _Period, 0, need + 400, rx);
   if(ny <= 0 || nx <= 0) return 0;
   ArrayResize(y, need);
   ArrayResize(x, need);
   int n = 0, j = 0;
   datetime now = iTime(g_y, _Period, 0);
   while(j < nx && rx[j].time >= now) j++;               // X bars of the new Y bar or later are not closed
   for(int i = 0; i < ny && n < need; i++)
   {
      while(j < nx && rx[j].time > ry[i].time) j++;
      if(j >= nx) break;
      if(rx[j].time != ry[i].time) continue;
      y[n] = MathLog(ry[i].close);
      x[n] = MathLog(rx[j].close);
      n++;
   }
   return n;
}

// Hedge fit, z score and the mean reversion check of the spread over the window
bool Stats()
{
   double y[], x[];
   int n = Aligned(y, x, InpLookback);
   if(n < InpLookback) return false;
   if(g_fitAge >= MathMax(1, InpRecalcBars))
   {
      double mx = 0, my = 0;
      for(int i = 0; i < n; i++) { mx += x[i]; my += y[i]; }
      mx /= n; my /= n;
      double sxy = 0, sxx = 0;
      for(int i = 0; i < n; i++) { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx); }
      if(sxx <= 0) return false;
      g_beta = sxy / sxx;
      g_alpha = my - g_beta * mx;
      g_fitAge = 0;
   }
   g_fitAge++;
   double s[];
   ArrayResize(s, n);
   double m = 0;
   for(int i = 0; i < n; i++) { s[i] = y[i] - g_alpha - g_beta * x[i]; m += s[i]; }
   m /= n;
   double v = 0;
   for(int i = 0; i < n; i++) v += (s[i] - m) * (s[i] - m);
   double sd = MathSqrt(v / (n - 1));
   if(sd <= 0) return false;
   g_z = (s[0] - m) / sd;
   // AR(1) of the changes: ds[t] = a + b * s[t-1], oldest to newest
   double sx = 0, sy = 0, sxx2 = 0, sxy2 = 0;
   int k = n - 1;
   for(int i = n - 1; i >= 1; i--)
   {
      double lag = s[i], d = s[i - 1] - s[i];
      sx += lag; sy += d; sxx2 += lag * lag; sxy2 += lag * d;
   }
   double den = k * sxx2 - sx * sx;
   if(den <= 0) return false;
   double b = (k * sxy2 - sx * sy) / den, a = (sy - b * sx) / k;
   double rss = 0;
   for(int i = n - 1; i >= 1; i--) { double e = (s[i - 1] - s[i]) - a - b * s[i]; rss += e * e; }
   double se = MathSqrt(rss / (k - 2) / (sxx2 - sx * sx / k));
   g_t = se > 0 ? b / se : 0;
   g_half = (b < 0 && b > -1) ? -MathLog(2.0) / MathLog(1 + b) : 1e9;
   g_coint = g_half <= InpMaxHalfLife && g_t < InpMaxTValue;
   return true;
}

// Lots of a leg worth `value` in the account currency
double LegLots(string sym, double value)
{
   double px = SymbolInfoDouble(sym, SYMBOL_BID), tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(px <= 0 || tv <= 0 || ts <= 0) return 0;
   double perLot = px * tv / ts;                         // value of one lot in the account currency
   double lots = MathFloor(value / perLot / step + 1e-9) * step;
   return lots < vmin ? 0 : MathMin(lots, vmax);
}

bool OpenSpread(int side)
{
   double valueY = AccountInfoDouble(ACCOUNT_BALANCE) * InpLegValuePct / 100.0;
   double ly = LegLots(g_y, valueY), lx = LegLots(g_x, MathAbs(g_beta) * valueY);
   if(ly <= 0 || lx <= 0) return false;
   bool buyY = side > 0, buyX = (side > 0) == (g_beta < 0);  // long spread: buy Y, sell beta of X (buy X when beta is negative)
   trade.SetTypeFillingBySymbol(g_y);
   bool okY = buyY ? trade.Buy(ly, g_y) : trade.Sell(ly, g_y);
   if(!okY) return false;
   trade.SetTypeFillingBySymbol(g_x);
   bool okX = buyX ? trade.Buy(lx, g_x) : trade.Sell(lx, g_x);
   if(!okX) { g_closing = !CloseLegs(); return false; }  // never keep one naked leg
   g_side = side;
   g_entryBar = iTime(g_y, _Period, 0);
   PrintFormat("PAIRS %s spread z=%.2f beta=%.3f lots Y %.2f X %.2f half=%.1f t=%.2f", side > 0 ? "long" : "short", g_z, g_beta, ly, lx, g_half, g_t);
   return true;
}

int OnInit()
{
   g_y = InpSymbolY != "" ? InpSymbolY : _Symbol;
   g_x = InpSymbolX;
   if(g_x == g_y || !SymbolSelect(g_x, true) || !SymbolSelect(g_y, true)) { Print("PairsSpread: two different symbols are needed"); return INIT_FAILED; }
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("PairsSpread finished");
}

void OnTick()
{
   datetime bar = iTime(g_y, _Period, 0);
   if(bar != lastBar)
   {
      lastBar = bar;
      g_pending = 0;
      g_tries = 0;
      long ty = 0, tx = 0;
      bool hy = HaveLeg(g_y, ty), hx = HaveLeg(g_x, tx);
      if(g_side != 0 && (!hy || !hx)) g_closing = true;  // a leg went missing (closed outside), close the rest
      if(Stats())
      {
         if(g_side != 0)
         {
            int age = iBarShift(g_y, _Period, g_entryBar);
            if(MathAbs(g_z) < InpExitZ || MathAbs(g_z) > InpStopZ || (InpMaxBars > 0 && age >= InpMaxBars)) g_closing = true;
         }
         else if(!InpUseCointCheck || g_coint)            // no new entry on a bar that has an exit
         {
            if(g_z > InpEntryZ && g_z < InpStopZ) g_pending = -1;
            else if(g_z < -InpEntryZ && g_z > -InpStopZ) g_pending = 1;
         }
      }
   }
   if(g_closing)
   {
      if(!CloseLegs()) return;
      g_closing = false;
      g_pending = 0;
   }
   if(g_pending == 0 || g_side != 0 || HaveAnyLeg()) return;
   if(OpenSpread(g_pending) || ++g_tries > 60) g_pending = 0;
}

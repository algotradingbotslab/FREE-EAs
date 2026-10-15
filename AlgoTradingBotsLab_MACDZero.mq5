// MACDZero: MACD line crossing the zero line
// Entry: MACD(12,26,9) main line crosses above zero to buy, below zero to sell.
// Exit: Opposite zero cross, or the ATR stop.
// Typical timeframe: H1. Educational bot, no claim of any statistical edge.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "MACD line crossing the zero line"
#include <Trade\Trade.mqh>

enum ENUM_DIR_MODE { DIR_BOTH = 0, DIR_LONG_ONLY = 1, DIR_SHORT_ONLY = 2 };

input int            InpMacdFast   = 12;               // MACD fast EMA
input int            InpMacdSlow   = 26;               // MACD slow EMA
input int            InpMacdSig    = 9;                // MACD signal period
input double         InpLots       = 0.10;             // Fixed lot size
input int            InpAtrPer     = 14;               // ATR period
input ENUM_TIMEFRAMES InpAtrTF     = PERIOD_CURRENT;   // ATR timeframe
input double         InpSLatr      = 2.0;              // Stop loss in ATR
input double         InpTPatr      = 0.0;              // Take profit in ATR, 0 = none
input double         InpTrailArm   = 0.0;              // Trail arms at profit in ATR, 0 = off
input double         InpTrailDist  = 1.5;              // Trail distance in ATR
input int            InpMaxBars    = 0;                // Close after N bars, 0 = off
input bool           InpExitOnSignal = true;           // Use the bot's own exit rule
input bool           InpUseSession = false;            // Session filter on
input int            InpSessStart  = 7;                // Session start hour, server time
input int            InpSessEnd    = 17;               // Session end hour, server time
input bool           InpUseTrend   = false;            // Trend filter on
input int            InpTrendMA    = 200;              // Trend filter MA period
input bool           InpUseAdx     = false;            // Regime filter (ADX) on
input int            InpAdxPer     = 14;               // ADX period
input double         InpAdxLevel   = 25.0;             // ADX level
input bool           InpAdxAbove   = true;             // true = pass above the level, false = below
input bool           InpUseVol     = false;            // Volatility filter on
input int            InpVolBars    = 100;              // Bars for the ATR average
input bool           InpUseWeekday = false;            // Skip Monday and Friday
input ENUM_DIR_MODE  InpDirection  = DIR_BOTH;         // Trade direction
input long           InpMagic      = 4715;             // Magic number

CTrade   trade;
bool     g_trailArmed = false;
int      hAtr = INVALID_HANDLE, hTrend = INVALID_HANDLE, hAdx = INVALID_HANDLE;
int      hMacd = INVALID_HANDLE;
datetime lastBar = 0;
double   entryAtr = 0;
double   g_slDist = 0, g_tpDist = 0;     // stop and target distance a signal may set, 0 = use the ATR inputs
int      g_sig = 0;                      // signal of the current bar, exits use this one
bool     g_entryDone = true;             // the entry decision of this bar has been made
string   g_wantClose = "";               // reason of a close that still has to go through
bool     g_canRetry = false;             // the last order failed in a way worth another try
int      g_retries = 0;                  // retries spent on the current bar

double Buf(int handle, int buffer, int shift)
{
   double b[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, buffer, shift, 1, b) != 1) return EMPTY_VALUE;
   return b[0];
}

bool AnyEmpty(double a, double b = 0, double c = 0, double d = 0)
{
   return a == EMPTY_VALUE || b == EMPTY_VALUE || c == EMPTY_VALUE || d == EMPTY_VALUE;
}

double Op(int s) { return iOpen(_Symbol, _Period, s); }
double Hi(int s) { return iHigh(_Symbol, _Period, s); }
double Lo(int s) { return iLow(_Symbol, _Period, s); }
double Cl(int s) { return iClose(_Symbol, _Period, s); }

int CrossOf(double a1, double a2, double b1, double b2)
{
   if(a2 <= b2 && a1 > b1) return 1;
   if(a2 >= b2 && a1 < b1) return -1;
   return 0;
}

bool Opposite(bool isBuy, int sig) { return isBuy ? sig < 0 : sig > 0; }
double ClampDist(double d, double atr) { return MathMax(0.5 * atr, MathMin(4.0 * atr, d)); }
double Atr() { return Buf(hAtr, 0, 1); }
bool HavePosition() { return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagic; }

// Entry signal from the last closed bar: 1 buy, -1 sell, 0 none. Called once per new bar.
int Signal()
{
   double m1 = Buf(hMacd, 0, 1), m2 = Buf(hMacd, 0, 2);
   if(AnyEmpty(m1, m2)) return 0;
   return CrossOf(m1, m2, 0, 0);
}

// The bot's own exit rule, checked once per new bar while a position is open.
bool ExitNow(bool isBuy, int sig)
{
   return Opposite(isBuy, sig);
}

// Time based flat rule, applied even when InpExitOnSignal is off.
bool ForceExit(bool isBuy)
{
   return false;
}

bool SessionOk()
{
   if(!InpUseSession) return true;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   return t.hour >= InpSessStart && t.hour < InpSessEnd;
}

bool TrendOk(bool isBuy)
{
   if(!InpUseTrend) return true;
   double ma = Buf(hTrend, 0, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   if(ma == EMPTY_VALUE) return false;
   return isBuy ? close1 > ma : close1 < ma;
}

bool AdxOk()
{
   if(!InpUseAdx) return true;
   double a = Buf(hAdx, 0, 1);
   if(a == EMPTY_VALUE) return false;
   return InpAdxAbove ? a > InpAdxLevel : a < InpAdxLevel;
}

bool VolOk()
{
   if(!InpUseVol) return true;
   double a[];
   int n = CopyBuffer(hAtr, 0, 1, InpVolBars, a);
   if(n < InpVolBars) return false;
   double sum = 0;
   for(int i = 0; i < n; i++) sum += a[i];
   return a[n - 1] > sum / n;
}

bool WeekdayOk()
{
   if(!InpUseWeekday) return true;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   return t.day_of_week >= 2 && t.day_of_week <= 4;
}

bool DirectionOk(bool isBuy)
{
   return InpDirection == DIR_BOTH || (InpDirection == DIR_LONG_ONLY) == isBuy;
}

bool FiltersOk(bool isBuy)
{
   return DirectionOk(isBuy) && WeekdayOk() && SessionOk() && TrendOk(isBuy) && AdxOk() && VolOk();
}

double LotSize()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathFloor(InpLots / step + 1e-9) * step);
}

// Order failures worth another try on the next tick of the same bar: the closed market at the daily rollover, and the very wide
// spread right after it that puts the stop inside the spread (invalid stops)
bool RetriableCode(uint rc)
{
   return rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_REQUOTE ||
          rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TIMEOUT ||
          rc == TRADE_RETCODE_INVALID_STOPS;
}

// Called when an entry order went through
void OnEntered(bool isBuy)
{

}

bool Open(bool isBuy)
{
   g_canRetry = false;
   double atr = Atr();
   if(atr == EMPTY_VALUE || atr <= 0) return false;
   double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slD = g_slDist > 0 ? g_slDist : InpSLatr * atr;
   double tpD = g_tpDist > 0 ? g_tpDist : InpTPatr * atr;
   double sl = slD > 0 ? NormalizeDouble(isBuy ? px - slD : px + slD, _Digits) : 0;
   double tp = tpD > 0 ? NormalizeDouble(isBuy ? px + tpD : px - tpD, _Digits) : 0;
   entryAtr = atr;
   bool ok = isBuy ? trade.Buy(LotSize(), _Symbol, px, sl, tp) : trade.Sell(LotSize(), _Symbol, px, sl, tp);
   g_canRetry = !ok && RetriableCode(trade.ResultRetcode());
   if(g_canRetry) g_retries++;
   if(ok) OnEntered(isBuy);
   return ok;
}

bool CloseOwn(string reason)
{
   bool ok = trade.PositionClose(_Symbol);
   g_canRetry = !ok && RetriableCode(trade.ResultRetcode());
   if(g_canRetry) g_retries++;
   return ok;
}

// Runs on every tick: finishes a close and then the entry decided on this bar, retrying only while the market is closed
void Act()
{
   if(g_retries > 60) { g_wantClose = ""; g_entryDone = true; }       // a problem that does not go away within this bar, wait for the next bar
   if(g_wantClose != "")
   {
      if(HavePosition() && !CloseOwn(g_wantClose) && !g_canRetry) g_wantClose = "";
      if(!HavePosition()) g_wantClose = "";
   }
   if(g_entryDone || g_sig == 0 || g_wantClose != "") return;
   g_entryDone = true;
   if(HavePosition()) return;
   bool isBuy = g_sig > 0;
   if(FiltersOk(isBuy) && !Open(isBuy) && g_canRetry) g_entryDone = false;
}

void Trail()
{
   if(!HavePosition()) { g_trailArmed = false; return; }
   if(InpTrailArm <= 0) return;
   bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
   double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
   double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profit = isBuy ? px - open : open - px;
   if(!g_trailArmed)
   {
      if(profit < InpTrailArm * entryAtr) return;
      g_trailArmed = true;
   }
   double want = isBuy ? px - InpTrailDist * entryAtr : px + InpTrailDist * entryAtr;
   bool better = isBuy ? want > sl + 0.1 * entryAtr : (sl == 0 || want < sl - 0.1 * entryAtr);
   if(better) trade.PositionModify(_Symbol, NormalizeDouble(want, _Digits), PositionGetDouble(POSITION_TP));
}

int OnInit()
{

   hAtr = iATR(_Symbol, InpAtrTF, InpAtrPer);
   if(InpUseTrend) hTrend = iMA(_Symbol, _Period, InpTrendMA, 0, MODE_SMA, PRICE_CLOSE);
   if(InpUseAdx) hAdx = iADX(_Symbol, _Period, InpAdxPer);
   if(hAtr == INVALID_HANDLE || (InpUseTrend && hTrend == INVALID_HANDLE) || (InpUseAdx && hAdx == INVALID_HANDLE)) return INIT_FAILED;
   hMacd = iMACD(_Symbol, _Period, InpMacdFast, InpMacdSlow, InpMacdSig, PRICE_CLOSE);
   if(hMacd == INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   Trail();
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar != lastBar)
   {
      lastBar = bar;
      g_slDist = 0;
      g_tpDist = 0;
      g_sig = Signal();
      g_entryDone = false;
      g_retries = 0;
      g_wantClose = "";
      if(HavePosition())
      {
         bool held = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
         int age = iBarShift(_Symbol, _Period, (datetime)PositionGetInteger(POSITION_TIME));
         if(InpMaxBars > 0 && age >= InpMaxBars) g_wantClose = "TIMER";
         else if(ForceExit(held)) g_wantClose = "TIMER";
         else if(InpExitOnSignal && ExitNow(held, g_sig)) g_wantClose = "SIGNAL";
      }
   }
   Act();
}

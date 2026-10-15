#property copyright "AlgoTradingBotsLab"
#property strict
#property description "MA crossover demo bot with optional session and trend filters, ATR stops, trailing and timer exit"
#include <Trade\Trade.mqh>

input int            InpFast       = 20;         // Fast MA period
input int            InpSlow       = 50;         // Slow MA period
input ENUM_MA_METHOD InpMethod     = MODE_SMA;   // MA method
input double         InpLots       = 0.10;       // Fixed lot size
input int            InpAtrPer     = 14;         // ATR period
input double         InpSLatr      = 2.0;        // Stop loss in ATR
input double         InpTPatr      = 0.0;        // Take profit in ATR, 0 = none
input double         InpTrailArm   = 0.0;        // Trail arms at profit in ATR, 0 = off
input double         InpTrailDist  = 1.5;        // Trail distance in ATR
input int            InpMaxBars    = 0;          // Close after N bars, 0 = off
input bool           InpExitOnCross = true;      // Close on opposite crossover
input bool           InpUseSession = false;      // Session filter on
input int            InpSessStart  = 7;          // Session start hour, server time
input int            InpSessEnd    = 17;         // Session end hour, server time
input bool           InpUseTrend   = false;      // Trend filter on
input int            InpTrendMA    = 200;        // Trend filter MA period
input long           InpMagic      = 4710;       // Magic number

CTrade   trade;
bool     g_trailArmed = false;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hTrend = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime lastBar = 0;
double   entryAtr = 0;

double Buf(int handle, int shift)
{
   double b[1];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return EMPTY_VALUE;
   return b[0];
}

int OnInit()
{
   hFast = iMA(_Symbol, _Period, InpFast, 0, InpMethod, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpSlow, 0, InpMethod, PRICE_CLOSE);
   hTrend = iMA(_Symbol, _Period, InpTrendMA, 0, MODE_SMA, PRICE_CLOSE);
   hAtr = iATR(_Symbol, _Period, InpAtrPer);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hTrend == INVALID_HANDLE || hAtr == INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

bool HavePosition() { return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagic; }

bool SessionOk()
{
   if(!InpUseSession) return true;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   return t.hour >= InpSessStart && t.hour < InpSessEnd;
}

bool TrendOk(bool isBuy)
{
   if(!InpUseTrend) return true;
   double ma = Buf(hTrend, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   if(ma == EMPTY_VALUE) return false;
   return isBuy ? close1 > ma : close1 < ma;
}

void Open(bool isBuy)
{
   double atr = Buf(hAtr, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathFloor(InpLots / step + 1e-9) * step);
   double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = InpSLatr > 0 ? (isBuy ? px - InpSLatr * atr : px + InpSLatr * atr) : 0;
   double tp = InpTPatr > 0 ? (isBuy ? px + InpTPatr * atr : px - InpTPatr * atr) : 0;
   entryAtr = atr;
   if(isBuy) trade.Buy(lots, _Symbol, px, sl, tp); else trade.Sell(lots, _Symbol, px, sl, tp);
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

void OnTick()
{
   Trail();
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar == lastBar) return;
   lastBar = bar;

   // timer exit, counted in bars of the chart timeframe
   if(InpMaxBars > 0 && HavePosition())
   {
      int age = iBarShift(_Symbol, _Period, (datetime)PositionGetInteger(POSITION_TIME));
      if(age >= InpMaxBars) trade.PositionClose(_Symbol);
   }

   double f1 = Buf(hFast, 1), f2 = Buf(hFast, 2), s1 = Buf(hSlow, 1), s2 = Buf(hSlow, 2);
   if(f1 == EMPTY_VALUE || f2 == EMPTY_VALUE || s1 == EMPTY_VALUE || s2 == EMPTY_VALUE) return;
   bool up = f2 <= s2 && f1 > s1;
   bool dn = f2 >= s2 && f1 < s1;
   if(HavePosition() && InpExitOnCross && (up || dn))
   {
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if((isBuy && dn) || (!isBuy && up)) trade.PositionClose(_Symbol);
   }
   if(HavePosition()) return;
   if(!SessionOk()) return;
   if(up && TrendOk(true)) Open(true);
   else if(dn && TrendOk(false)) Open(false);
}

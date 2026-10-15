#property strict
#property description "MA crossover demo bot with optional session and trend filters, ATR stops, trailing and timer exit"
#include <Trade\Trade.mqh>
#include <CLAUDE-VIDEOS\VideoLog.mqh>

input string         InpTag        = "run";      // Run tag, names the log folder
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
input int            InpControlSeed = 0;         // Random entry control seed, 0 = off
input double         InpControlProb = 0.006;     // Control entry chance per bar
input int            InpLogEquitySec = 300;      // Equity log interval in seconds
input bool           InpDiag       = false;      // Write diag.csv with the bar and indicator values the bot saw (checks, not for studies)

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hTrend = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime lastBar = 0;
double   entryAtr = 0;
int      g_diag = INVALID_HANDLE;

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
   if(InpControlSeed > 0) MathSrand(InpControlSeed);
   VL_Init(InpTag, InpLogEquitySec);
   if(InpDiag)
   {
      g_diag = FileOpen(g_vl_dir + "diag.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(g_diag != INVALID_HANDLE) FileWrite(g_diag, "tick_time", "bar1_time", "o1", "h1", "l1", "c1", "fast1", "fast2", "slow1", "slow2", "atr1", "up", "dn", "bid", "ask", "bar0_time", "bar0_open");
   }
   PrintFormat("MACross inputs tag=%s fast=%d slow=%d lots=%.2f sl=%.1f tp=%.1f arm=%.1f maxbars=%d sess=%d trend=%d",
               InpTag, InpFast, InpSlow, InpLots, InpSLatr, InpTPatr, InpTrailArm, InpMaxBars, (int)InpUseSession, (int)InpUseTrend);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
      VL_Event("CLOSE", PositionGetInteger(POSITION_TICKET), PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell",
               PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_CURRENT), 0, 0, "END", PositionGetDouble(POSITION_PROFIT));
   if(g_diag != INVALID_HANDLE) FileClose(g_diag);
   VL_Done();
   Print("MACross finished");
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   VL_OnTradeTransaction(trans, request, result);
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
   if(InpTrailArm <= 0 || !HavePosition()) return;
   bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
   double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
   double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profit = isBuy ? px - open : open - px;
   if(!g_vl_trail_armed)
   {
      if(profit < InpTrailArm * entryAtr) return;
      g_vl_trail_armed = true;
      VL_Event("TRAIL_ARM", PositionGetInteger(POSITION_TICKET), isBuy ? "buy" : "sell", PositionGetDouble(POSITION_VOLUME), px, sl, PositionGetDouble(POSITION_TP));
   }
   double want = isBuy ? px - InpTrailDist * entryAtr : px + InpTrailDist * entryAtr;
   bool better = isBuy ? want > sl + 0.1 * entryAtr : (sl == 0 || want < sl - 0.1 * entryAtr);
   if(better && trade.PositionModify(_Symbol, NormalizeDouble(want, _Digits), PositionGetDouble(POSITION_TP)))
      VL_Event("SL_MOVE", PositionGetInteger(POSITION_TICKET), isBuy ? "buy" : "sell", PositionGetDouble(POSITION_VOLUME), px, want, PositionGetDouble(POSITION_TP));
}

void OnTick()
{
   VL_Tick();
   Trail();
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar == lastBar) return;
   lastBar = bar;

   // timer exit, counted in bars of the chart timeframe
   if(InpMaxBars > 0 && HavePosition())
   {
      int age = iBarShift(_Symbol, _Period, (datetime)PositionGetInteger(POSITION_TIME));
      if(age >= InpMaxBars) { g_vl_pending = "TIMER"; trade.PositionClose(_Symbol); }
   }

   double f1 = Buf(hFast, 1), f2 = Buf(hFast, 2), s1 = Buf(hSlow, 1), s2 = Buf(hSlow, 2);
   if(f1 == EMPTY_VALUE || f2 == EMPTY_VALUE || s1 == EMPTY_VALUE || s2 == EMPTY_VALUE) return;
   bool up = f2 <= s2 && f1 > s1;
   bool dn = f2 >= s2 && f1 < s1;
   if(g_diag != INVALID_HANDLE)
      FileWrite(g_diag, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), TimeToString(iTime(_Symbol, _Period, 1), TIME_DATE | TIME_SECONDS),
                DoubleToString(iOpen(_Symbol, _Period, 1), _Digits), DoubleToString(iHigh(_Symbol, _Period, 1), _Digits), DoubleToString(iLow(_Symbol, _Period, 1), _Digits),
                DoubleToString(iClose(_Symbol, _Period, 1), _Digits), DoubleToString(f1, 7), DoubleToString(f2, 7), DoubleToString(s1, 7), DoubleToString(s2, 7),
                DoubleToString(Buf(hAtr, 1), 7), (int)up, (int)dn, DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits), DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits),
                TimeToString(iTime(_Symbol, _Period, 0), TIME_DATE | TIME_SECONDS), DoubleToString(iOpen(_Symbol, _Period, 0), _Digits));
   if(HavePosition() && InpExitOnCross && (up || dn))
   {
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if((isBuy && dn) || (!isBuy && up)) { g_vl_pending = "SIGNAL"; trade.PositionClose(_Symbol); }
   }
   if(HavePosition()) return;
   if(!SessionOk()) return;
   if(InpControlSeed > 0)      // control run: same session, stops and exits, but random entry bars and directions
   {
      if(MathRand() / 32767.0 < InpControlProb) Open(MathRand() % 2 == 0);
      return;
   }
   if(up && TrendOk(true)) Open(true);
   else if(dn && TrendOk(false)) Open(false);
}

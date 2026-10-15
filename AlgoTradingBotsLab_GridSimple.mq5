// GridSimple: simple grid, the same lot size at every level. NO STATISTICAL EDGE.
// This bot is statistically doomed to fail eventually. When a sustained move goes against the open levels the
// drawdown grows without limit and never recovers, or the account is blown. It exists to show exactly that.
// It only runs in the strategy tester or on a demo account. On any other account it removes itself in OnInit.
// Logic: a start rule (random, or the signal of another bot) sets an anchor price and a grid step in ATR.
// Levels sit at the anchor plus k steps. A buy at each level below, a sell at each level above (by mode),
// always the same size, each with a take profit one step back toward the anchor. Missing levels are refilled with
// pending limit orders on every new bar. When flat and price is far from the anchor, the grid is re-anchored.
// Optional filter: buy levels only while price is below a major MA, sell levels only while it is above.
// Needs a hedging account. Typical timeframe: H1.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "Simple grid, same size at every level. NO EDGE, doomed to fail. Tester and demo only."
#include <Trade\Trade.mqh>

enum ENUM_GRID_MODE { GRID_BUY = 0, GRID_SELL = 1, GRID_BOTH = 2 };
enum ENUM_START_RULE { START_RANDOM = 0, START_MACROSS = 1, START_RSI = 2, START_MACD = 3, START_DONCHIAN = 4 };

input ENUM_GRID_MODE  InpMode        = GRID_BOTH;      // Buy grid, sell grid or both
input ENUM_START_RULE InpStart       = START_RANDOM;   // Rule that starts a grid cycle
input double          InpStartProb   = 0.01;           // Random start chance per bar
input int             InpSeed        = 1;              // Random seed
input double          InpLots        = 0.10;           // Same lot size at every level
input int             InpAtrPer      = 14;             // ATR period
input ENUM_TIMEFRAMES InpAtrTF       = PERIOD_D1;      // ATR timeframe
input double          InpStepATR     = 0.3;            // Grid step in ATR
input int             InpLevels      = 10;             // Levels on each side
input double          InpResetSteps  = 3.0;            // Re-anchor when flat and this far
input bool            InpUseMAFilter = false;          // Buy below the MA only, sell above only
input int             InpMAFilterPer = 200;            // Filter MA period
input long            InpMagic       = 4742;           // Magic number

CTrade   trade;                           // market orders
CTrade   tradeP;                          // pending limit orders, always the Return fill policy
int      hAtr = INVALID_HANDLE, hMa = INVALID_HANDLE, hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
int      hRsi = INVALID_HANDLE, hMacd = INVALID_HANDLE;
datetime lastBar = 0;
bool     g_active = false;
int      g_startSig = 0;                  // start signal of this bar, kept while the market is closed
double   g_anchor = 0, g_step = 0;
int      g_dir0 = 1;                      // direction of the level at the anchor itself

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

int CrossOf(double a1, double a2, double b1, double b2)
{
   if(a2 <= b2 && a1 > b1) return 1;
   if(a2 >= b2 && a1 < b1) return -1;
   return 0;
}

// Rule that decides when a new cycle may start: 1 buy, -1 sell, 0 none, from the last closed bar.
// The other rules are the plain versions of MACross, RSIReversal, MACDSignal and Donchian.
int StartSignal()
{
   if(InpStart == START_RANDOM)
   {
      if(MathRand() / 32767.0 < InpStartProb) return MathRand() % 2 == 0 ? 1 : -1;
      return 0;
   }
   if(InpStart == START_MACROSS)
   {
      double f1 = Buf(hFast, 0, 1), f2 = Buf(hFast, 0, 2), s1 = Buf(hSlow, 0, 1), s2 = Buf(hSlow, 0, 2);
      if(AnyEmpty(f1, f2, s1, s2)) return 0;
      return CrossOf(f1, f2, s1, s2);
   }
   if(InpStart == START_RSI)
   {
      double r1 = Buf(hRsi, 0, 1), r2 = Buf(hRsi, 0, 2);
      if(AnyEmpty(r1, r2)) return 0;
      if(r2 <= 30 && r1 > 30) return 1;
      if(r2 >= 70 && r1 < 70) return -1;
      return 0;
   }
   if(InpStart == START_MACD)
   {
      double m1 = Buf(hMacd, 0, 1), m2 = Buf(hMacd, 0, 2), g1 = Buf(hMacd, 1, 1), g2 = Buf(hMacd, 1, 2);
      if(AnyEmpty(m1, m2, g1, g2)) return 0;
      return CrossOf(m1, m2, g1, g2);
   }
   int hiI = iHighest(_Symbol, _Period, MODE_HIGH, 20, 2), loI = iLowest(_Symbol, _Period, MODE_LOW, 20, 2);
   if(hiI < 0 || loI < 0) return 0;
   double c = iClose(_Symbol, _Period, 1);
   if(c > iHigh(_Symbol, _Period, hiI)) return 1;
   if(c < iLow(_Symbol, _Period, loI)) return -1;
   return 0;
}

bool MakeStartHandles()
{
   if(InpStart == START_MACROSS)
   {
      hFast = iMA(_Symbol, _Period, 20, 0, MODE_SMA, PRICE_CLOSE);
      hSlow = iMA(_Symbol, _Period, 50, 0, MODE_SMA, PRICE_CLOSE);
      return hFast != INVALID_HANDLE && hSlow != INVALID_HANDLE;
   }
   if(InpStart == START_RSI)
   {
      hRsi = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
      return hRsi != INVALID_HANDLE;
   }
   if(InpStart == START_MACD)
   {
      hMacd = iMACD(_Symbol, _Period, 12, 26, 9, PRICE_CLOSE);
      return hMacd != INVALID_HANDLE;
   }
   return true;
}

double Lot()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathFloor(InpLots / step + 1e-9) * step);
}

bool SideAllowed(bool buy)
{
   if(!InpUseMAFilter) return true;
   double ma = Buf(hMa, 0, 1);
   if(ma == EMPTY_VALUE) return false;
   double c = iClose(_Symbol, _Period, 1);
   return buy ? c < ma : c > ma;
}

bool SlotIsBuy(int k) { return k < 0 || (k == 0 && g_dir0 > 0); }

bool SlotWanted(int k)
{
   if(SlotIsBuy(k)) return InpMode != GRID_SELL && k > -InpLevels;
   return InpMode != GRID_BUY && k < InpLevels;
}

void Mark(const string comment, bool &has[])
{
   if(StringLen(comment) < 2 || StringGetCharacter(comment, 0) != 'G') return;
   int k = (int)StringToInteger(StringSubstr(comment, 1));
   if(k > -InpLevels && k < InpLevels) has[k + InpLevels] = true;
}

int OwnCount()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   return n;
}

void DeletePending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t != 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic) tradeP.OrderDelete(t);
   }
}

// Make sure every wanted level has a position or a pending limit order. Orders on a side the MA filter blocks are removed.
void Maintain()
{
   bool has[];
   ArrayResize(has, 2 * InpLevels);
   ArrayInitialize(has, false);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      Mark(PositionGetString(POSITION_COMMENT), has);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(!SideAllowed(OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT)) { tradeP.OrderDelete(t); continue; }
      Mark(OrderGetString(ORDER_COMMENT), has);
   }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point, ask - bid) + _Point;
   for(int k = -(InpLevels - 1); k <= InpLevels - 1; k++)
   {
      if(has[k + InpLevels] || !SlotWanted(k)) continue;
      bool buy = SlotIsBuy(k);
      if(!SideAllowed(buy)) continue;
      double lvl = NormalizeDouble(g_anchor + k * g_step, _Digits);
      double tp = NormalizeDouble(buy ? g_anchor + (k + 1) * g_step : g_anchor + (k - 1) * g_step, _Digits);
      string cm = StringFormat("G%d", k);
      if(buy && lvl < ask - minD) tradeP.BuyLimit(Lot(), lvl, _Symbol, 0, tp, ORDER_TIME_GTC, 0, cm);
      else if(!buy && lvl > bid + minD) tradeP.SellLimit(Lot(), lvl, _Symbol, 0, tp, ORDER_TIME_GTC, 0, cm);
   }
}

// Order failures worth another try on the next tick, like the closed market at the daily rollover
bool RetriableCode(uint rc)
{
   return rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_REQUOTE ||
          rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TIMEOUT;
}

void StartCycle(int sig)
{
   g_startSig = 0;                                        // set again below only when the market was closed
   if(InpMode == GRID_BUY && sig < 0) return;
   if(InpMode == GRID_SELL && sig > 0) return;
   int dir = InpMode == GRID_BUY ? 1 : (InpMode == GRID_SELL ? -1 : sig);
   if(!SideAllowed(dir > 0)) return;
   double atr = Buf(hAtr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;
   double step = InpStepATR * atr;
   double px = dir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp = NormalizeDouble(dir > 0 ? px + step : px - step, _Digits);
   bool ok = dir > 0 ? trade.Buy(Lot(), _Symbol, px, 0, tp, "G0") : trade.Sell(Lot(), _Symbol, px, 0, tp, "G0");
   if(!ok)
   {
      if(RetriableCode(trade.ResultRetcode())) g_startSig = sig;     // try again on the next tick of this bar
      return;
   }
   g_dir0 = dir;
   g_step = step;
   g_anchor = px;
   g_active = true;
   Maintain();
}

int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("GridSimple refuses to run: strategy tester or demo account only. This bot has no statistical edge.");
      ExpertRemove();
      return INIT_FAILED;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("GridSimple needs a hedging account, many positions are open at once.");
      return INIT_FAILED;
   }
   Comment("GridSimple: educational demo with no statistical edge, doomed to fail eventually. Tester and demo only.");
   hAtr = iATR(_Symbol, InpAtrTF, InpAtrPer);
   if(InpUseMAFilter) hMa = iMA(_Symbol, _Period, InpMAFilterPer, 0, MODE_SMA, PRICE_CLOSE);
   if(hAtr == INVALID_HANDLE || (InpUseMAFilter && hMa == INVALID_HANDLE) || !MakeStartHandles()) return INIT_FAILED;
   MathSrand(InpSeed);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   tradeP.SetExpertMagicNumber(InpMagic);
   tradeP.SetTypeFilling(ORDER_FILLING_RETURN);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   if(g_startSig != 0 && !g_active) StartCycle(g_startSig);
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar == lastBar) return;
   lastBar = bar;
   g_startSig = 0;                   // a start that waited for an open market does not carry over to the next bar
   int sig = StartSignal();          // drawn on every bar so the random stream does not depend on the state
   if(!g_active)
   {
      if(sig != 0) StartCycle(sig);
      return;
   }
   if(OwnCount() == 0)
   {
      double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      if(MathAbs(mid - g_anchor) > InpResetSteps * g_step)
      {
         DeletePending();
         g_active = false;
         return;
      }
   }
   Maintain();
}

// GridMartingale: first trade, then a growing grid against the position. NO STATISTICAL EDGE.
// This bot is statistically doomed to fail eventually. Averaging down with bigger lots only delays the blow up,
// it never removes it, and the account pays for it in one long move. It exists to show exactly that.
// It only runs in the strategy tester or on a demo account. On any other account it removes itself in OnInit.
// Logic: a start rule (random, or the signal of another bot) opens the first trade. If price moves against the
// last entry by one gap, another trade in the same direction is added. The gap is fixed for the first trades,
// then it grows by a factor for every later trade. The lot of trade j is InpLots * InpLotMult^(j-1), kept unrounded
// in the calculation and rounded only for the order (for example 0.01, 0.01, 0.01, 0.02). Every position carries the
// same take profit, a set distance from the average price of the basket. No stop loss.
// Needs a hedging account. Typical timeframe: H1.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "Averaging grid with growing lots. NO EDGE, doomed to fail. Tester and demo only."
#include <Trade\Trade.mqh>

enum ENUM_START_RULE { START_RANDOM = 0, START_MACROSS = 1, START_RSI = 2, START_MACD = 3, START_DONCHIAN = 4 };

input ENUM_START_RULE InpStart       = START_RANDOM;   // Rule that opens the first trade
input double          InpStartProb   = 0.01;           // Random start chance per bar
input int             InpSeed        = 1;              // Random seed
input double          InpLots        = 0.10;           // Size of the first trade
input double          InpLotMult     = 1.2;            // Lot factor for each extra trade
input int             InpAtrPer      = 14;             // ATR period
input ENUM_TIMEFRAMES InpAtrTF       = PERIOD_CURRENT; // ATR timeframe
input double          InpGridATR     = 1.5;            // Gap between trades in ATR
input int             InpExpandAfter = 4;              // Gap grows after this many trades
input double          InpExpandMult  = 1.2;            // Gap factor for each later trade
input int             InpMaxTrades   = 10;             // Maximum trades in one basket
input double          InpTPatr       = 1.0;            // Basket target from average price, ATR
input long            InpMagic       = 4743;           // Magic number

CTrade   trade;
int      hAtr = INVALID_HANDLE, hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hRsi = INVALID_HANDLE, hMacd = INVALID_HANDLE;
datetime lastBar = 0, g_failBar = 0;
int      g_startSig = 0;                  // start signal of this bar, kept while the market is closed
bool     g_canRetry = false;              // the last order failed in a way worth another try
int      g_n = 0, g_dir = 1;              // trades in the basket and its direction
double   g_lastPx = 0, g_atr = 0;         // last entry price, ATR locked at the start of the basket

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

// Order failures worth another try on the next tick, like the closed market at the daily rollover
bool RetriableCode(uint rc)
{
   return rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_REQUOTE ||
          rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TIMEOUT;
}

double RawLot(int j) { return InpLots * MathPow(InpLotMult, j - 1); }

double RoundLot(double raw)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = NormalizeDouble(MathRound(raw / step) * step, 3);
   return MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), lots));
}

// Gap from trade n to trade n+1
double GapDist(int n)
{
   double f = n <= InpExpandAfter ? 1.0 : MathPow(InpExpandMult, n - InpExpandAfter);
   return InpGridATR * g_atr * f;
}

int OwnCount()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   return n;
}

// One shared take profit for the whole basket, a set distance from the volume weighted average price
void SetBasketTP()
{
   double vol = 0, wsum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      vol += PositionGetDouble(POSITION_VOLUME);
      wsum += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
   }
   if(vol <= 0) return;
   double avg = wsum / vol;
   double tp = NormalizeDouble(g_dir > 0 ? avg + InpTPatr * g_atr : avg - InpTPatr * g_atr, _Digits);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(MathAbs(PositionGetDouble(POSITION_TP) - tp) > _Point / 2.0) trade.PositionModify(t, 0, tp);
   }
}

bool OpenTrade(bool buy)
{
   int j = g_n + 1;
   double lots = RoundLot(RawLot(j));
   double px = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string cm = StringFormat("M%d", j);
   bool ok = buy ? trade.Buy(lots, _Symbol, px, 0, 0, cm) : trade.Sell(lots, _Symbol, px, 0, 0, cm);
   g_canRetry = !ok && RetriableCode(trade.ResultRetcode());
   if(!ok) return false;
   g_n = j;
   double fill = trade.ResultPrice();
   g_lastPx = fill > 0 ? fill : px;
   SetBasketTP();
   return true;
}

void StartBasket(int sig)
{
   double atr = Buf(hAtr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) { g_startSig = 0; return; }
   g_atr = atr;
   g_dir = sig > 0 ? 1 : -1;
   g_n = 0;
   if(OpenTrade(g_dir > 0) || !g_canRetry) g_startSig = 0;     // a closed market is tried again on the next tick of this bar
}

int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("GridMartingale refuses to run: strategy tester or demo account only. This bot has no statistical edge.");
      ExpertRemove();
      return INIT_FAILED;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("GridMartingale needs a hedging account, many positions are open at once.");
      return INIT_FAILED;
   }
   Comment("GridMartingale: educational demo with no statistical edge, doomed to fail eventually. Tester and demo only.");
   hAtr = iATR(_Symbol, InpAtrTF, InpAtrPer);
   if(hAtr == INVALID_HANDLE || !MakeStartHandles()) return INIT_FAILED;
   MathSrand(InpSeed);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar != lastBar)
   {
      lastBar = bar;
      int sig = StartSignal();                              // drawn on every bar so the random stream does not depend on the state
      if(g_n > 0 && OwnCount() == 0) g_n = 0;
      g_startSig = g_n == 0 ? sig : 0;                      // a start only counts when the bar begins flat
   }
   if(g_n > 0)
   {
      if(PositionsTotal() == 0) g_n = 0;                    // basket closed at its target
      else if(g_n < InpMaxTrades && bar != g_failBar)
      {
         double px = g_dir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);   // the price the next fill would get, so fills are a full gap apart
         double against = g_dir > 0 ? g_lastPx - px : px - g_lastPx;
         if(against >= GapDist(g_n) && !OpenTrade(g_dir > 0) && !g_canRetry) g_failBar = bar;   // refused for good, wait for the next bar
      }
   }
   if(g_n == 0 && g_startSig != 0) StartBasket(g_startSig);
}

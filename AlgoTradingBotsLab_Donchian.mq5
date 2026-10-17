// Donchian: Donchian channel breakout, 20 bars in and 10 bars out
// Entry: Close above the highest high of the previous 20 bars to buy, below the lowest low to sell.
// Exit: Close beyond the opposite 10 bar extreme, or the ATR stop.
// Typical timeframe: H1 or H4. Educational bot, no claim of any statistical edge.
// Standalone file. The filters, stops, target, trail and timer are the same text in every bot of the set.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "Donchian channel breakout, 20 bars in and 10 bars out"
#include <Trade\Trade.mqh>

enum ENUM_DIR_MODE { DIR_BOTH = 0, DIR_LONG_ONLY = 1, DIR_SHORT_ONLY = 2 };

input int            InpEntryBars  = 20;               // Breakout lookback in bars
input int            InpExitBars   = 10;               // Exit lookback in bars
input int            InpSizeMode   = 2;                // Sizing: 0 fixed lot, 1 fixed risk in USD, 2 percent of the balance
input double         InpLots       = 0.10;             // Fixed lot size (sizing 0)
input double         InpRiskUSD    = 50.0;             // Money at risk per trade (sizing 1)
input double         InpRiskPct    = 0.25;             // Percent of the balance at risk per trade (sizing 2)
input double         InpRiskAtr    = 3.0;              // Risk distance in ATR when the stop is off (sizing 1 and 2)
input int            InpMinLotRule = 1;                // Lot below the minimum: 1 take the minimum lot, 0 skip when that risks over 1.5 times the wanted risk
input bool           InpRiskWithCosts = true;          // Count the commission in the risk (the spread is already inside the stop distance)
input double         InpCommLot    = 0.0;              // Commission per lot and side, 0 = learn it from the bot's own deals
input int            InpAtrPer     = 14;               // ATR period
input ENUM_TIMEFRAMES InpAtrTF     = PERIOD_CURRENT;   // ATR timeframe
input double         InpSLatr      = 3.0;              // Stop loss in ATR
input double         InpTPatr      = 0.0;              // Take profit in ATR, 0 = none
input double         InpTrailArm   = 0.0;              // Trail arms at profit in ATR, 0 = off
input double         InpTrailDist  = 1.5;              // Trail distance in ATR
input int            InpMaxBars    = 0;                // Close after N bars, 0 = off
input bool           InpExitOnSignal = true;           // Use the bot's own exit rule
input bool           InpUseSession = false;            // Session filter on
input int            InpSessStart  = 7;                // Session start hour, server time
input int            InpSessEnd    = 17;               // Session end hour, server time
input int            InpSessMode   = 0;                // Session windows: 0 hours above, 1 London, 2 New York, 3 London and New York (server time)
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
input long           InpMagic      = 4719;             // Magic number

CTrade   trade;
int      hAtr = INVALID_HANDLE, hTrend = INVALID_HANDLE, hAdx = INVALID_HANDLE;

datetime lastBar = 0;
double   entryAtr = 0;
double   g_slDist = 0, g_tpDist = 0;     // stop and target distance a signal may set, 0 = use the ATR inputs
int      g_sig = 0;                      // signal of the current bar, exits use this one
int      g_entrySig = 0;                 // signal the entry uses, the same as g_sig except in a control run
bool     g_entryDone = true;             // the entry decision of this bar has been made
string   g_wantClose = "";               // reason of a close that still has to go through
bool     g_canRetry = false;             // the last order failed in a way worth another try
int      g_retries = 0;                  // retries spent on the current bar
bool     g_trailArmed = false;           // the trailing stop of the open position is armed
bool     g_prOk = true;                  // prop rules allow new entries on this tick
double   g_commLot = -1;                 // commission per lot and side learned from the deals, -1 = not known yet

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
   int hiI = iHighest(_Symbol, _Period, MODE_HIGH, InpEntryBars, 2);
   int loI = iLowest(_Symbol, _Period, MODE_LOW, InpEntryBars, 2);
   if(hiI < 0 || loI < 0) return 0;
   double c = Cl(1);
   if(c > Hi(hiI)) return 1;
   if(c < Lo(loI)) return -1;
   return 0;
}

// The bot's own exit rule, checked once per new bar while a position is open.
bool ExitNow(bool isBuy, int sig)
{
   double c = Cl(1);
   if(isBuy)
   {
      int lo = iLowest(_Symbol, _Period, MODE_LOW, InpExitBars, 2);
      return lo >= 0 && c < Lo(lo);
   }
   int hi = iHighest(_Symbol, _Period, MODE_HIGH, InpExitBars, 2);
   return hi >= 0 && c > Hi(hi);
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
   if(InpSessMode == 1) return t.hour >= 10 && t.hour < 18;      // London, server time
   if(InpSessMode == 2) return t.hour >= 15 && t.hour < 23;      // New York, server time
   if(InpSessMode == 3) return t.hour >= 10 && t.hour < 23;      // London and New York
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

// Commission per lot and side: the input, else the last own deal that paid one (0 until a deal shows it)
double CommPerLot()
{
   if(InpCommLot > 0) return InpCommLot;
   if(g_commLot >= 0) return g_commLot;
   if(!HistorySelect(0, TimeCurrent())) return 0;
   int seen = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && seen < 4; i--)      // the last few own deals, entry or exit may carry it
   {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      double v = HistoryDealGetDouble(d, DEAL_VOLUME), c = HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(v <= 0) continue;
      seen++;
      if(c != 0) { g_commLot = MathAbs(c) / v; return g_commLot; }
   }
   return 0;
}

// Lot of the next trade. Sizing 0 is the fixed lot (or the bot's own lot rule). Sizing 1 and 2: money at risk / loss of 1 lot at the stop,
// rounded down to the volume step, the minimum lot rule, the maximum lot, then cut to what the free margin allows. 0 = skip the trade.
double LotFor(bool isBuy, double px, double slD, double atr)
{
   if(InpSizeMode == 0) return LotSize();
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double dist = slD > 0 ? slD : InpRiskAtr * atr;
   double risk = InpSizeMode == 1 ? InpRiskUSD : AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double stopPx = isBuy ? px - dist : px + dist, pl = 0;
   if(dist <= 0 || risk <= 0 || !OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, px, stopPx, pl)) return 0;
   double comm = InpRiskWithCosts ? 2 * CommPerLot() : 0;
   double loss1 = MathAbs(pl) + comm;
   if(loss1 <= 0) return 0;
   double lots = MathFloor(risk / loss1 / step + 1e-9) * step;
   if(lots < vmin)
   {
      if(InpMinLotRule == 0 && vmin * loss1 > 1.5 * risk) { PrintFormat("SIZE skip: minimum lot %.2f risks %.2f, wanted %.2f", vmin, vmin * loss1, risk); return 0; }
      lots = vmin;
   }
   double m1 = 0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, px, m1) && m1 > 0)
      lots = MathMin(lots, MathFloor(AccountInfoDouble(ACCOUNT_MARGIN_FREE) / m1 / step + 1e-9) * step);
   lots = MathMin(lots, vmax);
   if(lots < vmin) { PrintFormat("SIZE skip: margin allows %.2f lots", lots); return 0; }
   lots = NormalizeDouble(lots, 8);
   PrintFormat("SIZE mode=%d lots=%.2f risk=%.2f wanted=%.2f loss1lot=%.2f comm=%.2f dist=%s", InpSizeMode, lots, lots * loss1, risk, loss1, comm,
               DoubleToString(dist, _Digits));
   return lots;
}

// ---------------------------------------------------------------- Prop rules (L5), off by default
// Challenge and funded account rules inside a backtest or on an account: profit target, max loss floor (static or trailing), daily loss limit,
// time limit, minimum trading days, consistency, weekend close, news blackout, lot cap. On a pass or a breach it closes everything and stops.
enum ENUM_PROP_FLOOR { PROP_FLOOR_STATIC = 0, PROP_FLOOR_TRAIL_BALANCE = 1, PROP_FLOOR_TRAIL_EQUITY = 2, PROP_FLOOR_TRAIL_TO_START = 3 };
input int             InpPropMode      = 0;            // Prop rules: 0 off, 1 on for this EA's positions, 2 on for every position of the account
input double          InpPropTargetPct = 10.0;         // Profit target in % of the start balance, 0 = none
input double          InpPropMaxLossPct = 10.0;        // Maximum loss in % of the start balance
input ENUM_PROP_FLOOR InpPropFloorType = PROP_FLOOR_STATIC;// Floor: static, trailing balance, trailing equity, trailing equity up to the start
input double          InpPropDailyPct  = 5.0;          // Daily loss limit in % of the start balance, 0 = none
input int             InpPropDailyType = 0;            // Daily reference: 0 balance at the reset, 1 the higher of balance and equity
input int             InpPropResetHour = 0;            // Daily reset hour, server time
input int             InpPropMinDays   = 0;            // Minimum trading days before the target counts
input int             InpPropMaxDays   = 0;            // Time limit in calendar days, 0 = none
input double          InpPropConsistencyPct = 0.0;     // Best day at most this % of the total profit at the target, 0 = off
input int             InpPropNewsMinutes = 0;          // No entries this many minutes around high impact news, 0 = off
input bool            InpPropNoWeekend = false;        // Flat from Friday and over the weekend
input int             InpPropFridayHour = 21;          // Friday close hour, server time
input double          InpPropMaxLots   = 0.0;          // Lot cap per entry, 0 = none
input double          InpPropStartBalance = 0.0;       // Start balance, 0 = the balance when the EA starts

int      g_prState = 0;                  // 0 running, 1 passed, 2 failed
string   g_prWhy = "";
double   g_prStart = 0, g_prHighBal = 0, g_prHighEq = 0, g_prDayRef = 0, g_prDayBal = 0;
datetime g_prBegin = 0, g_prDayKey = 0, g_prLastEntryDay = -1;
int      g_prDays = 0;
double   g_prBestDay = 0;                // best closed balance change of a finished trading day
bool     g_prTradedToday = false;
datetime g_prNews[];
int      g_prNewsN = 0;
CTrade   g_prTrade;

datetime PR_DayKey(datetime t) { return (datetime)(((long)t - InpPropResetHour * 3600) / 86400 * 86400); }

bool PR_Mine(long magic) { return InpPropMode == 2 || magic == InpMagic; }

void PR_CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PR_Mine(PositionGetInteger(POSITION_MAGIC))) continue;
      g_prTrade.PositionClose(t);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !PR_Mine(OrderGetInteger(ORDER_MAGIC))) continue;
      g_prTrade.OrderDelete(t);
   }
}

bool PR_HaveOpen()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PR_Mine(PositionGetInteger(POSITION_MAGIC))) return true;
   }
   return false;
}

void PR_LoadNews()
{
   g_prNewsN = 0;
   if(InpPropNewsMinutes <= 0) return;
   string base = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE), quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(!MQLInfoInteger(MQL_TESTER))
   {
      MqlCalendarValue v[];
      datetime a = TimeCurrent() - 86400, b = TimeCurrent() + 30 * 86400;
      string ccy[2];
      ccy[0] = base;
      ccy[1] = quote;
      for(int c = 0; c < 2; c++)
      {
         if(CalendarValueHistory(v, a, b, NULL, ccy[c]) <= 0) continue;
         for(int i = 0; i < ArraySize(v); i++)
         {
            MqlCalendarEvent e;
            if(!CalendarEventById(v[i].event_id, e) || e.importance != CALENDAR_IMPORTANCE_HIGH) continue;
            if(g_prNewsN >= ArraySize(g_prNews)) ArrayResize(g_prNews, g_prNewsN + 256);
            g_prNews[g_prNewsN++] = v[i].time;
         }
      }
   }
   else
   {
      int h = FileOpen("CLAUDE-VIDEOS\\lab\\news.csv", FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(h == INVALID_HANDLE) { Print("PROP: no CLAUDE-VIDEOS\\lab\\news.csv in the common Files folder, the news rule is off in the tester"); return; }
      FileReadString(h); FileReadString(h);
      while(!FileIsEnding(h))
      {
         datetime t = StringToTime(FileReadString(h));
         string c = FileReadString(h);
         if(t == 0 || (c != base && c != quote)) continue;
         if(g_prNewsN >= ArraySize(g_prNews)) ArrayResize(g_prNews, g_prNewsN + 1024);
         g_prNews[g_prNewsN++] = t;
      }
      FileClose(h);
   }
   ArrayResize(g_prNews, g_prNewsN);                     // drop the unused tail before sorting, or its zeros would move to the front
   if(g_prNewsN > 0) ArraySort(g_prNews);
   PrintFormat("PROP: %d high impact news times loaded", g_prNewsN);
}

bool PR_NewsNear(datetime now)
{
   if(InpPropNewsMinutes <= 0 || g_prNewsN == 0) return false;
   int a = 0, b = g_prNewsN - 1;
   while(a < b)                                          // first news time at or after now - window
   {
      int m = (a + b) / 2;
      if(g_prNews[m] < now - InpPropNewsMinutes * 60) a = m + 1; else b = m;
   }
   return MathAbs((double)(g_prNews[a] - now)) <= InpPropNewsMinutes * 60;
}

void PR_Init()
{
   if(InpPropMode <= 0) return;
   g_prStart = InpPropStartBalance > 0 ? InpPropStartBalance : AccountInfoDouble(ACCOUNT_BALANCE);
   g_prHighBal = g_prStart;
   g_prHighEq = MathMax(g_prStart, AccountInfoDouble(ACCOUNT_EQUITY));
   g_prBegin = TimeCurrent();
   g_prDayKey = PR_DayKey(g_prBegin);
   g_prDayBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_prDayRef = InpPropDailyType == 0 ? g_prDayBal : MathMax(g_prDayBal, AccountInfoDouble(ACCOUNT_EQUITY));
   g_prTrade.SetExpertMagicNumber(InpMagic);
   PR_LoadNews();
   PrintFormat("PROP on: start %.2f target %.2f%% max loss %.2f%% floor %d daily %.2f%% type %d reset %d min days %d max days %d", g_prStart,
               InpPropTargetPct, InpPropMaxLossPct, (int)InpPropFloorType, InpPropDailyPct, InpPropDailyType, InpPropResetHour, InpPropMinDays, InpPropMaxDays);
}

void PR_End(int state, string why)
{
   g_prState = state;
   g_prWhy = why;
   PR_CloseAll();
   string msg = StringFormat("PROP %s: %s at %s, balance %.2f equity %.2f, %d trading days", state == 1 ? "PASSED" : "FAILED", why,
                             TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY), g_prDays);
   Print(msg);
   Comment(msg);
}

// Call when an entry went through: counts trading days
void PR_OnEntry()
{
   if(InpPropMode <= 0) return;
   g_prTradedToday = true;
   datetime k = PR_DayKey(TimeCurrent());
   if(k != g_prLastEntryDay) { g_prLastEntryDay = k; g_prDays++; }
}

double PR_Lots(double lots)
{
   if(InpPropMode <= 0 || InpPropMaxLots <= 0) return lots;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMin(lots, MathFloor(InpPropMaxLots / step + 1e-9) * step);
}

// Every tick: true when new entries are allowed. A pass or a breach closes everything and blocks trading for good.
bool PR_Tick()
{
   if(InpPropMode <= 0) return true;
   if(g_prState != 0) { if(PR_HaveOpen()) PR_CloseAll(); return false; }
   datetime now = TimeCurrent();
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   datetime key = PR_DayKey(now);
   if(key != g_prDayKey)
   {
      if(g_prTradedToday) g_prBestDay = MathMax(g_prBestDay, bal - g_prDayBal);
      g_prTradedToday = false;
      g_prDayKey = key;
      g_prDayBal = bal;
      g_prDayRef = InpPropDailyType == 0 ? bal : MathMax(bal, eq);
   }
   g_prHighBal = MathMax(g_prHighBal, bal);
   g_prHighEq = MathMax(g_prHighEq, eq);
   double amount = g_prStart * InpPropMaxLossPct / 100.0, floor = g_prStart - amount;
   if(InpPropFloorType == PROP_FLOOR_TRAIL_BALANCE) floor = g_prHighBal - amount;
   if(InpPropFloorType == PROP_FLOOR_TRAIL_EQUITY) floor = g_prHighEq - amount;
   if(InpPropFloorType == PROP_FLOOR_TRAIL_TO_START) floor = MathMin(g_prHighEq - amount, g_prStart);
   if(InpPropMaxLossPct > 0 && eq <= floor) { PR_End(2, "max loss"); return false; }
   if(InpPropDailyPct > 0 && eq <= g_prDayRef - g_prStart * InpPropDailyPct / 100.0) { PR_End(2, "daily loss"); return false; }
   if(InpPropMaxDays > 0 && now - g_prBegin >= (datetime)InpPropMaxDays * 86400) { PR_End(2, "time limit"); return false; }
   if(InpPropTargetPct > 0 && eq >= g_prStart * (1 + InpPropTargetPct / 100.0) && g_prDays >= InpPropMinDays)
   {
      double best = MathMax(g_prBestDay, g_prTradedToday ? eq - g_prDayBal : 0), total = eq - g_prStart;
      if(InpPropConsistencyPct <= 0 || best <= total * InpPropConsistencyPct / 100.0) { PR_End(1, "target"); return false; }
   }
   MqlDateTime t;
   TimeToStruct(now, t);
   if(InpPropNoWeekend && ((t.day_of_week == 5 && t.hour >= InpPropFridayHour) || t.day_of_week == 6 || t.day_of_week == 0))
   {
      if(PR_HaveOpen()) PR_CloseAll();
      return false;
   }
   if(PR_NewsNear(now)) return false;
   return true;
}

// Room left to each limit, for the chart
string PR_Status()
{
   if(InpPropMode <= 0) return "";
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double amount = g_prStart * InpPropMaxLossPct / 100.0, floor = g_prStart - amount;
   if(InpPropFloorType == PROP_FLOOR_TRAIL_BALANCE) floor = g_prHighBal - amount;
   if(InpPropFloorType == PROP_FLOOR_TRAIL_EQUITY) floor = g_prHighEq - amount;
   if(InpPropFloorType == PROP_FLOOR_TRAIL_TO_START) floor = MathMin(g_prHighEq - amount, g_prStart);
   double daily = g_prDayRef - g_prStart * InpPropDailyPct / 100.0;
   return StringFormat("Prop rules: %s | equity %.2f | to max loss %.2f | to daily limit %s | to target %s | trading days %d",
                       g_prState == 0 ? "running" : (g_prState == 1 ? "PASSED" : "FAILED " + g_prWhy), eq, eq - floor,
                       InpPropDailyPct > 0 ? DoubleToString(eq - daily, 2) : "off",
                       InpPropTargetPct > 0 ? DoubleToString(g_prStart * (1 + InpPropTargetPct / 100.0) - eq, 2) : "off", g_prDays);
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
   double lots = PR_Lots(LotFor(isBuy, px, slD, atr));
   if(lots <= 0) return false;
   bool ok = isBuy ? trade.Buy(lots, _Symbol, px, sl, tp) : trade.Sell(lots, _Symbol, px, sl, tp);
   g_canRetry = !ok && RetriableCode(trade.ResultRetcode());
   if(g_canRetry) g_retries++;
   if(ok) g_trailArmed = false;
   if(ok) PR_OnEntry();
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
   if(g_entryDone || g_entrySig == 0 || g_wantClose != "") return;
   g_entryDone = true;
   if(HavePosition()) return;
   bool isBuy = g_entrySig > 0;
   if(FiltersOk(isBuy) && g_prOk && !Open(isBuy) && g_canRetry) g_entryDone = false;
}

void Trail()
{
   if(InpTrailArm <= 0 || !HavePosition()) return;
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
   if(!better || !trade.PositionModify(_Symbol, NormalizeDouble(want, _Digits), PositionGetDouble(POSITION_TP))) return;
}

int OnInit()
{

   hAtr = iATR(_Symbol, InpAtrTF, InpAtrPer);
   if(InpUseTrend) hTrend = iMA(_Symbol, _Period, InpTrendMA, 0, MODE_SMA, PRICE_CLOSE);
   if(InpUseAdx) hAdx = iADX(_Symbol, _Period, InpAdxPer);
   if(hAtr == INVALID_HANDLE || (InpUseTrend && hTrend == INVALID_HANDLE) || (InpUseAdx && hAdx == INVALID_HANDLE)) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   PR_Init();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{

   Print("Donchian finished");
}

void OnTick()
{
   g_prOk = PR_Tick();
   if(g_prState != 0) return;                         // the prop challenge is over (passed or failed): no more trading
   Trail();
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar != lastBar)
   {
      lastBar = bar;
      g_slDist = 0;
      g_tpDist = 0;
      g_sig = Signal();
      g_entrySig = g_sig;
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

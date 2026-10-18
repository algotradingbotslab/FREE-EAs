// PropGuard (L6): a watcher for challenge and funded accounts. It does not trade. It watches the account equity and enforces the prop rules
// (profit target, max loss floor static or trailing, daily loss limit, time limit, minimum trading days, consistency, weekend close, news blackout)
// for every position on the account, from any EA or manual. On a pass or a breach it closes everything, deletes pending orders and keeps
// closing anything new. The chart shows the room left to each limit. A risk tool, not a strategy: it may run live. Test it on demo first.
// In the strategy tester it can open random demo trades (InpTesterDemo) so the rules have something to act on.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "Prop rules guard: watches the account, closes everything on a pass or a breach. Not a strategy."
#include <Trade\Trade.mqh>

input long           InpMagic      = 4749;             // Magic number of the tester demo trades
input bool           InpTesterDemo = true;             // Strategy tester only: open random demo trades for the guard to watch
input double         InpDemoLots   = 0.10;             // Demo trade lot size
input int            InpDemoSeed   = 1;                // Demo trades: random seed
input double         InpDemoProb   = 0.05;             // Demo trades: entry chance per bar when flat
input int            InpDemoHoldBars = 12;             // Demo trades: close after this many bars

// ---------------------------------------------------------------- Prop rules (L5), off by default
// Challenge and funded account rules inside a backtest or on an account: profit target, max loss floor (static or trailing), daily loss limit,
// time limit, minimum trading days, consistency, weekend close, news blackout, lot cap. On a pass or a breach it closes everything and stops.
enum ENUM_PROP_FLOOR { PROP_FLOOR_STATIC = 0, PROP_FLOOR_TRAIL_BALANCE = 1, PROP_FLOOR_TRAIL_EQUITY = 2, PROP_FLOOR_TRAIL_TO_START = 3 };
input int             InpPropMode      = 2;            // Prop rules: 0 off, 1 only the demo trades of this EA, 2 every position of the account
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

CTrade   trade;
datetime lastBar = 0;

void Guard()
{
   PR_Tick();
   Comment(PR_Status());
}

// Tester only: a random demo position on the chart symbol, so the rules can be seen working
void DemoTrades()
{
   if(!MQLInfoInteger(MQL_TESTER) || !InpTesterDemo) return;
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar == lastBar) return;
   lastBar = bar;
   bool have = PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagic;
   if(have && iBarShift(_Symbol, _Period, (datetime)PositionGetInteger(POSITION_TIME)) >= InpDemoHoldBars) { trade.PositionClose(_Symbol); have = false; }
   double r = MathRand() / 32767.0;
   bool side = MathRand() % 2 == 0;
   if(have || g_prState != 0 || r >= InpDemoProb || !PR_Tick()) return;
   bool ok = side ? trade.Buy(InpDemoLots, _Symbol) : trade.Sell(InpDemoLots, _Symbol);
   if(ok && InpPropMode == 1) PR_OnEntry();
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   MathSrand(InpDemoSeed);
   PR_Init();
   EventSetTimer(1);
   Guard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("PropGuard finished: %s", g_prState == 0 ? "still running" : (g_prState == 1 ? "PASSED" : "FAILED " + g_prWhy));
   Comment("");
}

// Trading days count every entry on the account (mode 2) or the demo entries (mode 1)
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(InpPropMode != 2 || trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(HistoryDealSelect(trans.deal) && HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN) PR_OnEntry();
}

void OnTimer()
{
   Guard();
}

void OnTick()
{
   Guard();
   DemoTrades();
}

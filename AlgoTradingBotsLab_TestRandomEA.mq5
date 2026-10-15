#property copyright "AlgoTradingBotsLab"
#property strict
#include <Trade\Trade.mqh>
input double Lots = 0.10;
input int    TPpts = 300;
input int    SLpts = 300;
CTrade trade;
int OnInit() { MathSrand(12345); PrintFormat("TestRandomEA inputs Lots=%.2f TP=%d SL=%d", Lots, TPpts, SLpts); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { Print("TestRandomEA finished"); }
void OnTick() {
   if(PositionsTotal() > 0) return;
   double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK), b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(MathRand() % 2 == 0) trade.Buy(Lots, _Symbol, a, a - SLpts * _Point, a + TPpts * _Point);
   else                    trade.Sell(Lots, _Symbol, b, b + SLpts * _Point, b - TPpts * _Point);
}

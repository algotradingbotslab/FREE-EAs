// BuyHold: buy and hold benchmark. One long position from the first tick to the end of the test, no stop, no target.
// Use it as the yardstick: every other bot has to beat what simply owning the asset did over the same period.
// Typical timeframe: any (D1 is fine). Educational bot, no claim of any statistical edge.
#property copyright "AlgoTradingBotsLab"
#property strict
#property description "Buy and hold benchmark, one long position for the whole test"
#include <Trade\Trade.mqh>

input double         InpLots       = 0.10;             // Fixed lot size
input long           InpMagic      = 4739;             // Magic number

CTrade   trade;
bool     g_bought = false;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(g_bought) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathFloor(InpLots / step + 1e-9) * step);
   if(trade.Buy(lots, _Symbol, ask, 0, 0)) g_bought = true;
}

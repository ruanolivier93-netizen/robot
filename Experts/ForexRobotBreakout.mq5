//+------------------------------------------------------------------+
//|                                           ForexRobotBreakout.mq5 |
//|              Asian Range Breakout - Session Breakout Strategy     |
//|              Complementary to Mean Reversion EA                   |
//+------------------------------------------------------------------+
#property copyright "ForexRobot"
#property version   "1.00"
#property description "Asian Range Breakout EA - Trades London/NY breakouts from Asian consolidation"
#property strict

#include <Trade\Trade.mqh>
#include "..\Include\TradeManager.mqh"

#define MAX_SYMBOLS 6

//+------------------------------------------------------------------+
//| Per-symbol state for tracking Asian range + breakout               |
//+------------------------------------------------------------------+
enum EBreakoutState
{
   STATE_BUILDING_RANGE,    // Asian session active — tracking high/low
   STATE_WAITING_BREAKOUT,  // Range defined, waiting for breakout window to place pending orders
   STATE_PENDING_ORDER,     // Pending stop orders placed, waiting for fill
   STATE_TRADE_TAKEN,       // Breakout trade opened for today
   STATE_DONE_FOR_DAY       // Daily limit hit or session over
};

struct SBreakoutData
{
   string         symbol;
   EBreakoutState state;
   double         asianHigh;
   double         asianLow;
   double         rangeSize;
   datetime       lastResetDay;
   datetime       lastBarTime;
   int            handleATR;
   int            handleADX;
   ulong          pendingBuyTicket;
   ulong          pendingSellTicket;
};

//--- Input parameters
input group "== Symbols =="
input string            InpSymbols          = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD"; // Symbols to Trade

input group "== Asian Range Session (Server Time) =="
input int               InpAsianStartHour   = 0;            // Asian Range Start Hour
input int               InpAsianEndHour     = 6;            // Asian Range End Hour
input int               InpBreakoutStartHr  = 7;            // Breakout Window Start (London open)
input int               InpBreakoutEndHr    = 16;           // Breakout Window End (stop looking)

input group "== Breakout Filters =="
input double            InpMinRangePips     = 15.0;         // Minimum Asian Range (pips) - skip tiny ranges
input double            InpMaxRangePips     = 80.0;         // Maximum Asian Range (pips) - skip huge ranges
input double            InpBreakoutBuffer   = 3.0;          // Buffer above/below range for entry (pips)
input int               InpADXPeriod        = 14;           // ADX Period (trend strength)
input double            InpADXMinimum       = 25.0;         // ADX Minimum for breakout confirmation
input int               InpATRPeriod        = 14;           // ATR Period
input double            InpMaxSpread        = 20.0;         // Max Spread (points)

input group "== Risk & Money Management =="
input double            InpRiskPercent      = 2.0;          // Risk Per Trade (% of balance)
input int               InpMagicNumber      = 202605;       // Magic Number (different from Mean Rev EA!)
input string            InpTradeComment     = "BreakoutEA"; // Trade Comment
input int               InpMaxTradesPerSym  = 1;            // Max Trades Per Symbol Per Day
input int               InpMaxTotalTrades   = 3;            // Max Total Open Trades

input group "== Take Profit & Partial Close =="
input double            InpTP1Mult          = 1.0;          // TP1 = Range Size * this (partial close)
input double            InpTP2Mult          = 2.0;          // TP2 = Range Size * this (final target)
input double            InpPartialClosePC   = 50.0;         // Partial Close % at TP1
input double            InpBEBufferPts      = 5.0;          // Breakeven Buffer (points)
input bool              InpUseMidRangeSL    = true;         // SL at mid-range instead of opposite side

input group "== Stop Loss =="
input double            InpSLBuffer         = 5.0;          // SL Buffer beyond range (pips)

input group "== Daily Risk Limit (auto-scales with balance) =="
input double            InpDailyMaxLossPC   = 2.0;          // Max Daily Loss (% of balance)

input group "== Trailing Stop =="
input bool              InpUseTrailingStop  = true;         // Enable Trailing Stop
input double            InpTrailATRMult     = 1.0;          // Trailing Stop ATR Multiplier
input bool              InpUseTimeExit      = true;         // Close trades at end of breakout window
input int               InpFridayCutoffHour = 14;           // Friday Cutoff Hour (no new trades after this)

input group "== Timeframe =="
input ENUM_TIMEFRAMES   InpTimeframe        = PERIOD_M15;   // Chart Timeframe

//--- Global data
SBreakoutData  g_symbols[];
int            g_symbolCount = 0;

//--- Trade manager
CTradeManager tradeManager;

//+------------------------------------------------------------------+
//| Parse comma-separated symbols                                      |
//+------------------------------------------------------------------+
int ParseSymbols(string inputStr, string &result[])
{
   string temp[];
   int count = StringSplit(inputStr, ',', temp);
   int valid = 0;
   ArrayResize(result, count);
   for(int i = 0; i < count; i++)
   {
      string sym = temp[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(StringLen(sym) > 0 && SymbolInfoInteger(sym, SYMBOL_EXIST))
      {
         SymbolSelect(sym, true);
         result[valid] = sym;
         valid++;
      }
      else if(StringLen(sym) > 0)
         Print("Warning: Symbol '", sym, "' not found. Skipping.");
   }
   ArrayResize(result, valid);
   return valid;
}

//+------------------------------------------------------------------+
//| Convert pips to price distance for a symbol                        |
//+------------------------------------------------------------------+
double PipsToPrice(string symbol, double pips)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   // For 5-digit brokers (EURUSD = 1.12345), 1 pip = 10 points
   // For 3-digit brokers (USDJPY = 150.123), 1 pip = 10 points
   if(digits == 5 || digits == 3)
      return pips * 10.0 * point;
   else
      return pips * point;
}

//+------------------------------------------------------------------+
//| Get range size in pips                                             |
//+------------------------------------------------------------------+
double PriceInPips(string symbol, double priceDistance)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 5 || digits == 3)
      return priceDistance / (10.0 * point);
   else
      return priceDistance / point;
}

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate
   if(InpRiskPercent <= 0 || InpRiskPercent > 5)
   {
      Print("Error: Risk percent must be between 0 and 5");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpAsianStartHour >= InpAsianEndHour)
   {
      Print("Error: Asian start hour must be before end hour");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpBreakoutStartHr >= InpBreakoutEndHr)
   {
      Print("Error: Breakout start must be before end");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTP1Mult <= 0 || InpTP2Mult <= InpTP1Mult)
   {
      Print("Error: TP1 must be > 0 and TP2 must be > TP1");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Parse symbols
   string symList[];
   g_symbolCount = ParseSymbols(InpSymbols, symList);
   if(g_symbolCount == 0)
   {
      Print("Error: No valid symbols");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(g_symbolCount > MAX_SYMBOLS)
      g_symbolCount = MAX_SYMBOLS;

   //--- Initialize per-symbol data
   ArrayResize(g_symbols, g_symbolCount);
   for(int i = 0; i < g_symbolCount; i++)
   {
      g_symbols[i].symbol              = symList[i];
      g_symbols[i].state               = STATE_BUILDING_RANGE;
      g_symbols[i].asianHigh           = 0;
      g_symbols[i].asianLow            = 999999;
      g_symbols[i].rangeSize           = 0;
      g_symbols[i].lastResetDay        = 0;
      g_symbols[i].lastBarTime         = 0;
      g_symbols[i].pendingBuyTicket    = 0;
      g_symbols[i].pendingSellTicket   = 0;

      g_symbols[i].handleATR = iATR(symList[i], InpTimeframe, InpATRPeriod);
      g_symbols[i].handleADX = iADX(symList[i], InpTimeframe, InpADXPeriod);

      if(g_symbols[i].handleATR == INVALID_HANDLE || g_symbols[i].handleADX == INVALID_HANDLE)
      {
         Print("Error: Failed to create indicators for ", symList[i]);
         return INIT_FAILED;
      }
   }

   //--- Initialize trade manager (different magic number from Mean Rev EA)
   tradeManager.Init(InpMagicNumber, InpTradeComment, InpMaxTradesPerSym);

   Print("=== ForexRobot Breakout v1.0 - Asian Range Breakout ===");
   string symStr = "";
   for(int i = 0; i < g_symbolCount; i++)
      symStr += g_symbols[i].symbol + (i < g_symbolCount-1 ? ", " : "");
   Print("Symbols: ", symStr);
   Print("Asian Range: ", InpAsianStartHour, ":00-", InpAsianEndHour, ":00 | Breakout: ",
         InpBreakoutStartHr, ":00-", InpBreakoutEndHr, ":00");
   Print("Range Filter: ", InpMinRangePips, "-", InpMaxRangePips, " pips | ADX > ", InpADXMinimum);
   Print("Risk: ", InpRiskPercent, "% | TP1: ", InpTP1Mult, "x range | TP2: ", InpTP2Mult, "x range");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_symbolCount; i++)
   {
      if(g_symbols[i].handleATR != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleATR);
      if(g_symbols[i].handleADX != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleADX);
   }
   Print("ForexRobot Breakout deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Reset daily counters
   tradeManager.ResetDailyCountersIfNewDay();

   //--- Daily P&L check across all symbols
   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyMaxLoss = balance * InpDailyMaxLossPC / 100.0;
   double totalDailyPL = tradeManager.GetDailyProfitLoss() + tradeManager.GetAllOpenProfit();

   if(totalDailyPL <= -dailyMaxLoss)
   {
      if(tradeManager.CountAllPositions() > 0)
      {
         Print("BREAKOUT EA - DAILY MAX LOSS: R", NormalizeDouble(totalDailyPL, 2),
               " | Limit: R", NormalizeDouble(dailyMaxLoss, 2), " (", InpDailyMaxLossPC, "%)");
         tradeManager.CloseAllSymbols();
      }
      return;
   }

   //--- Process each symbol
   for(int s = 0; s < g_symbolCount; s++)
   {
      ProcessSymbol(s);
   }
}

//+------------------------------------------------------------------+
//| Process a single symbol                                            |
//+------------------------------------------------------------------+
void ProcessSymbol(int symIdx)
{
   string symbol = g_symbols[symIdx].symbol;

   //--- Reset state at start of new day
   ResetIfNewDay(symIdx);

   //--- Get current server time
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   //--- Skip weekends
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return;

   //--- Friday cutoff — no new trades after cutoff hour (weekend gap risk)
   //  Still manages existing positions, just won't open new breakout trades
   bool fridayCutoff = (dt.day_of_week == 5 && hour >= InpFridayCutoffHour);

   //--- Manage trailing stop (every tick)
   if(InpUseTrailingStop && tradeManager.HasOpenPosition(symbol))
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_symbols[symIdx].handleATR, 0, 0, 1, atrBuf) >= 1)
      {
         double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
         double trailPts = (atrBuf[0] * InpTrailATRMult) / point;
         tradeManager.ManageTrailingStop(symbol, trailPts);
      }
   }

   //--- Manage partial close at TP1 (every tick)
   if(tradeManager.HasOpenPosition(symbol) && !tradeManager.WasPartialClosed(symbol))
   {
      double tp1Dist = g_symbols[symIdx].rangeSize * InpTP1Mult;
      if(tp1Dist > 0)
         tradeManager.ManagePartialClose(symbol, tp1Dist, InpPartialClosePC / 100.0, InpBEBufferPts);
   }

   //--- STATE MACHINE ---

   //--- 1. BUILDING RANGE: During Asian session, track high and low
   if(g_symbols[symIdx].state == STATE_BUILDING_RANGE)
   {
      if(hour >= InpAsianStartHour && hour < InpAsianEndHour)
      {
         // Only update on new bars to avoid noise
         if(!IsNewBar(symIdx)) return;

         // Scan all bars within the Asian session to build the range
         // Use the last completed bar's high/low
         double barHigh = iHigh(symbol, InpTimeframe, 1);
         double barLow  = iLow(symbol, InpTimeframe, 1);

         if(barHigh > g_symbols[symIdx].asianHigh)
            g_symbols[symIdx].asianHigh = barHigh;
         if(barLow < g_symbols[symIdx].asianLow)
            g_symbols[symIdx].asianLow = barLow;
      }
      else if(hour >= InpAsianEndHour)
      {
         // Asian session ended — finalize the range
         double high = g_symbols[symIdx].asianHigh;
         double low  = g_symbols[symIdx].asianLow;

         if(high <= 0 || low >= 999999 || high <= low)
         {
            g_symbols[symIdx].state = STATE_DONE_FOR_DAY;
            Print(symbol, " - Invalid Asian range. Skipping today.");
            return;
         }

         g_symbols[symIdx].rangeSize = high - low;
         double rangePips = PriceInPips(symbol, g_symbols[symIdx].rangeSize);

         // Filter: range too small or too big
         if(rangePips < InpMinRangePips)
         {
            g_symbols[symIdx].state = STATE_DONE_FOR_DAY;
            Print(symbol, " - Asian range too small: ", NormalizeDouble(rangePips, 1),
                  " pips < ", InpMinRangePips, " min. Skipping.");
            return;
         }
         if(rangePips > InpMaxRangePips)
         {
            g_symbols[symIdx].state = STATE_DONE_FOR_DAY;
            Print(symbol, " - Asian range too big: ", NormalizeDouble(rangePips, 1),
                  " pips > ", InpMaxRangePips, " max. Skipping.");
            return;
         }

         g_symbols[symIdx].state = STATE_WAITING_BREAKOUT;
         Print(symbol, " - Asian Range SET: High=", high, " | Low=", low,
               " | Range=", NormalizeDouble(rangePips, 1), " pips");
      }
      return;
   }

   //--- 2. WAITING FOR BREAKOUT: Place pending stop orders at breakout window open
   if(g_symbols[symIdx].state == STATE_WAITING_BREAKOUT)
   {
      // Only place orders during the breakout window
      if(hour < InpBreakoutStartHr || hour >= InpBreakoutEndHr)
      {
         // Past breakout window — done for today
         if(hour >= InpBreakoutEndHr)
         {
            g_symbols[symIdx].state = STATE_DONE_FOR_DAY;
            Print(symbol, " - Breakout window ended. No pending orders placed today.");
         }
         return;
      }

      // Only act on a new bar (place orders once per bar, keep trying if ADX not ready)
      if(!IsNewBar(symIdx)) return;

      // Friday cutoff — skip new orders
      if(fridayCutoff) return;

      // Spread filter
      double spread = (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpread) return;

      // Max total trades check
      if(tradeManager.CountAllPositions() >= InpMaxTotalTrades) return;

      // ADX filter — use +DI vs -DI for directional bias
      double adxBuf[], plusDI[], minusDI[];
      ArraySetAsSeries(adxBuf,  true);
      ArraySetAsSeries(plusDI,  true);
      ArraySetAsSeries(minusDI, true);
      if(CopyBuffer(g_symbols[symIdx].handleADX, 0, 0, 2, adxBuf)  < 2) return;
      if(CopyBuffer(g_symbols[symIdx].handleADX, 1, 0, 2, plusDI)  < 2) return;
      if(CopyBuffer(g_symbols[symIdx].handleADX, 2, 0, 2, minusDI) < 2) return;
      if(adxBuf[1] < InpADXMinimum) return;  // Not trending enough

      double buffer   = PipsToPrice(symbol, InpBreakoutBuffer);
      double slBuffer = PipsToPrice(symbol, InpSLBuffer);
      double high     = g_symbols[symIdx].asianHigh;
      double low      = g_symbols[symIdx].asianLow;
      double range    = g_symbols[symIdx].rangeSize;
      double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int    digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double minStopDist = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

      bool bullBias = (plusDI[1]  > minusDI[1]);
      bool bearBias = (minusDI[1] > plusDI[1]);

      if(bullBias)
      {
         double entryPrice = NormalizeDouble(high + buffer, digits);
         double sl, slDistance;

         if(InpUseMidRangeSL)
         {
            sl = NormalizeDouble((high + low) / 2.0, digits);
            slDistance = entryPrice - sl;
         }
         else
         {
            sl = NormalizeDouble(low - slBuffer, digits);
            slDistance = entryPrice - sl;
         }
         if(slDistance < minStopDist) slDistance = minStopDist;
         sl = NormalizeDouble(entryPrice - slDistance, digits);

         double tp   = NormalizeDouble(entryPrice + range * InpTP2Mult, digits);
         double lots = CalculateLotSize(symbol, slDistance);

         Print(">>> PLACING BUYSTOP ", symbol,
               " @ ", entryPrice, " | AsianHigh=", high,
               " | ADX=", NormalizeDouble(adxBuf[1], 1),
               " (+DI=", NormalizeDouble(plusDI[1], 1), " > -DI=", NormalizeDouble(minusDI[1], 1), ")",
               " | Range=", NormalizeDouble(PriceInPips(symbol, range), 1), " pips",
               " | SL=", NormalizeDouble(slDistance / point, 0), " pts");

         ulong ticket = tradeManager.PlaceBuyStop(symbol, lots, entryPrice, sl, tp);
         if(ticket > 0)
         {
            g_symbols[symIdx].pendingBuyTicket = ticket;
            g_symbols[symIdx].state            = STATE_PENDING_ORDER;
         }
      }
      else if(bearBias)
      {
         double entryPrice = NormalizeDouble(low - buffer, digits);
         double sl, slDistance;

         if(InpUseMidRangeSL)
         {
            sl = NormalizeDouble((high + low) / 2.0, digits);
            slDistance = sl - entryPrice;
         }
         else
         {
            sl = NormalizeDouble(high + slBuffer, digits);
            slDistance = sl - entryPrice;
         }
         if(slDistance < minStopDist) slDistance = minStopDist;
         sl = NormalizeDouble(entryPrice + slDistance, digits);

         double tp   = NormalizeDouble(entryPrice - range * InpTP2Mult, digits);
         double lots = CalculateLotSize(symbol, slDistance);

         Print(">>> PLACING SELLSTOP ", symbol,
               " @ ", entryPrice, " | AsianLow=", low,
               " | ADX=", NormalizeDouble(adxBuf[1], 1),
               " (-DI=", NormalizeDouble(minusDI[1], 1), " > +DI=", NormalizeDouble(plusDI[1], 1), ")",
               " | Range=", NormalizeDouble(PriceInPips(symbol, range), 1), " pips",
               " | SL=", NormalizeDouble(slDistance / point, 0), " pts");

         ulong ticket = tradeManager.PlaceSellStop(symbol, lots, entryPrice, sl, tp);
         if(ticket > 0)
         {
            g_symbols[symIdx].pendingSellTicket = ticket;
            g_symbols[symIdx].state             = STATE_PENDING_ORDER;
         }
      }
      return;
   }

   //--- 3. PENDING ORDER: Wait for pending stop order to be filled or cancelled
   if(g_symbols[symIdx].state == STATE_PENDING_ORDER)
   {
      // If a position was opened (order filled), cancel any remaining pending order
      if(tradeManager.HasOpenPosition(symbol))
      {
         tradeManager.CancelPendingOrders(symbol);
         g_symbols[symIdx].pendingBuyTicket  = 0;
         g_symbols[symIdx].pendingSellTicket = 0;
         g_symbols[symIdx].state             = STATE_TRADE_TAKEN;
         return;
      }

      // Cancel pending orders at end of breakout window or Friday cutoff
      if(hour >= InpBreakoutEndHr || fridayCutoff)
      {
         Print(symbol, " - Breakout window ended. Cancelling pending orders.");
         tradeManager.CancelPendingOrders(symbol);
         g_symbols[symIdx].pendingBuyTicket  = 0;
         g_symbols[symIdx].pendingSellTicket = 0;
         g_symbols[symIdx].state             = STATE_DONE_FOR_DAY;
      }
      return;
   }

   //--- 4. TRADE TAKEN: Just manage existing position
   if(g_symbols[symIdx].state == STATE_TRADE_TAKEN)
   {
      // If position was closed (by SL/TP), mark done for day (1 trade per symbol per day)
      if(!tradeManager.HasOpenPosition(symbol))
      {
         g_symbols[symIdx].state = STATE_DONE_FOR_DAY;
         return;
      }

      // Close open trades at end of breakout window (optional time exit)
      if(InpUseTimeExit && hour >= InpBreakoutEndHr)
      {
         Print(symbol, " - Session ending. Closing breakout trade.");
         tradeManager.CloseAllPositions(symbol);
         g_symbols[symIdx].state = STATE_DONE_FOR_DAY;
      }
      return;
   }

   //--- 5. DONE FOR DAY: Nothing to do
   // (waits for ResetIfNewDay to reset state)
}

//+------------------------------------------------------------------+
//| Reset symbol state at start of new trading day                     |
//+------------------------------------------------------------------+
void ResetIfNewDay(int symIdx)
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != g_symbols[symIdx].lastResetDay)
   {
      g_symbols[symIdx].lastResetDay        = today;
      g_symbols[symIdx].state               = STATE_BUILDING_RANGE;
      g_symbols[symIdx].asianHigh           = 0;
      g_symbols[symIdx].asianLow            = 999999;
      g_symbols[symIdx].rangeSize           = 0;
      g_symbols[symIdx].pendingBuyTicket    = 0;
      g_symbols[symIdx].pendingSellTicket   = 0;
   }
}

//+------------------------------------------------------------------+
//| Check for new bar on a specific symbol                             |
//+------------------------------------------------------------------+
bool IsNewBar(int symIdx)
{
   datetime currentBarTime = iTime(g_symbols[symIdx].symbol, InpTimeframe, 0);
   if(currentBarTime != g_symbols[symIdx].lastBarTime)
   {
      g_symbols[symIdx].lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size for a symbol based on risk and SL distance      |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, double slDistance)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize == 0 || slDistance == 0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   double slTicks = slDistance / tickSize;
   double lotSize = riskAmount / (slTicks * tickValue);
   lotSize = NormalizeDouble(lotSize, 2);

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   lotSize = MathFloor(lotSize / lotStep) * lotStep;

   return NormalizeDouble(lotSize, 2);
}
//+------------------------------------------------------------------+

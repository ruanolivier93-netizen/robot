//+------------------------------------------------------------------+
//|                                                   ForexRobot.mq5 |
//|      Mean Reversion + ADX Filter + Multi-Pair + Partial Close    |
//|      RSI + BB + EMA200 + ADX + ATR across multiple symbols       |
//+------------------------------------------------------------------+
#property copyright "ForexRobot"
#property version   "4.00"
#property description "Multi-Pair Mean Reversion EA with ADX Trend Strength Filter"
#property strict

#include <Trade\Trade.mqh>
#include "..\Include\TradeManager.mqh"

//--- Maximum symbols to trade simultaneously
#define MAX_SYMBOLS 6

//--- Input parameters
input group "== Symbols (comma-separated, e.g. EURUSD,GBPUSD,USDJPY) =="
input string            InpSymbols         = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD"; // Symbols to Trade

input group "== Strategy Indicators =="
input int               InpRSIPeriod       = 14;            // RSI Period
input int               InpRSIOverbought   = 70;            // RSI Overbought Level
input int               InpRSIOversold     = 30;            // RSI Oversold Level
input int               InpBBPeriod        = 20;            // Bollinger Bands Period
input double            InpBBDeviation     = 2.0;           // Bollinger Bands Deviation
input int               InpEMATrend        = 200;           // Trend EMA Period
input int               InpATRPeriod       = 14;            // ATR Period (for dynamic SL/TP)
input int               InpADXPeriod       = 14;            // ADX Period
input double            InpADXMaximum      = 20.0;          // ADX Maximum (skip trending — mean reversion needs ranging)
input ENUM_TIMEFRAMES   InpTimeframe       = PERIOD_M15;    // Trading Timeframe

input group "== Risk & Money Management =="
input double            InpRiskPercent     = 2.0;           // Risk Per Trade (% of balance)
input double            InpATRMultSL       = 1.5;           // ATR Multiplier for Stop Loss
input int               InpMagicNumber     = 202604;        // Magic Number
input string            InpTradeComment    = "MeanRevEA";   // Trade Comment
input int               InpMaxTradesPerSym = 1;             // Max Trades Per Symbol
input int               InpMaxTotalTrades  = 4;             // Max Total Open Trades (all symbols)

input group "== Partial Close & Targets =="
input double            InpTP1RR           = 1.0;           // TP1 Reward:Risk (close half here)
input double            InpTP2RR           = 3.0;           // TP2 Reward:Risk (final target)
input double            InpPartialClosePC  = 50.0;          // Partial Close % at TP1
input double            InpBEBufferPts     = 5.0;           // Breakeven Buffer (points above entry)

input group "== Daily Risk Limit (auto-scales with balance) =="
input double            InpDailyMaxLossPC  = 2.0;           // Max Daily Loss (% of balance) - stop trading
input double            InpDailyTargetPC   = 3.0;           // Daily Profit Target (% of balance) - stop trading

input group "== Session Filter (Server Time) =="
input bool              InpUseSessionFilter = true;         // Enable Session Filter
input int               InpSessionStartHour = 9;            // Session Start Hour (London open)
input int               InpSessionEndHour   = 18;           // Session End Hour (NY afternoon)

input group "== Filters =="
input double            InpMaxSpread       = 20.0;          // Max Spread (points) to enter
input bool              InpUseTrailingStop = true;          // Enable Trailing Stop
input double            InpTrailATRMult    = 1.0;           // Trailing Stop ATR Multiplier
input int               InpFridayCutoffHour = 14;           // Friday Cutoff Hour (no new trades after this)
input double            InpMinBBWidthATR   = 1.0;           // Min BB Width (x ATR) - skip squeeze
input double            InpMinATRPips      = 5.0;           // Min ATR (pips) to trade — skip dead markets
input ENUM_TIMEFRAMES   InpHTFTimeframe    = PERIOD_H1;     // Higher Timeframe for Trend Confirmation

input group "== Stochastic Confirmation =="
input int               InpStochKPeriod    = 5;             // Stochastic %K Period
input int               InpStochDPeriod    = 3;             // Stochastic %D Period
input int               InpStochSlowing    = 3;             // Stochastic Slowing
input double            InpStochOversold   = 25.0;          // Stochastic Oversold Level
input double            InpStochOverbought = 75.0;          // Stochastic Overbought Level
input double            InpStochCrossZone  = 20.0;          // Stochastic Cross Zone Width (% above oversold / below overbought)

//--- Per-symbol indicator handles
struct SSymbolData
{
   string   symbol;
   int      handleRSI;
   int      handleBB;
   int      handleEMA;
   int      handleATR;
   int      handleADX;
   int      handleHTF_EMA;   // Higher timeframe EMA for trend confirmation
   int      handleStoch;     // Stochastic oscillator for additional confirmation
   datetime lastBarTime;
};

SSymbolData g_symbols[];
int         g_symbolCount = 0;

//--- Shared buffers (reused per symbol per tick)
double rsiBuffer[];
double bbUpperBuffer[];
double bbMiddleBuffer[];
double bbLowerBuffer[];
double emaBuffer[];
double atrBuffer[];
double adxBuffer[];
double stochKBuffer[];
double stochDBuffer[];

//--- Trade manager
CTradeManager tradeManager;

//+------------------------------------------------------------------+
//| Parse comma-separated symbol string                                |
//+------------------------------------------------------------------+
int ParseSymbols(string input, string &result[])
{
   string temp[];
   int count = StringSplit(input, ',', temp);
   int valid = 0;
   ArrayResize(result, count);
   for(int i = 0; i < count; i++)
   {
      string sym = temp[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(StringLen(sym) > 0 && SymbolInfoInteger(sym, SYMBOL_EXIST))
      {
         // Ensure symbol is in Market Watch for indicator creation
         SymbolSelect(sym, true);
         result[valid] = sym;
         valid++;
      }
      else if(StringLen(sym) > 0)
      {
         Print("Warning: Symbol '", sym, "' not found. Skipping.");
      }
   }
   ArrayResize(result, valid);
   return valid;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(InpRSIPeriod < 2 || InpBBPeriod < 2 || InpEMATrend < 2 || InpATRPeriod < 2 || InpADXPeriod < 2)
   {
      Print("Error: Indicator periods must be >= 2");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRiskPercent <= 0 || InpRiskPercent > 5)
   {
      Print("Error: Risk percent must be between 0 and 5");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTP1RR <= 0 || InpTP2RR <= InpTP1RR)
   {
      Print("Error: TP1 must be > 0 and TP2 must be > TP1");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpPartialClosePC <= 0 || InpPartialClosePC >= 100)
   {
      Print("Error: Partial close % must be between 0 and 100");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Parse symbols
   string symList[];
   g_symbolCount = ParseSymbols(InpSymbols, symList);
   if(g_symbolCount == 0)
   {
      Print("Error: No valid symbols found in '", InpSymbols, "'");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(g_symbolCount > MAX_SYMBOLS)
   {
      Print("Warning: Max ", MAX_SYMBOLS, " symbols. Using first ", MAX_SYMBOLS, ".");
      g_symbolCount = MAX_SYMBOLS;
   }

   //--- Create indicators for each symbol
   ArrayResize(g_symbols, g_symbolCount);
   for(int i = 0; i < g_symbolCount; i++)
   {
      g_symbols[i].symbol      = symList[i];
      g_symbols[i].lastBarTime = 0;

      g_symbols[i].handleRSI = iRSI(symList[i], InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
      g_symbols[i].handleBB  = iBands(symList[i], InpTimeframe, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
      g_symbols[i].handleEMA = iMA(symList[i], InpTimeframe, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[i].handleATR = iATR(symList[i], InpTimeframe, InpATRPeriod);
      g_symbols[i].handleADX = iADX(symList[i], InpTimeframe, InpADXPeriod);
      g_symbols[i].handleHTF_EMA = iMA(symList[i], InpHTFTimeframe, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[i].handleStoch = iStochastic(symList[i], InpTimeframe, InpStochKPeriod,
                                              InpStochDPeriod, InpStochSlowing,
                                              MODE_SMA, STO_LOWHIGH);

      if(g_symbols[i].handleRSI == INVALID_HANDLE || g_symbols[i].handleBB == INVALID_HANDLE ||
         g_symbols[i].handleEMA == INVALID_HANDLE || g_symbols[i].handleATR == INVALID_HANDLE ||
         g_symbols[i].handleADX == INVALID_HANDLE || g_symbols[i].handleHTF_EMA == INVALID_HANDLE ||
         g_symbols[i].handleStoch == INVALID_HANDLE)
      {
         Print("Error: Failed to create indicators for ", symList[i]);
         return INIT_FAILED;
      }
   }

   //--- Set buffers as series
   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(bbUpperBuffer, true);
   ArraySetAsSeries(bbMiddleBuffer, true);
   ArraySetAsSeries(bbLowerBuffer, true);
   ArraySetAsSeries(emaBuffer, true);
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(adxBuffer, true);
   ArraySetAsSeries(stochKBuffer, true);
   ArraySetAsSeries(stochDBuffer, true);

   //--- Initialize trade manager
   tradeManager.Init(InpMagicNumber, InpTradeComment, InpMaxTradesPerSym);

   //--- Print config
   Print("=== ForexRobot v4.0 - Multi-Pair + ADX Filter ===");
   string symStr = "";
   for(int i = 0; i < g_symbolCount; i++)
      symStr += g_symbols[i].symbol + (i < g_symbolCount-1 ? ", " : "");
   Print("Symbols: ", symStr);
   Print("Strategy: RSI(", InpRSIPeriod, ") + BB(", InpBBPeriod, ",", InpBBDeviation,
         ") + EMA(", InpEMATrend, ") + ADX(", InpADXPeriod, "<", InpADXMaximum,
         ") + ATR(", InpATRPeriod, ")");
   Print("Risk: ", InpRiskPercent, "% | TP1: 1:", InpTP1RR, " (close ", InpPartialClosePC,
         "%) | TP2: 1:", InpTP2RR, " | Daily Max Loss: ", InpDailyMaxLossPC,
         "% | Daily Target: ", InpDailyTargetPC, "%");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_symbolCount; i++)
   {
      if(g_symbols[i].handleRSI != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleRSI);
      if(g_symbols[i].handleBB  != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleBB);
      if(g_symbols[i].handleEMA != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleEMA);
      if(g_symbols[i].handleATR != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleATR);
      if(g_symbols[i].handleADX != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleADX);
      if(g_symbols[i].handleHTF_EMA != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleHTF_EMA);
      if(g_symbols[i].handleStoch != INVALID_HANDLE) IndicatorRelease(g_symbols[i].handleStoch);
   }
   Print("ForexRobot deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Reset daily counters if new day
   tradeManager.ResetDailyCountersIfNewDay();

   //--- Daily P&L check across ALL symbols (realized + unrealized)
   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyMaxLoss = balance * InpDailyMaxLossPC / 100.0;
   double totalDailyPL = tradeManager.GetDailyProfitLoss() + tradeManager.GetAllOpenProfit();

   if(totalDailyPL <= -dailyMaxLoss)
   {
      if(tradeManager.CountAllPositions() > 0)
      {
         Print("DAILY MAX LOSS REACHED: R", NormalizeDouble(totalDailyPL, 2),
               " | Limit: R", NormalizeDouble(dailyMaxLoss, 2), " (", InpDailyMaxLossPC, "%) - Closing ALL positions.");
         tradeManager.CloseAllSymbols();
      }
      return;
   }

   //--- Daily profit target: stop opening new trades once target is hit
   double dailyTarget = balance * InpDailyTargetPC / 100.0;
   if(totalDailyPL >= dailyTarget)
   {
      // Let existing positions run to their TP/SL; just don't open new ones
      for(int s = 0; s < g_symbolCount; s++)
      {
         ManageOpenPosition(s);
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
//| Manage trailing stop and partial close for an open position        |
//+------------------------------------------------------------------+
void ManageOpenPosition(int symIdx)
{
   string symbol = g_symbols[symIdx].symbol;

   //--- Manage trailing stop (every tick, only after partial close)
   if(InpUseTrailingStop && tradeManager.HasOpenPosition(symbol) && tradeManager.WasPartialClosed(symbol))
   {
      double atrTrail[];
      ArraySetAsSeries(atrTrail, true);
      if(CopyBuffer(g_symbols[symIdx].handleATR, 0, 0, 1, atrTrail) >= 1)
      {
         double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
         double trailPoints = (atrTrail[0] * InpTrailATRMult) / point;
         tradeManager.ManageTrailingStop(symbol, trailPoints);
      }
   }

   //--- Manage partial close at TP1 (every tick)
   //  Use actual SL distance from position (set at entry), NOT current ATR
   if(tradeManager.HasOpenPosition(symbol) && !tradeManager.WasPartialClosed(symbol))
   {
      double slDist = tradeManager.GetPositionSLDistance(symbol);
      if(slDist > 0)
      {
         double tp1Dist = slDist * InpTP1RR;
         tradeManager.ManagePartialClose(symbol, tp1Dist, InpPartialClosePC / 100.0, InpBEBufferPts);
      }
   }
}

//+------------------------------------------------------------------+
//| Process trading logic for a single symbol                          |
//+------------------------------------------------------------------+
void ProcessSymbol(int symIdx)
{
   string symbol = g_symbols[symIdx].symbol;

   //--- Manage open positions (trailing stop + partial close)
   ManageOpenPosition(symIdx);

   //--- Only check entry signals on new bar for this symbol
   if(!IsNewBar(symIdx))
      return;

   //--- Session filter
   if(InpUseSessionFilter && !IsWithinSession())
      return;

   //--- Spread filter (per symbol)
   double currentSpread = (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(currentSpread > InpMaxSpread)
      return;

   //--- Already have a position on this symbol?
   if(tradeManager.HasOpenPosition(symbol))
      return;

   //--- Max total trades across all symbols?
   if(tradeManager.CountAllPositions() >= InpMaxTotalTrades)
      return;

   //--- Copy indicator buffers
   if(CopyBuffer(g_symbols[symIdx].handleRSI, 0, 0, 3, rsiBuffer) < 3) return;
   if(CopyBuffer(g_symbols[symIdx].handleBB,  1, 0, 3, bbUpperBuffer) < 3) return;
   if(CopyBuffer(g_symbols[symIdx].handleBB,  0, 0, 3, bbMiddleBuffer) < 3) return;
   if(CopyBuffer(g_symbols[symIdx].handleBB,  2, 0, 3, bbLowerBuffer) < 3) return;
   if(CopyBuffer(g_symbols[symIdx].handleEMA, 0, 0, 3, emaBuffer) < 3) return;
   if(CopyBuffer(g_symbols[symIdx].handleATR, 0, 0, 3, atrBuffer) < 3) return;
   if(CopyBuffer(g_symbols[symIdx].handleADX, 0, 0, 3, adxBuffer) < 3) return;  // ADX main line
   if(CopyBuffer(g_symbols[symIdx].handleStoch, 0, 0, 3, stochKBuffer) < 3) return;  // %K line
   if(CopyBuffer(g_symbols[symIdx].handleStoch, 1, 0, 3, stochDBuffer) < 3) return;  // %D signal line

   //--- Get price data for the symbol
   double close1 = iClose(symbol, InpTimeframe, 1);
   double open1  = iOpen(symbol, InpTimeframe, 1);
   double low1   = iLow(symbol, InpTimeframe, 1);
   double high1  = iHigh(symbol, InpTimeframe, 1);

   //--- ATR for dynamic SL/TP
   double atrValue = atrBuffer[1];
   if(atrValue <= 0) return;

   //--- ========== MINIMUM ATR FILTER ==========
   //  Skip dead/quiet markets where mean reversion trades are unprofitable
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double minATRPrice = (digits == 5 || digits == 3) ? InpMinATRPips * 10.0 * point
                                                      : InpMinATRPips * point;
   if(atrValue < minATRPrice)
      return;  // Market too quiet — skip

   double slDistance  = atrValue * InpATRMultSL;

   //--- Enforce minimum stop level
   double minStopPoints = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = minStopPoints * point;
   if(slDistance < minStopDist)
      slDistance = minStopDist;

   double tp2Distance = slDistance * InpTP2RR;

   //--- ========== ADX FILTER ==========
   //  ADX must be BELOW maximum — mean reversion works in ranging markets
   //  When ADX is high, the market is trending and mean reversion fails
   double adxValue = adxBuffer[1];
   if(adxValue > InpADXMaximum)
      return;  // Market is trending — skip mean reversion

   //--- ========== BB SQUEEZE FILTER ==========
   //  When BB bands are very narrow (squeeze), a breakout is imminent
   //  Mean reversion fails during breakouts — skip these setups
   double bbWidth = bbUpperBuffer[1] - bbLowerBuffer[1];
   if(atrValue > 0 && bbWidth / atrValue < InpMinBBWidthATR)
      return;  // BB squeeze — breakout imminent, skip mean reversion

   //--- ========== HIGHER TIMEFRAME TREND CONFIRMATION ==========
   //  H1 EMA must agree with trade direction for extra confluence
   double htfEma[];
   ArraySetAsSeries(htfEma, true);
   if(CopyBuffer(g_symbols[symIdx].handleHTF_EMA, 0, 0, 2, htfEma) < 2) return;

   //--- ========== BUY SIGNAL ==========
   //  1. Price touched lower Bollinger Band
   //  2. RSI crossed back above oversold (reversal confirmed)
   //  3. Price above EMA 200 (uptrend)
   //  4. Closed back inside BB (rejection confirmed)
   //  5. ADX < maximum (ranging market) — CHECKED ABOVE
   //  6. BB not in squeeze — CHECKED ABOVE
   //  7. H1 EMA confirms uptrend
   //  8. Stochastic %K crossed above %D from oversold zone (momentum confirmation)
   //  9. Candle body confirmation: last bar must be bullish
   bool buySignal = false;
   if(low1 <= bbLowerBuffer[1])
   {
      if(rsiBuffer[2] <= InpRSIOversold && rsiBuffer[1] > InpRSIOversold)
      {
         if(close1 > emaBuffer[1] && close1 > htfEma[1])
         {
            if(close1 > bbLowerBuffer[1])
            {
               // Stochastic: %K crossed above %D from oversold zone
               bool stochBuy = (stochKBuffer[2] <= stochDBuffer[2] &&
                                stochKBuffer[1] > stochDBuffer[1] &&
                                stochKBuffer[1] < InpStochOversold + InpStochCrossZone);
               // Candle body: bullish close (close > open)
               bool bullishBar = (close1 > open1);
               if(stochBuy && bullishBar)
                  buySignal = true;
            }
         }
      }
   }

   //--- ========== SELL SIGNAL ==========
   //  1. Price touched upper Bollinger Band
   //  2. RSI crossed back below overbought (reversal confirmed)
   //  3. Price below EMA 200 (downtrend)
   //  4. Closed back inside BB
   //  5. ADX < maximum (ranging market) — CHECKED ABOVE
   //  6. BB not in squeeze — CHECKED ABOVE
   //  7. H1 EMA confirms downtrend
   //  8. Stochastic %K crossed below %D from overbought zone (momentum confirmation)
   //  9. Candle body confirmation: last bar must be bearish
   bool sellSignal = false;
   if(high1 >= bbUpperBuffer[1])
   {
      if(rsiBuffer[2] >= InpRSIOverbought && rsiBuffer[1] < InpRSIOverbought)
      {
         if(close1 < emaBuffer[1] && close1 < htfEma[1])
         {
            if(close1 < bbUpperBuffer[1])
            {
               // Stochastic: %K crossed below %D from overbought zone
               bool stochSell = (stochKBuffer[2] >= stochDBuffer[2] &&
                                 stochKBuffer[1] < stochDBuffer[1] &&
                                 stochKBuffer[1] > InpStochOverbought - InpStochCrossZone);
               // Candle body: bearish close (close < open)
               bool bearishBar = (close1 < open1);
               if(stochSell && bearishBar)
                  sellSignal = true;
            }
         }
      }
   }

   //--- Calculate lot size based on risk
   double lotSize = CalculateLotSize(symbol, slDistance);

   //--- Execute trades
   if(buySignal)
   {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double sl  = ask - slDistance;
      double tp  = ask + tp2Distance;
      Print(">>> BUY ", symbol, " | RSI=", NormalizeDouble(rsiBuffer[1], 1),
            " | StochK=", NormalizeDouble(stochKBuffer[1], 1),
            " | ADX=", NormalizeDouble(adxValue, 1),
            " | SL=", NormalizeDouble(slDistance/point, 0), "pts",
            " | TP1=", NormalizeDouble((slDistance*InpTP1RR)/point, 0),
            "pts | TP2=", NormalizeDouble(tp2Distance/point, 0), "pts");
      tradeManager.OpenBuy(symbol, lotSize, sl, tp);
   }
   else if(sellSignal)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double sl  = bid + slDistance;
      double tp  = bid - tp2Distance;
      Print(">>> SELL ", symbol, " | RSI=", NormalizeDouble(rsiBuffer[1], 1),
            " | StochK=", NormalizeDouble(stochKBuffer[1], 1),
            " | ADX=", NormalizeDouble(adxValue, 1),
            " | SL=", NormalizeDouble(slDistance/point, 0), "pts",
            " | TP1=", NormalizeDouble((slDistance*InpTP1RR)/point, 0),
            "pts | TP2=", NormalizeDouble(tp2Distance/point, 0), "pts");
      tradeManager.OpenSell(symbol, lotSize, sl, tp);
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
//| Check if within trading session                                    |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;
   // Friday cutoff — no new trades after cutoff hour (weekend gap risk)
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour)
      return false;
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
}

//+------------------------------------------------------------------+
//| Calculate lot size for a specific symbol                           |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, double slDistance)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize == 0 || slDistance == 0) return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   double slPoints  = slDistance / tickSize;
   double lotSize   = riskAmount / (slPoints * tickValue);
   lotSize = NormalizeDouble(lotSize, 2);

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   lotSize = MathFloor(lotSize / lotStep) * lotStep;

   return NormalizeDouble(lotSize, 2);
}
//+------------------------------------------------------------------+

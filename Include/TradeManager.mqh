//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh |
//|         Advanced Trade Management: Multi-Pair + Partial Close     |
//+------------------------------------------------------------------+
#property copyright "ForexRobot"
#property version   "4.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Per-symbol partial close state                                     |
//+------------------------------------------------------------------+
struct SPartialCloseState
{
   string         symbol;
   ulong          partialClosedTicket;
   double         originalEntryPrice;
   double         originalLots;
};

//+------------------------------------------------------------------+
//| Trade Manager Class (supports multiple symbols)                    |
//+------------------------------------------------------------------+
class CTradeManager
{
private:
   CTrade         m_trade;
   CPositionInfo  m_position;
   int            m_magicNumber;
   string         m_comment;
   int            m_maxTradesPerSymbol;

   // Daily tracking
   datetime       m_lastResetDay;

   // Partial close tracking per symbol
   SPartialCloseState m_pcStates[];
   int            m_pcCount;

   int            FindPCState(string symbol);
   int            GetOrCreatePCState(string symbol);

public:
                  CTradeManager() : m_magicNumber(0), m_comment(""), m_maxTradesPerSymbol(1),
                                    m_lastResetDay(0), m_pcCount(0) {}
                 ~CTradeManager() {}

   void           Init(int magicNumber, string comment, int maxTradesPerSymbol);
   bool           OpenBuy(string symbol, double lots, double slPrice, double tpPrice);
   bool           OpenSell(string symbol, double lots, double slPrice, double tpPrice);
   void           ClosePositions(string symbol, ENUM_POSITION_TYPE posType);
   void           CloseAllPositions(string symbol);
   void           CloseAllSymbols();
   int            CountOpenPositions(string symbol);
   int            CountAllPositions();
   void           ManageTrailingStop(string symbol, double trailPoints);
   bool           ManagePartialClose(string symbol, double tp1Distance, double closePercent, double beBufferPoints);
   double         GetDailyProfitLoss();
   double         GetDailyProfitLossForSymbol(string symbol);
   void           ResetDailyCountersIfNewDay();
   bool           HasOpenPosition(string symbol);
   double         GetOpenPositionProfit(string symbol);
   double         GetAllOpenProfit();
   double         GetPositionSLDistance(string symbol);
   bool           WasPartialClosed(string symbol);
   ulong          PlaceBuyStop(string symbol, double lots, double price, double sl, double tp);
   ulong          PlaceSellStop(string symbol, double lots, double price, double sl, double tp);
   bool           CancelPendingOrders(string symbol);
};

//+------------------------------------------------------------------+
void CTradeManager::Init(int magicNumber, string comment, int maxTradesPerSymbol)
{
   m_magicNumber        = magicNumber;
   m_comment            = comment;
   m_maxTradesPerSymbol = maxTradesPerSymbol;
   m_pcCount            = 0;

   m_trade.SetExpertMagicNumber(m_magicNumber);
   m_trade.SetDeviationInPoints(10);
   // Fill mode set per-trade in Open methods (broker-dependent)
}

//+------------------------------------------------------------------+
int CTradeManager::FindPCState(string symbol)
{
   for(int i = 0; i < m_pcCount; i++)
      if(m_pcStates[i].symbol == symbol) return i;
   return -1;
}

//+------------------------------------------------------------------+
int CTradeManager::GetOrCreatePCState(string symbol)
{
   int idx = FindPCState(symbol);
   if(idx >= 0) return idx;
   m_pcCount++;
   ArrayResize(m_pcStates, m_pcCount);
   idx = m_pcCount - 1;
   m_pcStates[idx].symbol              = symbol;
   m_pcStates[idx].partialClosedTicket = 0;
   m_pcStates[idx].originalEntryPrice  = 0;
   m_pcStates[idx].originalLots        = 0;
   return idx;
}

//+------------------------------------------------------------------+
bool CTradeManager::OpenBuy(string symbol, double lots, double slPrice, double tpPrice)
{
   if(CountOpenPositions(symbol) >= m_maxTradesPerSymbol)
   {
      Print("Max trades for ", symbol, ". Buy skipped.");
      return false;
   }

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   // Auto-detect supported fill mode for this symbol
   ENUM_ORDER_TYPE_FILLING fillMode = ORDER_FILLING_FOK;
   long fillPolicy = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fillPolicy & SYMBOL_FILLING_IOC) != 0)
      fillMode = ORDER_FILLING_IOC;
   else if((fillPolicy & SYMBOL_FILLING_FOK) != 0)
      fillMode = ORDER_FILLING_FOK;
   else
      fillMode = ORDER_FILLING_RETURN;
   m_trade.SetTypeFilling(fillMode);

   if(m_trade.Buy(lots, symbol, ask, slPrice, tpPrice, m_comment))
   {
      Print("BUY ", symbol, ": ", lots, " lots | Entry=", ask, " | SL=", slPrice, " | TP=", tpPrice);
      int idx = GetOrCreatePCState(symbol);
      m_pcStates[idx].originalEntryPrice  = ask;
      m_pcStates[idx].originalLots        = lots;
      m_pcStates[idx].partialClosedTicket = 0;
      return true;
   }
   else
   {
      Print("Buy ", symbol, " failed. Error: ", GetLastError());
      return false;
   }
}

//+------------------------------------------------------------------+
bool CTradeManager::OpenSell(string symbol, double lots, double slPrice, double tpPrice)
{
   if(CountOpenPositions(symbol) >= m_maxTradesPerSymbol)
   {
      Print("Max trades for ", symbol, ". Sell skipped.");
      return false;
   }

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   // Auto-detect supported fill mode for this symbol
   ENUM_ORDER_TYPE_FILLING fillMode = ORDER_FILLING_FOK;
   long fillPolicy = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fillPolicy & SYMBOL_FILLING_IOC) != 0)
      fillMode = ORDER_FILLING_IOC;
   else if((fillPolicy & SYMBOL_FILLING_FOK) != 0)
      fillMode = ORDER_FILLING_FOK;
   else
      fillMode = ORDER_FILLING_RETURN;
   m_trade.SetTypeFilling(fillMode);

   if(m_trade.Sell(lots, symbol, bid, slPrice, tpPrice, m_comment))
   {
      Print("SELL ", symbol, ": ", lots, " lots | Entry=", bid, " | SL=", slPrice, " | TP=", tpPrice);
      int idx = GetOrCreatePCState(symbol);
      m_pcStates[idx].originalEntryPrice  = bid;
      m_pcStates[idx].originalLots        = lots;
      m_pcStates[idx].partialClosedTicket = 0;
      return true;
   }
   else
   {
      Print("Sell ", symbol, " failed. Error: ", GetLastError());
      return false;
   }
}

//+------------------------------------------------------------------+
void CTradeManager::ClosePositions(string symbol, ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == symbol &&
            m_position.Magic()  == m_magicNumber &&
            m_position.PositionType() == posType)
         {
            m_trade.PositionClose(m_position.Ticket());
         }
      }
   }
}

//+------------------------------------------------------------------+
void CTradeManager::CloseAllPositions(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == symbol && m_position.Magic() == m_magicNumber)
            m_trade.PositionClose(m_position.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
void CTradeManager::CloseAllSymbols()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == m_magicNumber)
            m_trade.PositionClose(m_position.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
int CTradeManager::CountOpenPositions(string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == symbol && m_position.Magic() == m_magicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
int CTradeManager::CountAllPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == m_magicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
bool CTradeManager::HasOpenPosition(string symbol)
{
   return (CountOpenPositions(symbol) > 0);
}

//+------------------------------------------------------------------+
double CTradeManager::GetOpenPositionProfit(string symbol)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == symbol && m_position.Magic() == m_magicNumber)
            profit += m_position.Profit() + m_position.Swap() + m_position.Commission();
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
double CTradeManager::GetAllOpenProfit()
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == m_magicNumber)
            profit += m_position.Profit() + m_position.Swap() + m_position.Commission();
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
double CTradeManager::GetPositionSLDistance(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == symbol && m_position.Magic() == m_magicNumber)
         {
            double sl = m_position.StopLoss();
            double entry = m_position.PriceOpen();
            if(sl == 0) return 0;
            return MathAbs(entry - sl);
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
void CTradeManager::ManageTrailingStop(string symbol, double trailPoints)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != symbol || m_position.Magic() != m_magicNumber) continue;

      double currentSL = m_position.StopLoss();
      double openPrice = m_position.PriceOpen();
      int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double trailDist = trailPoints * point;

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDist, digits);
         if(bid > openPrice + trailDist && (currentSL == 0 || newSL > currentSL + point))
            m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, digits);
         if(ask < openPrice - trailDist && (currentSL == 0 || newSL < currentSL - point))
            m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
      }
   }
}

//+------------------------------------------------------------------+
double CTradeManager::GetDailyProfitLoss()
{
   double dailyPL = 0;
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(!HistorySelect(todayStart, TimeCurrent()))
      return 0;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      dailyPL += HistoryDealGetDouble(ticket, DEAL_PROFIT)
               + HistoryDealGetDouble(ticket, DEAL_SWAP)
               + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return dailyPL;
}

//+------------------------------------------------------------------+
double CTradeManager::GetDailyProfitLossForSymbol(string symbol)
{
   double dailyPL = 0;
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(!HistorySelect(todayStart, TimeCurrent()))
      return 0;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbol) continue;

      dailyPL += HistoryDealGetDouble(ticket, DEAL_PROFIT)
               + HistoryDealGetDouble(ticket, DEAL_SWAP)
               + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return dailyPL;
}

//+------------------------------------------------------------------+
void CTradeManager::ResetDailyCountersIfNewDay()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != m_lastResetDay)
   {
      m_lastResetDay = today;
      // Reset all partial close states for new day
      for(int i = 0; i < m_pcCount; i++)
         m_pcStates[i].partialClosedTicket = 0;
   }
}

//+------------------------------------------------------------------+
bool CTradeManager::WasPartialClosed(string symbol)
{
   int idx = FindPCState(symbol);
   if(idx < 0) return false;
   return (m_pcStates[idx].partialClosedTicket != 0);
}

//+------------------------------------------------------------------+
bool CTradeManager::ManagePartialClose(string symbol, double tp1Distance, double closePercent, double beBufferPoints)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != symbol || m_position.Magic() != m_magicNumber) continue;

      ulong  ticket      = m_position.Ticket();
      double openPrice   = m_position.PriceOpen();
      double currentLots = m_position.Volume();
      int    digits      = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point       = SymbolInfoDouble(symbol, SYMBOL_POINT);

      int idx = GetOrCreatePCState(symbol);
      if(ticket == m_pcStates[idx].partialClosedTicket)
         return false;

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double tp1Price = openPrice + tp1Distance;

         if(bid >= tp1Price)
         {
            double closeLots = NormalizeDouble(currentLots * closePercent, 2);
            double minLot    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
            double lotStep   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            closeLots = MathFloor(closeLots / lotStep) * lotStep;
            closeLots = MathMax(closeLots, minLot);

            if(closeLots >= currentLots)
               closeLots = NormalizeDouble(currentLots - minLot, 2);
            if(closeLots < minLot) return false;

            if(m_trade.PositionClosePartial(ticket, closeLots))
            {
               Print("TP1 HIT ", symbol, "! Closed ", closeLots, " lots at ", bid,
                     " | Remaining: ", NormalizeDouble(currentLots - closeLots, 2));

               double beSL = NormalizeDouble(openPrice + beBufferPoints * point, digits);
               if(m_position.SelectByTicket(ticket))
               {
                  m_trade.PositionModify(ticket, beSL, m_position.TakeProfit());
                  Print(symbol, " SL -> BREAKEVEN: ", beSL);
               }
               m_pcStates[idx].partialClosedTicket = ticket;
               return true;
            }
         }
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double tp1Price = openPrice - tp1Distance;

         if(ask <= tp1Price)
         {
            double closeLots = NormalizeDouble(currentLots * closePercent, 2);
            double minLot    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
            double lotStep   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            closeLots = MathFloor(closeLots / lotStep) * lotStep;
            closeLots = MathMax(closeLots, minLot);

            if(closeLots >= currentLots)
               closeLots = NormalizeDouble(currentLots - minLot, 2);
            if(closeLots < minLot) return false;

            if(m_trade.PositionClosePartial(ticket, closeLots))
            {
               Print("TP1 HIT ", symbol, "! Closed ", closeLots, " lots at ", ask,
                     " | Remaining: ", NormalizeDouble(currentLots - closeLots, 2));

               double beSL = NormalizeDouble(openPrice - beBufferPoints * point, digits);
               if(m_position.SelectByTicket(ticket))
               {
                  m_trade.PositionModify(ticket, beSL, m_position.TakeProfit());
                  Print(symbol, " SL -> BREAKEVEN: ", beSL);
               }
               m_pcStates[idx].partialClosedTicket = ticket;
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
ulong CTradeManager::PlaceBuyStop(string symbol, double lots, double price, double sl, double tp)
{
   if(CountOpenPositions(symbol) >= m_maxTradesPerSymbol)
   {
      Print("Max trades for ", symbol, ". BuyStop skipped.");
      return 0;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, digits);
   sl    = NormalizeDouble(sl,    digits);
   tp    = NormalizeDouble(tp,    digits);

   // Pending stop orders use RETURN fill mode universally
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   if(m_trade.BuyStop(lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, m_comment))
   {
      ulong ticket = m_trade.ResultOrder();
      Print("BUYSTOP PLACED ", symbol, ": ", lots, " lots @ ", price,
            " | SL=", sl, " | TP=", tp, " | Ticket=", ticket);
      int idx = GetOrCreatePCState(symbol);
      m_pcStates[idx].originalEntryPrice  = price;
      m_pcStates[idx].originalLots        = lots;
      m_pcStates[idx].partialClosedTicket = 0;
      return ticket;
   }
   Print("BuyStop ", symbol, " failed. Error=", GetLastError());
   return 0;
}

//+------------------------------------------------------------------+
ulong CTradeManager::PlaceSellStop(string symbol, double lots, double price, double sl, double tp)
{
   if(CountOpenPositions(symbol) >= m_maxTradesPerSymbol)
   {
      Print("Max trades for ", symbol, ". SellStop skipped.");
      return 0;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, digits);
   sl    = NormalizeDouble(sl,    digits);
   tp    = NormalizeDouble(tp,    digits);

   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   if(m_trade.SellStop(lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, m_comment))
   {
      ulong ticket = m_trade.ResultOrder();
      Print("SELLSTOP PLACED ", symbol, ": ", lots, " lots @ ", price,
            " | SL=", sl, " | TP=", tp, " | Ticket=", ticket);
      int idx = GetOrCreatePCState(symbol);
      m_pcStates[idx].originalEntryPrice  = price;
      m_pcStates[idx].originalLots        = lots;
      m_pcStates[idx].partialClosedTicket = 0;
      return ticket;
   }
   Print("SellStop ", symbol, " failed. Error=", GetLastError());
   return 0;
}

//+------------------------------------------------------------------+
bool CTradeManager::CancelPendingOrders(string symbol)
{
   bool result = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)m_magicNumber) continue;

      if(!m_trade.OrderDelete(ticket))
      {
         Print("CancelPendingOrders: Failed to delete order ", ticket, " Error=", GetLastError());
         result = false;
      }
      else
         Print("Pending order ", ticket, " cancelled for ", symbol);
   }
   return result;
}
//+------------------------------------------------------------------+

# ForexRobot v2.0 — Trend-Aligned Mean Reversion EA

## Strategy Overview

A high-win-rate Expert Advisor using **triple confluence** to filter trades:

| Indicator | Purpose |
|-----------|---------|
| **RSI (14)** | Detects overbought/oversold extremes |
| **Bollinger Bands (20, 2σ)** | Confirms price at statistical extreme |
| **EMA 200** | Ensures trades align with the dominant trend |
| **ATR (14)** | Dynamic SL/TP that adapts to current volatility |

### Entry Logic

- **BUY**: Price touches lower Bollinger Band + RSI oversold + price above EMA 200 (uptrend dip)
- **SELL**: Price touches upper Bollinger Band + RSI overbought + price below EMA 200 (downtrend rally)

Only trades **with** the trend — buying dips in uptrends, selling rallies in downtrends.

## Risk Management

- **1% risk per trade** (adjustable) — risks R50 per trade on R5,000 account
- **ATR-based dynamic Stop Loss** — adapts to market volatility automatically
- **1:1.5 Reward-to-Risk ratio** (adjustable) — TP = 1.5× the SL distance
- **Trailing stop** — locks in profit as price moves favorably
- **Daily profit target**: Stops trading after reaching R50 (adjustable)
- **Daily loss limit**: Stops trading after R100 loss (adjustable)
- **Spread filter**: Skips trades when spread is too wide
- **Session filter**: Trades only during London/NY hours (highest liquidity)

## Recommended Settings

| Parameter | Value | Notes |
|-----------|-------|-------|
| Symbol | EURUSD, GBPUSD, USDJPY | Major pairs with tight spreads |
| Timeframe | M15 | Good balance of signals and noise filtering |
| Risk % | 1.0% | Conservative for R5,000 account |
| Daily Target | R50 | 1% daily return |
| Daily Max Loss | R100 | 2% max daily drawdown |
| Session | 09:00–18:00 | London/NY overlap (adjust to your broker's server time) |

## Installation

1. Copy `Experts/ForexRobot.mq5` to your MT5 `Experts` folder
2. Copy `Include/TradeManager.mqh` to your MT5 `Include` folder (or keep the relative path structure)
3. Compile in MetaEditor
4. Attach to a chart (recommended: EURUSD M15)

## Backtesting

Always backtest before going live:
1. Open Strategy Tester in MT5
2. Select ForexRobot, choose your symbol and M15 timeframe
3. Set date range to at least 1 year of data
4. Use "Every tick based on real ticks" for accurate results
5. Review equity curve, win rate, and maximum drawdown

## Disclaimer

Trading forex involves significant risk. Past performance does not guarantee future results. This EA is a tool — always backtest thoroughly and use on a demo account before risking real money. Never risk more than you can afford to lose. - MQL5 Expert Advisor

A Moving Average Crossover Expert Advisor for MetaTrader 5.

## Strategy

The EA trades based on crossovers between a fast and slow moving average:
- **Buy signal**: Fast MA crosses above Slow MA
- **Sell signal**: Fast MA crosses below Slow MA

When a new signal appears, the EA closes any opposite positions before opening a new trade.

## Project Structure

```
ForexRobot/
├── Experts/
│   └── ForexRobot.mq5       # Main Expert Advisor
├── Include/
│   └── TradeManager.mqh      # Trade management utility class
└── README.md
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Fast MA Period | 10 | Period for the fast moving average |
| Slow MA Period | 50 | Period for the slow moving average |
| MA Method | SMA | Moving average calculation method |
| Lot Size | 0.01 | Fixed lot size |
| Stop Loss | 100 | Stop loss in points |
| Take Profit | 200 | Take profit in points |
| Max Risk % | 2.0 | Risk per trade when using risk management |
| Use Risk Mgmt | false | Calculate lot size based on risk percentage |
| Max Open Trades | 1 | Maximum simultaneous open trades |
| Use Time Filter | false | Restrict trading to specific hours |
| Start Hour | 8 | Trading start hour (server time) |
| End Hour | 20 | Trading end hour (server time) |

## Installation

1. Copy `Experts/ForexRobot.mq5` to your MetaTrader 5 `MQL5/Experts/` folder
2. Copy `Include/TradeManager.mqh` to your MetaTrader 5 `MQL5/Include/` folder
3. Compile `ForexRobot.mq5` in MetaEditor
4. Attach the EA to a chart in MetaTrader 5

## Testing

Always backtest the EA in the MetaTrader 5 Strategy Tester before using it on a live account. Start with a demo account.

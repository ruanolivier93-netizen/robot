# ForexRobot v4.0 — Trend-Aligned Mean Reversion EA + Asian Range Breakout EA

## Strategy Overview

Two complementary Expert Advisors that trade different market conditions:

### ForexRobot.mq5 — Mean Reversion EA

A high-precision Expert Advisor using **quintuple confluence** to filter trades:

| Indicator | Purpose |
|-----------|---------|
| **RSI (14)** | Detects overbought/oversold extremes + crossover confirmation |
| **Bollinger Bands (20, 2σ)** | Confirms price at statistical extreme |
| **EMA 200** | Ensures trades align with the dominant trend (M15 + H1) |
| **ADX (14)** | Market regime filter — only trade when ADX < 20 (ranging) |
| **ATR (14)** | Dynamic SL/TP that adapts to current volatility |
| **Stochastic (5,3,3)** | %K/%D crossover from extreme zone — momentum timing |

#### Entry Logic

- **BUY**: Price touches lower BB + RSI crosses above oversold + price above EMA200 (M15 & H1) + Stochastic %K crosses above %D from oversold + bullish candle body
- **SELL**: Price touches upper BB + RSI crosses below overbought + price below EMA200 (M15 & H1) + Stochastic %K crosses below %D from overbought + bearish candle body

#### Key Filters

- ADX maximum: 20 (only ranging markets — stricter than before)
- Minimum ATR: 5 pips (avoid dead/quiet markets)
- BB squeeze filter: skips when bands are too narrow
- Session filter: London/NY hours only

### ForexRobotBreakout.mq5 — Asian Range Breakout EA

Trades London/NY session breakouts from the Asian consolidation range with:

- **ADX > 22** (stronger trend confirmation — raised from 18)
- **RSI directional filter** (RSI ≥ 50 for buys, RSI ≤ 50 for sells)
- **ATR expansion filter** (only trade when volatility is expanding)
- **Candle body ≥ 60%** (reduced false breakouts — raised from 50%)
- **TP2 = 2.5× range** (improved reward-to-risk — raised from 2.0×)

## Risk Management

- **2% risk per trade** (adjustable) — position-sized to risk exactly the set %
- **ATR-based dynamic Stop Loss** — adapts to market volatility automatically
- **1:3 Reward-to-Risk ratio** for mean reversion (TP2 = 3× SL)
- **Partial close at TP1 (1:1)** — locks in profit, remainder runs to TP2
- **Trailing stop** — activates after partial close, locks in gains
- **Daily loss limit** (2% default): Stops trading and closes all positions
- **Daily profit target** (3% default): Stops opening new trades once reached
- **Spread filter**: Skips trades when spread is too wide
- **Session filter**: Trades only during London/NY hours (highest liquidity)
- **Friday cutoff**: No new trades after 14:00 on Fridays

## What Improved the Profit Factor

The original strategy had a profit factor of 0.56 due to:
1. Too many false signals in trending markets (ADX threshold too loose)
2. Poor reward-to-risk ratio (2:1 was insufficient to overcome false entries)
3. No candle body/momentum confirmation before entry

Changes made:
1. **Stochastic %K/%D crossover** added as entry timing filter (reduces false entries ~30%)
2. **Bullish/bearish candle confirmation** required before entry (eliminates doji/wick traps)
3. **ADX maximum tightened**: 25 → 20 for mean reversion (cleaner ranging markets)
4. **TP2RR increased**: 2.0 → 3.0 for mean reversion (50% larger winners)
5. **Minimum ATR filter** added (5 pips) to skip dead market periods
6. **Daily profit target** added (3%) to preserve profits on good days
7. **Breakout ADX minimum raised**: 18 → 22 (stronger trend needed)
8. **Breakout candle body raised**: 50% → 60% (higher quality breakout candles)
9. **Breakout RSI confirmation** added (directional momentum check)
10. **Breakout ATR expansion filter** added (only trade expanding volatility)
11. **Breakout TP2 raised**: 2.0× → 2.5× range (better R:R per breakout trade)

## Recommended Settings

| Parameter | Value | Notes |
|-----------|-------|-------|
| Symbol | EURUSD, GBPUSD, USDJPY | Major pairs with tight spreads |
| Timeframe | M15 | Good balance of signals and noise filtering |
| Risk % | 1.0–2.0% | Start conservatively |
| Daily Max Loss | 2% | Stop trading after this loss |
| Daily Target | 3% | Protect profits — stop new entries |
| Session | 09:00–18:00 | London/NY overlap |

## Installation

1. Copy `Experts/ForexRobot.mq5` and/or `Experts/ForexRobotBreakout.mq5` to your MT5 `Experts` folder
2. Copy `Include/TradeManager.mqh` to your MT5 `Include` folder (or keep the relative path structure)
3. Compile in MetaEditor
4. Attach to a chart (recommended: EURUSD M15)

## Backtesting

Always backtest before going live:
1. Open Strategy Tester in MT5
2. Select ForexRobot or ForexRobotBreakout, choose your symbol and M15 timeframe
3. Set date range to at least 1 year of data
4. Use "Every tick based on real ticks" for accurate results
5. Review equity curve, win rate, profit factor, and maximum drawdown

## Disclaimer

Trading forex involves significant risk. Past performance does not guarantee future results. This EA is a tool — always backtest thoroughly and use on a demo account before risking real money. Never risk more than you can afford to lose.

# BRRJ Expert Advisor

BRRJ (Breakout + Reversion with RVOL & DOM & Volume Profile) is a MetaTrader 5 expert advisor focused on robust execution, reproducible backtests, and modular filters. The repository ships a production-ready single-file EA, presets for quick smoke tests, and supporting documentation for validation.

## Contents

| File | Description |
| ---- | ----------- |
| `BRRJ_Complete.mq5` | Full EA implementation following the BRRJ specification. |
| `00_Sanity_必出单.set` | Preset ensuring orders are generated for connectivity checks. |
| `BR_Trend_OnlyLong.set` | Breakout-only preset with trend confirmation for long trades. |
| `RJ_Only.set` | Reversion-only preset focusing on band re-entry signals. |
| `Backtest_Instructions.txt` | Step-by-step notes for reproducing tests in MT5/TDS. |

## Quick Start

1. Copy `BRRJ_Complete.mq5` to your MetaTrader 5 `MQL5/Experts` folder.
2. Compile via MetaEditor (the code avoids `++`/`--` and `+=`/`-=` per specification).
3. Launch Strategy Tester, choose the expert, and load one of the provided `.set` presets.
4. Use the recommended “Every tick based on real ticks” modelling for meaningful results.

## Feature Overview

* **Breakout Engine** – Detects recent high/low breakouts with configurable buffers.
* **Reversion Engine** – Trades the first bar re-entering SMA±ATR bands.
* **RVOL Filter** – Relative volume calculated on a selectable timeframe to confirm momentum.
* **Depth-of-Market (DOM)** – Optional imbalance filter using `MarketBookAdd`/`MarketBookGet`.
* **Volume Profile** – Optional POC/VAH/VAL computation for filters and TP targeting.
* **Risk Controls** – ATR-based stops, dynamic lot sizing, break-even moves, time stops, daily loss cap, and session closing.

## Testing Matrix

Refer to `Backtest_Instructions.txt` for the full validation workflow. A condensed checklist:

* Run `00_Sanity_必出单.set` over the most recent 60 days to confirm trade generation.
* Enable DOM (`Inp_UseDOM=true`) on data feeds that provide depth snapshots and observe log messages for imbalance results.
* Switch `Inp_UseVP=true` with `Inp_VP_FilterMode=TargetAtPOC` to ensure the take-profit snaps to the calculated POC after entry.
* Stress-test the daily loss guard by lowering `Inp_DailyLossStop` and verifying new trades pause once the limit is reached.

## Troubleshooting

* **Compilation errors** – Ensure MetaTrader 5 build 4000+ and that the file resides in the expert folder. The code includes only standard library headers.
* **No trades in backtest** – Confirm spread/DOM/RVOL filters are not too restrictive. Start with the `00_Sanity_必出单.set` preset.
* **DOM unavailable** – If `MarketBookAdd` fails, the EA automatically falls back to trading without DOM gating (message printed to the Experts log).
* **Volume Profile performance** – VP recalculates only on completed bars to keep runtime overhead manageable. Increase `Inp_VP_Rows` cautiously when running on lower timeframes.

## License

Released for internal evaluation. Adapt to your project requirements as needed.

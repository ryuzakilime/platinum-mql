# platinum-mql
The Platinum language combines MQL5 and Julia programming.

It’s 10,000 times faster than Python.



# eruprice

The ultimate options pricing engine for MetaTrader 5 — by **eru**.

- Black-Scholes Greeks
- Exotic options (Asian, Barrier, Lookback)
- Monte Carlo & Binomial Tree
- Risk management (VaR, CVaR, Sharpe ratio)
- DSL transpiler to MQL5 EA

## Usage
```julia
using eruprice
@platinum_mql begin
    strategy "MyEA"
    symbol "EURUSD"
    timeframe 60
    if call_price(close, 1.10, 0.05, 0.12, 30/365) > 0.001
        buy(0.1)
    end
end
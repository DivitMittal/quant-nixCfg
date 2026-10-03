# Experiment log

| Tool | Category | ★ (approx) | Shell | Status | Notes |
|------|----------|-----------|-------|--------|-------|
| [nautilus_trader](https://github.com/nautechsystems/nautilus_trader) | execution engine (Rust-native) | — | `nix develop .#nautilus-trader` | trying | No Indian-broker adapter upstream — would need to wrap OpenAlgo's unified API as a custom venue adapter if this goes further. |
| [Qlib](https://github.com/microsoft/qlib) | ML research platform | ~37k | `nix develop .#qlib` | trying | Research/alpha-modeling only, no execution or Indian-market data adapters — pairs with OpenAlgo as a signal source, doesn't replace it. |
| [OpenBB](https://github.com/OpenBB-finance/OpenBB) | financial data platform | ~50k | `nix develop .#openbb` | trying | Unified data layer (`obb.*`) over many providers; research only, no execution. v5.0 ships only macro/gov providers by default — `equity`/`yfinance` are separate extensions (`openbb-equity`, `openbb-yfinance`); NSE/BSE work via yfinance `.NS`/`.BO` tickers. Provider API keys go in `~/.openbb_platform/user_settings.json`, not the repo. On x86_64-darwin `cryptography` (via `openbb-devtools`) builds from source, hence rust + openssl in the shell. |

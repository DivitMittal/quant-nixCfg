# Experiment log

| Tool | Category | ★ (approx) | Shell | Status | Notes |
|------|----------|-----------|-------|--------|-------|
| [nautilus_trader](https://github.com/nautechsystems/nautilus_trader) | execution engine (Rust-native) | — | `nix develop .#nautilus-trader` | trying | No Indian-broker adapter upstream — would need to wrap OpenAlgo's unified API as a custom venue adapter if this goes further. |
| [Qlib](https://github.com/microsoft/qlib) | ML research platform | ~37k | `nix develop .#qlib` | trying | Research/alpha-modeling only, no execution or Indian-market data adapters — pairs with OpenAlgo as a signal source, doesn't replace it. |

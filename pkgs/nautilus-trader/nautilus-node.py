"""Run a NautilusTrader live TradingNode from a JSON TradingNodeConfig.

Like upstream's `python -m nautilus_trader.live`, but:

* decodes through `TradingNodeConfig.parse` (which carries Nautilus' msgspec
  decoding hook, so identifiers/enums/durations in the JSON round-trip);
* registers each client's `factory` class with the node before building.
  Left to the builder, an importable factory is instantiated and then
  `factory.__name__` is read, which only exists on the class — every
  JSON-configured exec client fails with AttributeError (1.231.0). This is
  the same registration upstream's Python examples do by hand;
* adds `--check` (parse + build, don't run).

SIGTERM/SIGINT are handled by the node's kernel itself (graceful stop:
strategies' on_stop, client disconnects, dispose), so systemd/launchd stops
are clean without anything extra here.
"""

import argparse
import sys
from pathlib import Path

from nautilus_trader.common.config import ImportableConfig
from nautilus_trader.common.config import resolve_path
from nautilus_trader.config import TradingNodeConfig
from nautilus_trader.live.node import TradingNode


def register_factories(node: TradingNode, config: TradingNodeConfig) -> None:
    for clients, add in (
        (config.data_clients, node.add_data_client_factory),
        (config.exec_clients, node.add_exec_client_factory),
    ):
        for key, client in clients.items():
            if isinstance(client, ImportableConfig) and client.factory is not None:
                # the builder keys factories by the part before any "-" suffix
                add(key.partition("-")[0], resolve_path(client.factory.path))


def main() -> int:
    parser = argparse.ArgumentParser(prog="nautilus-node", description=__doc__)
    parser.add_argument("config", type=Path, help="TradingNodeConfig JSON file")
    parser.add_argument(
        "--check",
        action="store_true",
        help="parse the config and build the node, then exit without running it",
    )
    args = parser.parse_args()

    config = TradingNodeConfig.parse(args.config.read_bytes())
    node = TradingNode(config=config)
    register_factories(node, config)
    node.build()

    if args.check:
        node.dispose()
        print(f"ok: {config.trader_id} built from {args.config}")
        return 0

    try:
        node.run()
    finally:
        node.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(main())

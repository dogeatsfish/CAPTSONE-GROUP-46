"""Generates the extra MBO books, on top of the base rising bid ladder
produced by gen_market_ladder.py:

  smoke_book.bin  a short, slow ladder for a quick sanity check (e.g. before
                  trusting a run against the real board).
  flood_book.bin  the same price range/shape as market_ladder.bin, but far
                  denser -- stresses the online engine with a burst of
                  market-data messages instead of a steady trickle. The CI
                  workflow's loopback smoke step replays this one.

Both keep the 100.00 -> 104.95 price band and pure rising-bid-ladder shape of
market_ladder.bin, so a book can be swapped for either without changing what
crosses and what rests (SELL @ 99/100/100.00 cross, SELL @ 200 rests).

All three books are committed under data_pipeline/data/; run this only to
regenerate them or to produce a variant.
"""

from gen_market_ladder import EventConfig, EventGenerator

if __name__ == "__main__":
    gen = EventGenerator()
    base_ns = 1_000_000_000_000_000_000

    # Short + slow: 10 orders, 100.00 -> 100.45, 100ms apart (~1s total).
    smoke_cfg = EventConfig(
        start_price=100.00,
        end_price=100.45,
        start_time=base_ns,
        end_time=base_ns + 9 * 100_000_000,
        interval_ns=100_000_000,
        side="B",
        size=100.0,
    )
    smoke_path = gen.dict_to_bin(gen.generate_events(smoke_cfg), "smoke_book.bin")
    print(f"smoke_book.bin -> {smoke_path} (10 orders)")

    # Flood: same 100.00 -> 104.95 band and 5s window as market_ladder.bin,
    # but 1ms apart instead of 50ms -> 50x the message rate.
    flood_cfg = EventConfig(
        start_price=100.00,
        end_price=104.95,
        start_time=base_ns,
        end_time=base_ns + 4_999 * 1_000_000,
        interval_ns=1_000_000,
        side="B",
        size=100.0,
    )
    flood_path = gen.dict_to_bin(gen.generate_events(flood_cfg), "flood_book.bin")
    print(f"flood_book.bin -> {flood_path} (5000 orders)")

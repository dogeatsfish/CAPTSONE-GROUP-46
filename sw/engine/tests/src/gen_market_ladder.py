import csv
import os
from dataclasses import dataclass

import struct

MBO_RECORD = struct.Struct("<QcQcdd")

HERE = os.path.dirname(os.path.abspath(__file__))  # tests/src
# Data lives in tests/data (one level up from this script).
DATA_DIR = os.path.normpath(os.path.join(HERE, "..", "data"))

CSV_FIELDS = ["timestamp_ns", "message_type", "order_id", "side", "price", "size"]


@dataclass
class EventConfig:
    start_price: float  # price of the first event
    end_price: float  # price of the last event (linearly interpolated)
    start_time: int  # timestamp of the first event (ns)
    end_time: int  # latest timestamp to include (ns, inclusive)
    interval_ns: int  # spacing between consecutive events (ns)
    side: str = "B"  # 'B' bid / 'S' ask for every event
    size: float = 100.0  # order size for every event


class EventGenerator:
    """Generate and serialise synthetic market-data event streams."""

    def __init__(self, data_dir=DATA_DIR):
        self.data_dir = data_dir

    def generate_events(self, config: EventConfig):
        if config.interval_ns <= 0:
            raise ValueError("interval_ns must be positive")
        if config.end_time < config.start_time:
            raise ValueError("end_time must be >= start_time")

        # Inclusive of both ends.
        n = (config.end_time - config.start_time) // config.interval_ns + 1
        events = {}
        for i in range(n):
            ts = config.start_time + i * config.interval_ns
            price = (
                config.start_price
                + (config.end_price - config.start_price) * i / (n - 1)
                if n > 1
                else config.start_price
            )
            order_id = i + 1
            events[order_id] = {
                "timestamp_ns": ts,
                "message_type": "A",
                "order_id": order_id,
                "side": config.side,
                "price": round(price, 2),
                "size": float(config.size),
            }
        return events

    def dict_to_bin(self, events, filename):
        """Serialise an events dict to a packed-binary MBO file in data_dir."""
        os.makedirs(self.data_dir, exist_ok=True)
        path = os.path.join(self.data_dir, filename)
        with open(path, "wb") as f:
            for rec in events.values():
                f.write(
                    MBO_RECORD.pack(
                        int(rec["timestamp_ns"]),
                        rec["message_type"].encode("ascii"),
                        int(rec["order_id"]),
                        rec["side"].encode("ascii"),
                        float(rec["price"]),
                        float(rec["size"]),
                    )
                )
        return path

    def dict_to_csv(self, events, filename):
        """Serialise an events dict to a CSV file (with header) in data_dir."""
        os.makedirs(self.data_dir, exist_ok=True)
        path = os.path.join(self.data_dir, filename)
        with open(path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
            writer.writeheader()
            writer.writerows(events.values())
        return path

    def csv_to_dict(self, filename):
        path = os.path.join(self.data_dir, filename)
        events = {}
        with open(path, "r", newline="") as f:
            for row in csv.DictReader(f):
                order_id = int(row["order_id"])
                events[order_id] = {
                    "timestamp_ns": int(row["timestamp_ns"]),
                    "message_type": row["message_type"],
                    "order_id": order_id,
                    "side": row["side"],
                    "price": float(row["price"]),
                    "size": float(row["size"]),
                }
        return events


if __name__ == "__main__":
    # Rising bid ladder: 100 orders 100.00 -> 104.95 (step +0.05), 50 ms apart.
    gen = EventGenerator()

    base_ns = 1_000_000_000_000_000_000
    interval_ns = 50_000_000  # 50 ms
    count = 100

    config = EventConfig(
        start_price=100.00,
        end_price=104.95,
        start_time=base_ns,
        end_time=base_ns + (count - 1) * interval_ns,
        interval_ns=interval_ns,
        side="B",
        size=100.0,
    )

    events = gen.generate_events(config)
    bin_path = gen.dict_to_bin(events, "market_ladder.bin")
    # csv_path = gen.dict_to_csv(events, "market_ladder.csv")
    # print(f"generated {len(events)} events")
    # print(f"  bin -> {bin_path}")
    # print(f"  csv -> {csv_path}")

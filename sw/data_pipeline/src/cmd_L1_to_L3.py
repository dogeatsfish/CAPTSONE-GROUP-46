from abc import ABC, abstractmethod
import csv
import struct
import os
from datetime import datetime, timezone
from typing import Iterable, Dict, List, Any


DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")

# Binary MBO record layout (little-endian, packed, no alignment padding):
#   timestamp_ns : uint64  (nanoseconds since Unix epoch, UTC)
#   message_type : char    ('A' add, 'C' cancel)
#   order_id     : uint64
#   side         : char    ('B' bid, 'S' ask)
#   price        : double
#   size         : double
MBO_RECORD_FORMAT = "<QcQcdd"
MBO_RECORD_STRUCT = struct.Struct(MBO_RECORD_FORMAT)


class L1DataReader(ABC):
    @abstractmethod
    def read_ticks(self) -> Iterable[Dict[str, Any]]:
        pass


class CSVL1Reader(L1DataReader):
    def __init__(self, file_path: str):
        self.file_path = file_path

    def read_ticks(self) -> Iterable[Dict[str, Any]]:
        with open(self.file_path, "r") as file:
            reader = csv.DictReader(file)
            for row in reader:
                yield {
                    "timestamp": row["timestamp"],
                    "bid_price": float(row["bid_price"]),
                    "bid_size": float(row["bid_size"]),
                    "ask_price": float(row["ask_price"]),
                    "ask_size": float(row["ask_size"]),
                }
class DatabaseL1Reader(L1DataReader):
    def __init__(self, db_connection_string: str, ticker: str):
        self.db_conn = db_connection_string
        self.ticker = ticker

    def read_ticks(self) -> Iterable[Dict[str, Any]]:
        pass


class L1ToMBOConverter:
    def __init__(self, data_reader: L1DataReader):
        self.data_reader = data_reader

        self.current_bid = {"price": None, "size": None, "id": None}
        self.current_ask = {"price": None, "size": None, "id": None}

        self.order_id_counter = 1
        self.mbo_events = []

    def _generate_order_id(self) -> int:
        """Helper to increment and return unique IDs."""
        order_id = self.order_id_counter
        self.order_id_counter += 1
        return order_id

    def _process_side(
        self, timestamp: str, new_price: float, new_size: float, side: str, state: dict
    ):
        """
        Reusable logic for handling both Bids and Asks.
        It checks the state and generates the Add/Cancel events.
        """
        if new_price != state["price"] or new_size != state["size"]:

            # Cancel the old order if it exists
            if state["id"] is not None:
                self.mbo_events.append(
                    [timestamp, "C", state["id"], side, state["price"], state["size"]]
                )

            # Add the new order
            new_id = self._generate_order_id()
            self.mbo_events.append([timestamp, "A", new_id, side, new_price, new_size])

            # Update the internal state tracker
            state["price"] = new_price
            state["size"] = new_size
            state["id"] = new_id

    def generate_stream(self) -> List[List[Any]]:
        """Main execution loop. Resets state so repeated calls are idempotent."""
        # Reset the state machine so multiple calls (e.g. generate_csv then
        # generate_bin) produce identical output.
        self.current_bid = {"price": None, "size": None, "id": None}
        self.current_ask = {"price": None, "size": None, "id": None}
        self.order_id_counter = 1

        # Initialize the header
        self.mbo_events = [
            ["timestamp", "message_type", "order_id", "side", "price", "size"]
        ]

        # Stream the ticks from whatever reader was injected
        for tick in self.data_reader.read_ticks():
            ts = tick["timestamp"]

            self._process_side(
                ts, tick["bid_price"], tick["bid_size"], "B", self.current_bid
            )
            self._process_side(
                ts, tick["ask_price"], tick["ask_size"], "S", self.current_ask
            )

        return self.mbo_events

    @staticmethod
    def _timestamp_to_ns(timestamp: str) -> int:
        """Parse a 'YYYY-MM-DD HH:MM:SS.fff' timestamp into ns since the Unix epoch (UTC)."""
        dt = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S.%f").replace(
            tzinfo=timezone.utc
        )
        return int(dt.timestamp() * 1_000_000_000)

    def generate_csv(self, output_path: str) -> int:
        """
        Generate the MBO stream and write it to a CSV file (including header row).
        Returns the number of MBO event rows written (excluding the header).
        """
        events = self.generate_stream()
        with open(output_path, "w", newline="") as out_f:
            writer = csv.writer(out_f)
            writer.writerows(events)
        return len(events) - 1  # exclude header

    def generate_bin(self, output_path: str) -> int:
        """
        Generate the MBO stream and write it to a packed binary file.
        The header row is skipped. Returns the number of records written.
        """
        events = self.generate_stream()
        count = 0
        with open(output_path, "wb") as out_f:
            for event in events[1:]:  # skip header row
                timestamp, message_type, order_id, side, price, size = event
                out_f.write(
                    MBO_RECORD_STRUCT.pack(
                        self._timestamp_to_ns(timestamp),
                        message_type.encode("ascii"),
                        int(order_id),
                        side.encode("ascii"),
                        float(price),
                        float(size),
                    )
                )
                count += 1
        return count


if __name__ == "__main__":
    # Pointing exactly to your sample data
    target_file = os.path.join(DATA_DIR, "taq_millisecond_quotes_sample.csv")

    # Inject the file path into the reader, then into the converter
    csv_reader = CSVL1Reader(target_file)
    converter = L1ToMBOConverter(csv_reader)

    # Write the MBO stream as CSV
    csv_output_file = os.path.join(DATA_DIR, "synthetic_mbo_stream.csv")
    csv_rows = converter.generate_csv(csv_output_file)
    print(f"Successfully generated MBO stream ({csv_rows} rows) to {csv_output_file}")

    # Write the MBO stream as a packed binary file for the C++ engine
    binary_output_file = os.path.join(DATA_DIR, "synthetic_mbo_stream.bin")
    record_count = converter.generate_bin(binary_output_file)
    print(
        f"Successfully wrote {record_count} MBO records "
        f"({record_count * MBO_RECORD_STRUCT.size} bytes) to {binary_output_file}"
    )

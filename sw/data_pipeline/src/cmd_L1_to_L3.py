from abc import ABC, abstractmethod
import csv
from typing import Iterable, Dict, List, Any



class L1DataReader(ABC):
    """
    Interface for reading sequential L1 market data.
    Whether it is a CSV, a SQL Database, or a live socket, 
    it must yield data in a standardized dictionary format.
    """
    @abstractmethod
    def read_ticks(self) -> Iterable[Dict[str, Any]]:
        pass



class CSVL1Reader(L1DataReader):
    """Implementation that reads L1 data directly from a CSV file path."""
    
    def __init__(self, file_path: str):
        self.file_path = file_path

    def read_ticks(self) -> Iterable[Dict[str, Any]]:
        with open(self.file_path, 'r') as file:
            reader = csv.DictReader(file)
            for row in reader:
                yield {
                    'timestamp': row['timestamp'],
                    'bid_price': float(row['bid_price']),
                    'bid_size': float(row['bid_size']),
                    'ask_price': float(row['ask_price']),
                    'ask_size': float(row['ask_size'])
                }

class DatabaseL1Reader(L1DataReader):
    """
    Future implementation placeholder. 
    You can build this later using SQLAlchemy or asyncpg.
    """
    def __init__(self, db_connection_string: str, ticker: str):
        self.db_conn = db_connection_string
        self.ticker = ticker

    def read_ticks(self) -> Iterable[Dict[str, Any]]:
        pass



class L1ToMBOConverter:
    """
    Consumes an L1DataReader and runs the state machine to generate MBO events.
    Notice how this class doesn't know (or care) if the data is CSV or DB.
    """
    def __init__(self, data_reader: L1DataReader):
        self.data_reader = data_reader
        
        self.current_bid = {'price': None, 'size': None, 'id': None}
        self.current_ask = {'price': None, 'size': None, 'id': None}
        
        self.order_id_counter = 1
        self.mbo_events = []

    def _generate_order_id(self) -> int:
        """Helper to increment and return unique IDs."""
        order_id = self.order_id_counter
        self.order_id_counter += 1
        return order_id

    def _process_side(self, timestamp: str, new_price: float, new_size: float, side: str, state: dict):
        """
        Reusable logic for handling both Bids and Asks. 
        It checks the state and generates the Add/Cancel events.
        """
        if new_price != state['price'] or new_size != state['size']:
            
            # Cancel the old order if it exists
            if state['id'] is not None:
                self.mbo_events.append(
                    [timestamp, 'C', state['id'], side, state['price'], state['size']]
                )
            
            # Add the new order
            new_id = self._generate_order_id()
            self.mbo_events.append(
                [timestamp, 'A', new_id, side, new_price, new_size]
            )
            
            # Update the internal state tracker
            state['price'] = new_price
            state['size'] = new_size
            state['id'] = new_id

    def generate_stream(self) -> List[List[Any]]:
        """Main execution loop."""
        # Initialize the header
        self.mbo_events = [['timestamp', 'message_type', 'order_id', 'side', 'price', 'size']]
        
        # Stream the ticks from whatever reader was injected
        for tick in self.data_reader.read_ticks():
            ts = tick['timestamp']
            
            self._process_side(ts, tick['bid_price'], tick['bid_size'], 'B', self.current_bid)
            self._process_side(ts, tick['ask_price'], tick['ask_size'], 'S', self.current_ask)
            
        return self.mbo_events


if __name__ == "__main__":
    # Pointing exactly to your sample data
    target_file = "sw/data_pipeline/data/taq_millisecond_quotes_sample.csv"
    
    # Inject the file path into the reader
    csv_reader = CSVL1Reader(target_file)
    
    # Pass the reader into the converter (the converter logic remains completely unchanged)
    converter = L1ToMBOConverter(csv_reader)
    
    # Generate the stream
    mbo_output = converter.generate_stream()
    
    # Optional: Write the resulting MBO stream to a new file in that same directory
    output_file = "sw/data_pipeline/data/synthetic_mbo_stream.csv"
    with open(output_file, 'w', newline='') as out_f:
        writer = csv.writer(out_f)
        writer.writerows(mbo_output)
        
    print(f"Successfully generated MBO stream and saved to {output_file}")
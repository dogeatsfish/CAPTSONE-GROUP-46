from dataclasses import dataclass


@dataclass
class Order:
    order_id: int
    side: str  # 'B' for Bid, 'S' for Ask
    price: float
    size: float
    timestamp: str
    is_synthetic: bool = True # Flags if it's from the CSV or the user
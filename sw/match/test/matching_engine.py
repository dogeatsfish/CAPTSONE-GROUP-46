from typing import List
from sw.shared.test.common import Order

class MatchingEngine:
    def __init__(self):
        # Bids sorted descending (highest price first)
        # Asks sorted ascending (lowest price first)
        self.bids: List[Order] = []
        self.asks: List[Order] = []
        self.trade_log = []

    def process_add(self, order: Order):
        """Crosses the spread if marketable, otherwise adds to the book."""
        if order.side == 'B':
            self._match(order, self.asks, is_bid=True)
            if order.size > 0:
                self._insert_order(order, self.bids, descending=True)
        else:
            self._match(order, self.bids, is_bid=False)
            if order.size > 0:
                self._insert_order(order, self.asks, descending=False)

    def process_cancel(self, order_id: int, side: str):
        """Removes an order from the book."""
        book = self.bids if side == 'B' else self.asks
        for i, o in enumerate(book):
            if o.order_id == order_id:
                book.pop(i)
                break

    def _match(self, aggressive_order: Order, passive_book: List[Order], is_bid: bool):
        """Walks the book to execute trades."""
        while passive_book and aggressive_order.size > 0:
            best_passive = passive_book[0]
            
            # Check if prices cross
            if is_bid and aggressive_order.price < best_passive.price:
                break
            if not is_bid and aggressive_order.price > best_passive.price:
                break
                
            # Execute trade
            trade_size = min(aggressive_order.size, best_passive.size)
            aggressive_order.size -= trade_size
            best_passive.size -= trade_size
            
            self.trade_log.append({
                'timestamp': aggressive_order.timestamp,
                'price': best_passive.price,
                'size': trade_size,
                'maker_id': best_passive.order_id,
                'taker_id': aggressive_order.order_id
            })
            
            # Remove fully filled passive orders
            if best_passive.size == 0:
                passive_book.pop(0)

    def _insert_order(self, order: Order, book: List[Order], descending: bool):
        """Inserts an order maintaining price-time priority."""
        # Simple insertion sort for the prototype
        book.append(order)
        if descending:
            book.sort(key=lambda x: (-x.price, x.timestamp))
        else:
            book.sort(key=lambda x: (x.price, x.timestamp))
            
    def get_l1_state(self):
        """Returns the current Best Bid and Offer (BBO)."""
        best_bid = self.bids[0].price if self.bids else None
        best_ask = self.asks[0].price if self.asks else None
        return {'bid': best_bid, 'ask': best_ask}
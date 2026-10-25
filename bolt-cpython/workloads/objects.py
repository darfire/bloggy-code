# an order book: classes, attribute access, method calls, dicts, small
# lists, exceptions now and then. hits the object model and call paths of
# the interpreter.
import sys
import time


class Order:
    __slots__ = ("oid", "side", "price", "qty")

    def __init__(self, oid, side, price, qty):
        self.oid = oid
        self.side = side
        self.price = price
        self.qty = qty


class Rejected(Exception):
    pass


class Book:
    def __init__(self):
        self.levels = {"buy": {}, "sell": {}}
        self.orders = {}
        self.traded = 0

    def add(self, order):
        if order.qty <= 0:
            raise Rejected(order.oid)
        self.orders[order.oid] = order
        self.levels[order.side].setdefault(order.price, []).append(order)
        self.match(order)

    def cancel(self, oid):
        order = self.orders.pop(oid, None)
        if order is None:
            return False
        level = self.levels[order.side].get(order.price)
        if level and order in level:
            level.remove(order)
            if not level:
                del self.levels[order.side][order.price]
        return True

    def match(self, order):
        other = "sell" if order.side == "buy" else "buy"
        book = self.levels[other]
        while order.qty > 0 and book:
            best = min(book) if other == "sell" else max(book)
            if (order.side == "buy" and best > order.price) or (order.side == "sell" and best < order.price):
                break
            resting = book[best][0]
            q = min(order.qty, resting.qty)
            order.qty -= q
            resting.qty -= q
            self.traded += q * best
            if resting.qty == 0:
                book[best].pop(0)
                self.orders.pop(resting.oid, None)
                if not book[best]:
                    del book[best]


def main(n):
    t0 = time.perf_counter()
    total = 0
    for round_ in range(n):
        book = Book()
        x = 4242 + round_
        rejected = 0
        for oid in range(30000):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
            if x % 10 == 0 and oid > 0:
                book.cancel(oid - 1 - x % 50)
                continue
            side = "buy" if x & 1 else "sell"
            try:
                book.add(Order(oid, side, 100 + (x >> 3) % 20, (x >> 8) % 50))
            except Rejected:
                rejected += 1
        total += book.traded + rejected + len(book.orders)
    t1 = time.perf_counter()
    print(f"workload=objects n={n} time={t1 - t0:.4f}s checksum={total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 10)

CC = gcc
CFLAGS = -Wall

# scalar: no vectorizer at all, one add per element - the pure latency story
sum_scalar: sum.c
	$(CC) $(CFLAGS) -O2 -fno-tree-vectorize -o sum_scalar sum.c

# what you get by default
sum_o2: sum.c
	$(CC) $(CFLAGS) -O2 -o sum_o2 sum.c

# compiler allowed to reorder float adds
sum_fastmath: sum.c
	$(CC) $(CFLAGS) -O3 -ffast-math -o sum_fastmath sum.c

# ...and told to split the accumulator when unrolling
sum_fastmath_unroll: sum.c
	$(CC) $(CFLAGS) -O3 -ffast-math -funroll-loops -fvariable-expansion-in-unroller -o sum_fastmath_unroll sum.c

all: sum_scalar sum_o2 sum_fastmath sum_fastmath_unroll

clean:
	rm -f sum_scalar sum_o2 sum_fastmath sum_fastmath_unroll

.PHONY: all clean

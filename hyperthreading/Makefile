CC = gcc
# no vectorizer, same as the scalar build in ../accumulators - otherwise
# gcc turns both loops into SSE and the chain/wide difference changes
CFLAGS = -O2 -fno-tree-vectorize -Wall -pthread

smt: smt.c
	$(CC) $(CFLAGS) -o smt smt.c

clean:
	rm -f smt

.PHONY: clean

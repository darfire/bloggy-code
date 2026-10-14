CC = gcc
CFLAGS = -O2 -Wall
NOPS = 96

ops.c ops.h: gen_ops.py
	python3 gen_ops.py $(NOPS)

pipeline_fused: pipeline.c ops.c ops.h
	$(CC) $(CFLAGS) -o pipeline_fused pipeline.c ops.c

pipeline_staged: pipeline.c ops.c ops.h
	$(CC) $(CFLAGS) -DSTAGED -o pipeline_staged pipeline.c ops.c

all: pipeline_fused pipeline_staged

clean:
	rm -f pipeline_fused pipeline_staged ops.c ops.h

.PHONY: all clean

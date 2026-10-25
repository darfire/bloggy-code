CC = gcc
CFLAGS = -O2 -Wall

hints_none: hints.c
	$(CC) $(CFLAGS) -o hints_none hints.c

hints_right: hints.c
	$(CC) $(CFLAGS) -DHINT_RIGHT -o hints_right hints.c

hints_wrong: hints.c
	$(CC) $(CFLAGS) -DHINT_WRONG -o hints_wrong hints.c

all: hints_none hints_right hints_wrong

clean:
	rm -f hints_none hints_right hints_wrong

.PHONY: all clean

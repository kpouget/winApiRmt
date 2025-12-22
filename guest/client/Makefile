# Makefile for Windows API Remoting userspace library and test client

CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c99
LDFLAGS = -ljson-c
INCLUDES = -I.

# Library
LIB_NAME = libwinapi.so
LIB_STATIC = libwinapi.a
LIB_SOURCES = libwinapi.c
LIB_OBJECTS = $(LIB_SOURCES:.c=.o)

# Test client
TEST_NAME = test_client
TEST_SOURCES = test_client.c
TEST_OBJECTS = $(TEST_SOURCES:.c=.o)

# Default target
all: $(LIB_NAME) $(LIB_STATIC) $(TEST_NAME)

# Shared library
$(LIB_NAME): $(LIB_OBJECTS)
	$(CC) -shared -fPIC -o $@ $^ $(LDFLAGS)

# Static library
$(LIB_STATIC): $(LIB_OBJECTS)
	ar rcs $@ $^

# Test client (statically linked for simplicity)
$(TEST_NAME): $(TEST_OBJECTS) $(LIB_STATIC)
	$(CC) -o $@ $^ $(LDFLAGS)

# Object files
%.o: %.c
	$(CC) $(CFLAGS) $(INCLUDES) -fPIC -c $< -o $@

# Install library and headers
install: $(LIB_NAME) $(LIB_STATIC)
	sudo install -d /usr/local/lib
	sudo install -d /usr/local/include
	sudo install -m 755 $(LIB_NAME) /usr/local/lib/
	sudo install -m 644 $(LIB_STATIC) /usr/local/lib/
	sudo install -m 644 libwinapi.h /usr/local/include/
	sudo ldconfig

# Uninstall
uninstall:
	sudo rm -f /usr/local/lib/$(LIB_NAME)
	sudo rm -f /usr/local/lib/$(LIB_STATIC)
	sudo rm -f /usr/local/include/libwinapi.h
	sudo ldconfig

# Clean build artifacts
clean:
	rm -f *.o $(LIB_NAME) $(LIB_STATIC) $(TEST_NAME)

# Run tests (assuming driver is loaded)
test: $(TEST_NAME)
	./$(TEST_NAME)

# Quick test - echo only
test-echo: $(TEST_NAME)
	./$(TEST_NAME) --echo-only

# Buffer test only
test-buffer: $(TEST_NAME)
	./$(TEST_NAME) --buffer-only

# Performance test only
test-perf: $(TEST_NAME)
	./$(TEST_NAME) --perf-only

.PHONY: all install uninstall clean test test-echo test-buffer test-perf
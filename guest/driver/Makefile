# Makefile for Windows API Remoting VMBus Client Driver

obj-m += winapi_client.o
winapi_client-objs := vmbus_client.o

# Kernel build directory - adjust as needed
# Check if ../kernel exists, otherwise use system default
KERNEL_DIR ?= $(shell if [ -d "../kernel" ]; then echo "../kernel"; else echo "/lib/modules/$(shell uname -r)/build"; fi)

# Build directory
BUILD_DIR := $(shell pwd)

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(BUILD_DIR) modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(BUILD_DIR) clean

install: all
	$(MAKE) -C $(KERNEL_DIR) M=$(BUILD_DIR) modules_install
	depmod -a

load:
	sudo insmod winapi_client.ko

unload:
	sudo rmmod winapi_client

reload: unload load

.PHONY: all clean install load unload reload
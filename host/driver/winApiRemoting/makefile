#
# Makefile for WinAPI Remoting Driver
# Use with: nmake -f makefile
#

TARGET=winApiRemoting.sys
OBJS=vmbus_privder.obj api_handlers.obj

# Compiler and linker
CC=cl.exe
LINK=link.exe

# Flags
CFLAGS=/c /W3 /Zi /Od /D"_WIN64" /D"WINNT=1" /D"_AMD64_" /D"AMD64" /Qspectre- /kernel /I"..\..\..\common"
LFLAGS=/DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry /MACHINE:X64

# Libraries
LIBS=ntoskrnl.lib hal.lib wmilib.lib vmbuskmcl.lib

# Build rules
all: $(TARGET)

$(TARGET): $(OBJS)
	$(LINK) $(LFLAGS) /OUT:$(TARGET) $(OBJS) $(LIBS)

vmbus_privder.obj: vmbus_privder.c
	$(CC) $(CFLAGS) vmbus_privder.c

api_handlers.obj: api_handlers.c
	$(CC) $(CFLAGS) api_handlers.c

clean:
	del *.obj *.sys *.pdb

.PHONY: all clean
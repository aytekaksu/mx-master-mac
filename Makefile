CC = xcrun clang
CFLAGS = -Wall -Wextra -Werror
FRAMEWORKS = -framework ApplicationServices -framework Carbon -framework IOKit

.PHONY: all test clean
all: build/mx4-device-helper

build:
	mkdir -p build

build/mx4-device-helper: helper/mx4-device-helper.m | build
	$(CC) $(CFLAGS) $(FRAMEWORKS) $< -o $@

build/test-mx4-device-helper: helper/test-mx4-device-helper.m helper/mx4-device-helper.m | build
	$(CC) $(CFLAGS) $(FRAMEWORKS) $< -o $@

test: build/test-mx4-device-helper
	./build/test-mx4-device-helper

clean:
	rm -rf build

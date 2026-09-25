CC = xcrun clang
CFLAGS = -Wall -Wextra -Werror -mmacosx-version-min=13.0 -arch arm64 -arch x86_64
FRAMEWORKS = -framework ApplicationServices -framework Carbon -framework IOKit

.PHONY: all test package clean
all: build/mx4-device-helper

build:
	mkdir -p build

build/mx4-device-helper: helper/mx4-device-helper.m | build
	$(CC) $(CFLAGS) $(FRAMEWORKS) $< -o $@
	codesign --force --sign - --timestamp=none $@
	codesign --verify --strict $@

build/test-mx4-device-helper: helper/test-mx4-device-helper.m helper/mx4-device-helper.m | build
	$(CC) $(CFLAGS) $(FRAMEWORKS) $< -o $@

test: build/test-mx4-device-helper
	./build/test-mx4-device-helper

package: all test
	sh scripts/package-release.sh

clean:
	rm -rf build

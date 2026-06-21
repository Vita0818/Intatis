# Intatis convenience targets.

.PHONY: app test build clean release install uninstall

# Where to link the `intatis` command. /usr/local/bin is on the default macOS
# PATH. For a no-sudo install use:  make install BINDIR=$(HOME)/.local/bin
BINDIR ?= /usr/local/bin

# Generate the Xcode project and open it (apps build/run from Xcode).
app:
	xcodegen generate
	open Intatis.xcodeproj

# Library/logic layer: build + run the XCTest suites (no Xcode needed).
test:
	swift test

build:
	swift build

clean:
	rm -rf .build Intatis.xcodeproj

# Optimized standalone binary at .build/release/intatis (no sudo).
release:
	swift build -c release

# Symlink that binary into your PATH so `intatis` works from any directory.
# Run `make release` first; afterwards every `make release` is instantly live
# (no reinstall). Use sudo if BINDIR isn't writable: `sudo make install`.
install:
	@test -x "$(CURDIR)/.build/release/intatis" || { echo "run 'make release' first"; exit 1; }
	@mkdir -p "$(BINDIR)"
	ln -sf "$(CURDIR)/.build/release/intatis" "$(BINDIR)/intatis"
	@echo "linked $(BINDIR)/intatis -> $(CURDIR)/.build/release/intatis"

uninstall:
	rm -f "$(BINDIR)/intatis"

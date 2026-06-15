# Intatis convenience targets.

.PHONY: app test build clean

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

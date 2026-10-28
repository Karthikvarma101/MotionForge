# MotionForge — convenience targets (everything is plain SwiftPM underneath).
.PHONY: all build app dmg run test bench sample clean

all: app

build:
	swift build -c release

app:
	scripts/bundle.sh release

# Drag-to-Applications disk image for releases -> build/MotionForge.dmg
dmg: app
	scripts/make-dmg.sh

run: app
	open build/MotionForge.app

test:
	swift build -c release --product mftests
	.build/release/mftests

bench:
	swift build -c release --product mfbench
	.build/release/mfbench --out benchmarks

# Renders the demo frames that show position / scale / opacity edits (see README).
sample:
	swift build -c release --product mfcli
	.build/release/mfcli demo Examples/demo
	.build/release/mfcli effects-demo Examples/effects
	.build/release/mfcli phase4-demo Examples/phase4

clean:
	rm -rf .build build

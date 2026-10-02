# Seat Gauge. Command Line Tools only, no Xcode.
#
# Swift Testing ships with the Command Line Tools and XCTest does not, so every
# swift run points at the tools' frameworks: -F on the framework directory and
# an rpath on that directory and on the usr/lib beside it.
SWIFT_FLAGS := -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# A clone builds `com.launchastro.seatgauge.dev`, so `make app` and `make run`
# keep their own Application Support folder and defaults domain and never
# share the installed app's. `make app SEATGAUGE_REAL_ID=1` opts
# into the real identifier, and any other value builds nothing. `make install`
# always builds with it.
ifeq ($(SEATGAUGE_REAL_ID),1)
APP_ID := com.launchastro.seatgauge
else ifeq ($(SEATGAUGE_REAL_ID),)
APP_ID := com.launchastro.seatgauge.dev
endif

.PHONY: build test check app install run clean

build:
	swift build $(SWIFT_FLAGS)

# Under a scratch home, serially, as scripts/check.sh runs it.
test:
	scripts/scratch-home.sh swift test --no-parallel $(SWIFT_FLAGS)

# The gate a pull request has to pass.
check:
	scripts/check.sh

app:
	@[ -n "$(APP_ID)" ] || { echo 'make app: SEATGAUGE_REAL_ID takes 1 or nothing, so nothing was built.' >&2; exit 2; }
	scripts/build-app.sh $(APP_ID)

# The release build and the bundle first, so the copy that lands in
# /Applications, and the seatgauge-cli linked into ~/.local/bin, are the ones
# this run just built.
install:
	scripts/build-app.sh
	scripts/install.sh

run: app
	open "dist/Seat Gauge.app"

clean:
	rm -rf .build dist

APP  := build/rayfast.app
BIN  := $(APP)/Contents/MacOS/rayfast
OPT  := -fobjc-arc -Os -Wall -Wno-deprecated-declarations -mmacosx-version-min=13.0
LIBS := -framework Cocoa -framework Carbon -framework QuartzCore -framework IOSurface

all: $(BIN)

$(BIN): core.m ui.m codex.m rf.h Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	clang $(OPT) core.m ui.m codex.m -o $@ $(LIBS) -Wl,-dead_strip
	strip -x $@
	codesign -s - -f $(APP) 2>/dev/null || true

run: all
	-pkill -x rayfast; open $(APP)

# copies to ~/Applications and starts it at login via a LaunchAgent
install: all
	-pkill -x rayfast
	rm -rf ~/Applications/rayfast.app && mkdir -p ~/Applications && cp -R $(APP) ~/Applications/
	sed "s#HOME#$$HOME#" local.rayfast.plist > ~/Library/LaunchAgents/local.rayfast.plist
	-launchctl bootout gui/$$(id -u)/local.rayfast 2>/dev/null
	launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/local.rayfast.plist

uninstall:
	-launchctl bootout gui/$$(id -u)/local.rayfast
	rm -f ~/Library/LaunchAgents/local.rayfast.plist
	rm -rf ~/Applications/rayfast.app

# a separately named copy for experiments, so tests never touch the real running instance
TEST := build/rayfast-test.app
test-app: all
	rm -rf $(TEST) && cp -R $(APP) $(TEST)
	mv $(TEST)/Contents/MacOS/rayfast $(TEST)/Contents/MacOS/rayfast-test
	plutil -replace CFBundleExecutable -string rayfast-test $(TEST)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string local.rayfast.test $(TEST)/Contents/Info.plist
	plutil -replace CFBundleName -string rayfast-test $(TEST)/Contents/Info.plist
	codesign -s - -f $(TEST) 2>/dev/null || true

# Dev loop next to the real rayfast (which keeps ⌘Space): `make dev` after every edit rebuilds and
# relaunches the test copy, opened with DEV_KEY. Its own config dir, so recording a hotkey there never
# rewrites the real config (the real instance would reload it and lose ⌘Space).
DEV_KEY ?= hyper+9
DEV_DIR := $(patsubst %/,%,$(or $(TMPDIR),/tmp))/rayfast-dev
dev:
	-@pkill -x rayfast-test
	@$(MAKE) --no-print-directory test-app
	@mkdir -p $(DEV_DIR)
	open -n --env RF_NOHOTKEY=1 --env RF_TOGGLE=$(DEV_KEY) --env RF_CONFIG_DIR=$(DEV_DIR) --stderr $(DEV_DIR)/err.log $(TEST)
	@echo "rayfast-test is running: open it with $(DEV_KEY) (hyper = ctrl+opt+shift+cmd). Logs: $(DEV_DIR)/err.log. Stop: make dev-stop"

dev-stop:
	-@pkill -x rayfast-test

# Puts the committed code in place as the real rayfast, through the nix config that runs it.
NIXCFG ?= $(HOME)/workdir/infra/nixpkgs
# The darwinConfigurations entry to switch to: the machine's hostname (sykar-macbook) has none of its own.
NIXHOST ?= macbook
ship: dev-stop
	@git diff --quiet HEAD || { echo "uncommitted changes: commit them first, ship only takes commits"; exit 1; }
	git push origin HEAD
	nix flake update rayfast --flake $(NIXCFG)
	sudo darwin-rebuild switch --flake $(NIXCFG)#$(NIXHOST)

clean:
	rm -rf build
.PHONY: all run install uninstall test-app dev dev-stop ship clean

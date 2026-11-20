APP := build/API Proxy Widget.app
INSTALLED := /Applications/API Proxy Widget.app

.PHONY: build test app install uninstall demo-hub

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

# Builds the app, replaces the copy in /Applications and starts it.
install: app
	-pkill -x APIProxyWidget
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

uninstall:
	-pkill -x APIProxyWidget
	rm -rf "$(INSTALLED)"

# A stand-in hub with made-up accounts: http://127.0.0.1:8399, management key "demo".
demo-hub:
	python3 scripts/demo-hub.py

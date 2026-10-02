APP := ClickFocus.app
INSTALL_DIR := $(HOME)/Applications
INSTALLED := $(INSTALL_DIR)/$(APP)
AGENT := $(HOME)/Library/LaunchAgents/com.tomk.ClickFocus.plist
# Signing with a fixed certificate keeps the Accessibility permission across
# rebuilds. Without the certificate in the keychain, "-" signs ad hoc.
CERT := ClickFocus Code Signing
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning | grep -q '"$(CERT)"' && echo '$(CERT)' || echo -)

.PHONY: all run install uninstall clean

all: $(APP)

ClickFocus: ClickFocus.swift
	swiftc -O -o $@ $<

$(APP): ClickFocus Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	cp Info.plist $@/Contents/
	cp ClickFocus $@/Contents/MacOS/
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.tomk.ClickFocus $@

run: $(APP)
	$(APP)/Contents/MacOS/ClickFocus --verbose

# Opening the installed app makes it a login item. Earlier versions installed
# a LaunchAgent instead, which is removed.
install: $(APP)
	-pkill -f '$(INSTALLED)/Contents/MacOS/ClickFocus'
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	rm -f $(AGENT)
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED)
	cp -R $(APP) $(INSTALL_DIR)/
	open $(INSTALLED)

uninstall:
	-$(INSTALLED)/Contents/MacOS/ClickFocus --login-item off
	-pkill -f '$(INSTALLED)/Contents/MacOS/ClickFocus'
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	rm -f $(AGENT)
	rm -rf $(INSTALLED)

clean:
	rm -rf ClickFocus $(APP)

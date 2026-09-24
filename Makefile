APP := ClickFocus.app
INSTALL_DIR := $(HOME)/Applications
AGENT := $(HOME)/Library/LaunchAgents/com.tomk.ClickFocus.plist
LOG := $(HOME)/Library/Logs/ClickFocus.log
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

install: $(APP)
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	mkdir -p $(INSTALL_DIR) $(dir $(AGENT))
	rm -rf $(INSTALL_DIR)/$(APP)
	cp -R $(APP) $(INSTALL_DIR)/
	sed -e 's|__APP__|$(INSTALL_DIR)/$(APP)|' -e 's|__LOG__|$(LOG)|' com.tomk.ClickFocus.plist > $(AGENT)
	launchctl bootstrap gui/$$(id -u) $(AGENT)

uninstall:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)
	rm -rf $(INSTALL_DIR)/$(APP)

clean:
	rm -rf ClickFocus $(APP)

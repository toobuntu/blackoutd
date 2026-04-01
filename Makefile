BINARY         = blackoutd
SRCDIR         = src
BUILDDIR       = build
BUNDLE_ID      = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" $(SRCDIR)/Info.plist)
AGENT_LABEL    = $(BUNDLE_ID)
INSTALL_BIN    = /usr/local/bin/$(BINARY)
AGENT_DIR      = $(HOME)/Library/LaunchAgents
AGENT_PLIST    = $(BUNDLE_ID).plist
AGENT_DST      = $(AGENT_DIR)/$(AGENT_PLIST)
AGENT_TEMPLATE = blackoutd.plist.template
UID            = $(shell id -u)

SRCS   = $(SRCDIR)/main.m $(SRCDIR)/AppDelegate.m $(SRCDIR)/DisplayController.m
TARGET = $(BUILDDIR)/$(BINARY)
CC     = clang
CFLAGS = \
    -fobjc-arc \
    -Wall \
    -Wextra \
    -DBD_BUNDLE_ID='"$(BUNDLE_ID)"' \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework IOKit \
    -sectcreate __TEXT __info_plist $(SRCDIR)/Info.plist

.PHONY: all clean install postinstall reinstall uninstall load unload

all: $(TARGET)

$(TARGET): $(SRCS) $(SRCDIR)/AppDelegate.h $(SRCDIR)/DisplayController.h $(SRCDIR)/Info.plist
	mkdir -p $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $(SRCS)
	codesign --sign - --force $@

clean:
	rm -rf $(BUILDDIR)

install: $(TARGET) postinstall
	sudo install -d /usr/local/bin
	sudo install -m 755 $(TARGET) $(INSTALL_BIN)
	launchctl bootstrap gui/$(UID) $(AGENT_DST)

# Expand {{BUNDLE_ID}} and {{HOME}} in plist template and install to LaunchAgents.
# Creates ~/Library/Logs if absent.
postinstall:
	install -d $(AGENT_DIR)
	install -d $(HOME)/Library/Logs
	sed -e 's|{{BUNDLE_ID}}|$(BUNDLE_ID)|g' \
	    -e 's|{{HOME}}|$(HOME)|g' \
	    $(AGENT_TEMPLATE) > $(AGENT_DST)
	chmod 644 $(AGENT_DST)

# Reinstall binary and plist, then restart agent.
#   make clean; make; make reinstall
reinstall: $(TARGET) postinstall
	-launchctl bootout gui/$(UID)/$(AGENT_LABEL)
	sudo install -m 755 $(TARGET) $(INSTALL_BIN)
	launchctl bootstrap gui/$(UID) $(AGENT_DST)

# Remove agent and all installed files.
uninstall: unload
	sudo rm -f $(INSTALL_BIN)
	rm -f $(AGENT_DST)

# Bootstrap / bootout without reinstalling.
load:
	launchctl bootstrap gui/$(UID) $(AGENT_DST)

unload:
	-launchctl bootout gui/$(UID)/$(AGENT_LABEL) || true

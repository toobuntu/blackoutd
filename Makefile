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

RESOURCES_SRC  = $(SRCDIR)/Resources
BUNDLE_NAME    = $(BINARY).bundle
BUILD_BUNDLE   = $(BUILDDIR)/$(BUNDLE_NAME)/Contents/Resources
SHARE_BUNDLE   = /usr/local/share/$(BUNDLE_NAME)

SRCS   = $(SRCDIR)/main.m $(SRCDIR)/AppDelegate.m $(SRCDIR)/DisplayController.m
TARGET = $(BUILDDIR)/$(BINARY)
CC     = clang
CFLAGS = \
    -fobjc-arc \
    -Wall \
    -Wextra \
    -Os \
    -DBD_BUNDLE_ID='"$(BUNDLE_ID)"' \
    -DBD_RESOURCES_BUNDLE='"$(SHARE_BUNDLE)"' \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework IOKit \
    -sectcreate __TEXT __info_plist $(SRCDIR)/Info.plist

.PHONY: all clean install postinstall reinstall uninstall load unload print-bundle-id

all: $(TARGET)

$(TARGET): $(SRCS) $(SRCDIR)/AppDelegate.h $(SRCDIR)/DisplayController.h $(SRCDIR)/Info.plist
	mkdir -p $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $(SRCS)
	strip $@
	codesign --sign - --force $@
	mkdir -p $(BUILD_BUNDLE)
	cp -R $(RESOURCES_SRC)/*.lproj $(BUILD_BUNDLE)/

clean:
	rm -rf $(BUILDDIR)

install: $(TARGET) postinstall
	sudo install -d /usr/local/bin
	sudo install -m 755 $(TARGET) $(INSTALL_BIN)
	sudo install -d $(SHARE_BUNDLE)/Contents/Resources
	sudo cp -R $(BUILD_BUNDLE)/*.lproj $(SHARE_BUNDLE)/Contents/Resources/
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
	sudo install -d $(SHARE_BUNDLE)/Contents/Resources
	sudo cp -R $(BUILD_BUNDLE)/*.lproj $(SHARE_BUNDLE)/Contents/Resources/
	launchctl bootstrap gui/$(UID) $(AGENT_DST)

# Remove agent and all installed files.
uninstall: unload
	sudo rm -f $(INSTALL_BIN)
	sudo rm -rf $(SHARE_BUNDLE)
	rm -f $(AGENT_DST)

# Bootstrap / bootout without reinstalling.
load:
	launchctl bootstrap gui/$(UID) $(AGENT_DST)

unload:
	-launchctl bootout gui/$(UID)/$(AGENT_LABEL)

print-bundle-id:
	@echo $(BUNDLE_ID)

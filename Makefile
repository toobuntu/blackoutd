BINARY         = blackoutd
SRCDIR         = src
BUILDDIR       = build
BUNDLE_ID      = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" $(SRCDIR)/Info.plist)
VERSION        = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $(SRCDIR)/Info.plist)
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

.PHONY: all clean install postinstall dev uninstall load unload print-bundle-id release

all: $(TARGET)

$(TARGET): $(SRCS) $(SRCDIR)/AppDelegate.h $(SRCDIR)/DisplayController.h $(SRCDIR)/Info.plist
	mkdir -p $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $(SRCS)
	strip $@
	codesign --sign - --force $@
	mkdir -p $(BUILD_BUNDLE)
	cp $(RESOURCES_SRC)/Info.plist $(BUILDDIR)/$(BUNDLE_NAME)/Contents/
	cp -R $(RESOURCES_SRC)/*.lproj $(BUILD_BUNDLE)/

clean:
	rm -rf $(BUILDDIR)

install: $(TARGET) postinstall
	sudo install -d /usr/local/bin
	sudo install -m 755 $(TARGET) $(INSTALL_BIN)
	sudo install -d $(SHARE_BUNDLE)/Contents/Resources
	sudo cp $(BUILDDIR)/$(BUNDLE_NAME)/Contents/Info.plist $(SHARE_BUNDLE)/Contents/
	sudo cp -R $(BUILD_BUNDLE)/*.lproj $(SHARE_BUNDLE)/Contents/Resources/
	launchctl bootstrap gui/$(UID) $(AGENT_DST)

# Expand {{BUNDLE_ID}}, {{HOME}}, and {{INSTALL_BIN}} in plist template
# and install to LaunchAgents. Creates ~/Library/Logs if absent.
postinstall:
	install -d $(AGENT_DIR)
	install -d $(HOME)/Library/Logs
	sed -e 's|{{BUNDLE_ID}}|$(BUNDLE_ID)|g' \
	    -e 's|{{HOME}}|$(HOME)|g' \
	    -e 's|{{INSTALL_BIN}}|$(INSTALL_BIN)|g' \
	    $(AGENT_TEMPLATE) > $(AGENT_DST)
	chmod 644 $(AGENT_DST)

# Dev cycle: bootout the running agent, regenerate the plist pointing to
# the build/ binary, and bootstrap the new plist. No sudo, nothing copied
# into /usr/local. Intended for tight iteration during development.
# Use 'make install' for a full production install to /usr/local/bin.
dev: $(TARGET)
	-launchctl bootout gui/$(UID)/$(AGENT_LABEL)
	install -d $(AGENT_DIR)
	install -d $(HOME)/Library/Logs
	sed -e 's|{{BUNDLE_ID}}|$(BUNDLE_ID)|g' \
	    -e 's|{{HOME}}|$(HOME)|g' \
	    -e 's|{{INSTALL_BIN}}|$(abspath $(TARGET))|g' \
	    $(AGENT_TEMPLATE) > $(AGENT_DST)
	chmod 644 $(AGENT_DST)
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

# Verify a clean working tree, build the binary, and create an annotated
# git tag. Does NOT push the tag, sign artifacts, or produce a packaged
# release; those are manual follow-up steps printed at the end.
# Tag convention: v<VERSION> (e.g., v0.2.0)
release: $(TARGET)
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: uncommitted changes in working tree" >&2; \
		echo "Commit or stash changes before creating a release." >&2; \
		exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "error: tag v$(VERSION) already exists" >&2; \
		exit 1; \
	fi
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "Created tag v$(VERSION)"
	@echo "Binary: $(TARGET)"
	@echo "Version: $(VERSION)"
	@echo ""
	@echo "To push the tag: git push origin v$(VERSION)"

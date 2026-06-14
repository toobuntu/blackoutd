# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

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
LOG_FILE       = $(HOME)/Library/Logs/$(BINARY).log
LOG_KEEP       = 5
GIT_DESCRIBE   := $(shell git -C $(CURDIR) describe --tags --always --dirty 2>/dev/null || echo unknown)
BUILD_TIME     := $(shell date -u -Iseconds)

RESOURCES_SRC  = $(SRCDIR)/Resources
BUNDLE_NAME    = $(BINARY).bundle
BUILD_BUNDLE   = $(BUILDDIR)/$(BUNDLE_NAME)/Contents/Resources
SHARE_BUNDLE   = /usr/local/share/$(BUNDLE_NAME)

SRCS   = $(SRCDIR)/main.m $(SRCDIR)/AppDelegate.m $(SRCDIR)/DisplayController.m
HDRS   = $(SRCDIR)/AppDelegate.h $(SRCDIR)/DisplayController.h
TARGET = $(BUILDDIR)/$(BINARY)
GIT_STAMP = $(BUILDDIR)/.git-describe
CC     = clang
# Lint tools. clang-format ships with Xcode (xcrun); clang-tidy is not in the
# Xcode toolchain, so run Homebrew llvm's via `brew exec` (no PATH linking).
# Override either variable to point at a specific binary.
CLANG_FORMAT ?= xcrun clang-format
CLANG_TIDY   ?= brew exec clang-tidy
# Defines and frameworks, shared by the build and `make tidy` so static
# analysis sees exactly what the compiler does.
DEFINES = \
    -DBD_BUNDLE_ID='"$(BUNDLE_ID)"' \
    -DBD_RESOURCES_BUNDLE='"$(SHARE_BUNDLE)"' \
    -DBD_BUILD_GIT='"$(GIT_DESCRIBE)"' \
    -DBD_BUILD_TIME='"$(BUILD_TIME)"'
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework IOKit
CFLAGS = \
    -fobjc-arc \
    -Wall \
    -Wextra \
    -Os \
    $(DEFINES) \
    $(FRAMEWORKS) \
    -sectcreate __TEXT __info_plist $(SRCDIR)/Info.plist

# Shared clang-format file/style args (`format` writes with -i; `lint`
# checks with --dry-run).
CLANG_FORMAT_ARGS = --style=file --Werror $(SRCS) $(HDRS)
# Full clang-tidy invocation, shared by `tidy` and `lint`. Flags after --
# mirror the build via $(DEFINES)/$(FRAMEWORKS).
CLANG_TIDY_RUN = $(CLANG_TIDY) --quiet $(SRCS) -- -fobjc-arc $(DEFINES) $(FRAMEWORKS) -I$(SRCDIR)
# $(call require,command,error-message): abort with the message if the
# tool is missing. --version probes PATH binaries and the xcrun/brew-exec
# wrappers alike, which `command -v` cannot resolve.
require = @$(1) --version >/dev/null 2>&1 || { printf 'error: %s\n' '$(2)' >&2; exit 1; }

.PHONY: all clean install postinstall dev reinstall uninstall load unload \
        print-bundle-id preflight release format tidy lint test check FORCE

all: $(TARGET)

$(TARGET): $(SRCS) $(HDRS) $(SRCDIR)/Info.plist $(GIT_STAMP)
	mkdir -p $(BUILDDIR)
	$(CC) $(CFLAGS) -o $@ $(SRCS)
	strip $@
	codesign --sign - --force $@
	mkdir -p $(BUILD_BUNDLE)
	cp $(RESOURCES_SRC)/Info.plist $(BUILDDIR)/$(BUNDLE_NAME)/Contents/
	cp -R $(RESOURCES_SRC)/*.lproj $(BUILD_BUNDLE)/

# Rewrite the git-describe stamp only when it changes, so $(TARGET) relinks
# (re-embedding BD_BUILD_GIT) after a commit even when no source file changed,
# without defeating incremental rebuilds otherwise.
$(GIT_STAMP): FORCE
	@mkdir -p $(BUILDDIR)
	@printf '%s' '$(GIT_DESCRIBE)' | cmp -s - $@ 2>/dev/null || printf '%s' '$(GIT_DESCRIBE)' >$@

FORCE:

clean:
	rm -rf $(BUILDDIR)

# First-time install. MUST be run as the logged-in user, not under sudo.
# This recipe invokes sudo internally only for the privileged writes to
# /usr/local. $(HOME) and $(UID) must reflect the real user so the plist
# lands in ~/Library/LaunchAgents and launchctl targets gui/$UID, not
# gui/0. Running 'sudo make install' would set $(HOME)=/var/root and
# $(UID)=0 and break both.
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
	@scripts/rotate-log.sh "$(LOG_FILE)" $(LOG_KEEP)
	install -d $(AGENT_DIR)
	install -d $(HOME)/Library/Logs
	sed -e 's|{{BUNDLE_ID}}|$(BUNDLE_ID)|g' \
	    -e 's|{{HOME}}|$(HOME)|g' \
	    -e 's|{{INSTALL_BIN}}|$(abspath $(TARGET))|g' \
	    $(AGENT_TEMPLATE) > $(AGENT_DST)
	chmod 644 $(AGENT_DST)
	launchctl bootstrap gui/$(UID) $(AGENT_DST)
	@printf '%s\n' 'PATH `blackoutd` is now stale; use `./build/blackoutd` or `make reinstall`.'

# Upgrade flow for end users: bootout the running agent (if any), install
# the new binary and resources to /usr/local, then bootstrap the new
# plist. Works correctly when the agent is already loaded (where plain
# install would fail with launchctl bootstrap exit 5).
# MUST be run as the logged-in user, not under sudo (see install above).
reinstall: $(TARGET) postinstall
	-launchctl bootout gui/$(UID)/$(AGENT_LABEL)
	@scripts/rotate-log.sh "$(LOG_FILE)" $(LOG_KEEP)
	sudo install -d /usr/local/bin
	sudo install -m 755 $(TARGET) $(INSTALL_BIN)
	sudo install -d $(SHARE_BUNDLE)/Contents/Resources
	sudo cp $(BUILDDIR)/$(BUNDLE_NAME)/Contents/Info.plist $(SHARE_BUNDLE)/Contents/
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

# Ad-hoc lint entry points. The .githooks/pre-commit hook runs the same tools
# in check mode on staged files, and CI runs them repo-wide; these are for
# running them by hand. clang-format reads .clang-format; clang-tidy reads
# .clang-tidy.

# Reformat sources in place. --style=file is explicit to match the
# pre-commit and CI invocations regardless of clang-format's default.
format:
	$(CLANG_FORMAT) -i $(CLANG_FORMAT_ARGS)

# Static analysis. --quiet drops the "N warnings generated / Suppressed N"
# accounting (HeaderFilterRegex in .clang-tidy already scopes diagnostics to
# src/). Flags after -- mirror the build via $(DEFINES)/$(FRAMEWORKS).
tidy:
	$(call require,$(CLANG_TIDY),clang-tidy unavailable (brew install llvm))
	$(CLANG_TIDY_RUN)

# Run RSpec under Homebrew's portable Ruby — the same Ruby `brew ruby`
# uses and that CI runs via Homebrew/actions/setup-ruby. Run
# `bundle install` under that Ruby once first (see CONTRIBUTING.md).
test:
	@pr_bin="$$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin"; \
	env -P"$$pr_bin:$$PATH" bundle exec rspec

# Read-only repo-wide checks — the local equivalent of CI's whole-tree
# gates (the pre-commit hook only sees staged files and uses
# `reuse lint-file`). Modifies nothing; requires the full toolchain.
lint:
	$(call require,$(CLANG_FORMAT),clang-format unavailable (xcode-select --install && xcode-select --switch /Library/Developer/CommandLineTools))
	$(call require,$(CLANG_TIDY),clang-tidy unavailable (brew install llvm))
	$(call require,reuse,reuse not installed (brew install reuse))
	$(call require,adrs,adrs not installed (brew install adrs))
	scripts/lint-perms.sh --tracked
	$(CLANG_FORMAT) --dry-run $(CLANG_FORMAT_ARGS)
	$(CLANG_TIDY_RUN)
	reuse lint
	adrs doctor

# Full local gate: read-only checks plus the behavioral test suite
# (CI parity). The one command to run before pushing.
check: lint test

# Verify a clean working tree before doing release work. Run as a
# prerequisite so the build does not happen if the gate fails.
preflight:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: uncommitted changes in working tree" >&2; \
		echo "Commit or stash changes before creating a release." >&2; \
		exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "error: tag v$(VERSION) already exists" >&2; \
		exit 1; \
	fi

# Verify a clean working tree, build the binary, and create a signed
# annotated git tag. --sign enforces signing here rather than relying on a
# global tag.gpgSign; with gpg.format=ssh it signs with the SSH key. Does
# NOT push the tag or produce a packaged release; those are manual
# follow-up steps printed at the end. Tag convention: v<VERSION>.
release: preflight $(TARGET)
	git tag --sign --message="Release v$(VERSION)" "v$(VERSION)"
	@echo "Created tag v$(VERSION)"
	@echo "Binary: $(TARGET)"
	@echo "Version: $(VERSION)"
	@echo ""
	@echo "To push the tag: git push origin v$(VERSION)"

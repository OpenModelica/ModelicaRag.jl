APP_NAME := modelicarag
PROJECT_DIR := $(CURDIR)
BUILD_DIR := $(PROJECT_DIR)/build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME)-app
APP_LAUNCHER := $(BUILD_DIR)/$(APP_NAME)

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR := $(DESTDIR)$(PREFIX)/bin
LIBDIR := $(DESTDIR)$(PREFIX)/lib/$(APP_NAME)
INSTALLED_WRAPPER := $(BINDIR)/$(APP_NAME)
INSTALLED_BINARY := $(LIBDIR)/bin/$(APP_NAME)

.PHONY: all build install uninstall clean

all: build

build:
	julia --project=. scripts/build_modelicarag.jl

install: build
	@test -n "$(PREFIX)" || { echo "PREFIX must not be empty"; exit 1; }
	install -d "$(BINDIR)"
	rm -rf "$(LIBDIR)"
	install -d "$(LIBDIR)"
	cp -a "$(APP_BUNDLE)/." "$(LIBDIR)/"
	printf '%s\n' '#!/usr/bin/env bash' \
		'set -euo pipefail' \
		'exec "$(PREFIX)/lib/$(APP_NAME)/bin/$(APP_NAME)" "$$@"' > "$(INSTALLED_WRAPPER)"
	chmod 755 "$(INSTALLED_WRAPPER)"

uninstall:
	@test -n "$(PREFIX)" || { echo "PREFIX must not be empty"; exit 1; }
	rm -f "$(INSTALLED_WRAPPER)"
	rm -rf "$(LIBDIR)"

clean:
	rm -rf "$(BUILD_DIR)"

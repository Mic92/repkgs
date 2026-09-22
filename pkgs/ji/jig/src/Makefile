# Local development build of jig and its unit tests (`nix-shell ../shell.nix` here, then
# `make test`), outputs in /tmp, outside the tree. The set's package builds this Makefile (package.nix,
# source = ./src) with BUILD=$(NIX_BUILD_TOP)/build on the command line, so outputs land in
# (ctx).build and the source tree stays pristine like jigd's; the bootstrap compiles src/
# directly instead (bootstrap.nu).
CXX      ?= clang++
# OPT on the command line (the package builds with OPT=-O3); ?= so a hand-run `make`
# keeps -O0 for fast iteration and the derivation never edits this file to tune flags
OPT      ?= -O0
CXXFLAGS ?= -std=c++26 $(OPT) -g -Wall -Wextra -Werror -Wno-unused-command-line-argument \
            -U_LIBCPP_HARDENING_MODE -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -fno-exceptions \
            -DJIG_STORE_DIR='"$(NIX_STORE_DIR)"'
NIX_STORE_DIR ?= /nix/store
LDLIBS   ?= -lblake3 -lzstd
# Outputs live outside the tree, locally and under Nix: /tmp keeps `source = ./src` bare,
# stray binaries can never be snapshotted into a derivation. Per user and checkout, so
# concurrent builds don't share a dir. The derivation passes BUILD=(ctx).build instead.
BUILD    ?= $(or $(TMPDIR),/tmp)/jig-$(or $(USER),anon)-$(notdir $(abspath $(CURDIR)/..))
PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin

srcs   := $(wildcard *.cc)
objs   := $(patsubst %.cc,$(BUILD)/%.o,$(srcs))
common := $(filter-out $(BUILD)/main.o $(BUILD)/jig_test.o,$(objs))

.PHONY: all test install clean
all: $(BUILD)/jig $(BUILD)/jig_test
test: $(BUILD)/jig_test
	$<
install: $(BUILD)/jig
	mkdir -p $(DESTDIR)$(BINDIR)
	cp $(BUILD)/jig $(DESTDIR)$(BINDIR)/jig

$(BUILD)/jig: $(BUILD)/main.o $(common)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDLIBS)
$(BUILD)/jig_test: $(BUILD)/jig_test.o $(common)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDLIBS)
$(BUILD)/%.o: %.cc $(wildcard *.h) | $(BUILD)
	$(CXX) $(CXXFLAGS) -c -o $@ $<
$(BUILD):
	mkdir -p $@
clean:
	rm -rf $(BUILD)

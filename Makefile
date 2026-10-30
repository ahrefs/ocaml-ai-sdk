.DEFAULT_GOAL := build

.PHONY: build
build:
	dune build

.PHONY: fmt
fmt:
	dune fmt --auto-promote

.PHONY: test
test:
	dune runtest

.PHONY: promote
promote:
	dune build @runtest --auto-promote

.PHONY: watch
watch:
	dune build -w

.PHONY: clean
clean:
	dune clean

.PHONY: top
top:
	dune utop .

# The codemode VM is a Rust program, built with cargo from sources vendored out of Cargo.lock into
# lib/codemode-sandbox/vendor (not in git), then built offline. Dune does not build it: run these
# targets (needs a Rust toolchain, 1.87 or later).
CODEMODE_DIR := lib/codemode-sandbox
CODEMODE_TARGET_DIR := $(CURDIR)/_build/codemode-sandbox
CODEMODE_BINARY := ai-sdk-quickjs-runner
CODEMODE_CARGO_FLAGS := --config vendor/config.toml --frozen
PREFIX ?= $(or $(OPAM_SWITCH_PREFIX),/usr/local)

# Downloads exactly the crates (and checksums) pinned by Cargo.lock; rerun when Cargo.lock changes.
# `cargo vendor` prints the source-replacement config, which the build targets pass to cargo.
.PHONY: rust-vendor
rust-vendor:
	cd $(CODEMODE_DIR) && rm -rf vendor && cargo vendor --locked vendor > vendor.config.tmp \
	  && mv vendor.config.tmp vendor/config.toml

$(CODEMODE_DIR)/vendor/config.toml: $(CODEMODE_DIR)/Cargo.lock
	$(MAKE) rust-vendor

.PHONY: build-codemode-binary
build-codemode-binary: $(CODEMODE_DIR)/vendor/config.toml
	cd $(CODEMODE_DIR) && CARGO_TARGET_DIR=$(CODEMODE_TARGET_DIR) cargo build --release $(CODEMODE_CARGO_FLAGS)

.PHONY: test-codemode-binary
test-codemode-binary: $(CODEMODE_DIR)/vendor/config.toml
	cd $(CODEMODE_DIR) && CARGO_TARGET_DIR=$(CODEMODE_TARGET_DIR) cargo test --release $(CODEMODE_CARGO_FLAGS)

# Runs pi-codemode's sandbox tests against the binary (needs node and pnpm).
.PHONY: conformance-codemode-binary
conformance-codemode-binary: build-codemode-binary
	cd $(CODEMODE_DIR)/conformance && pnpm install --frozen-lockfile && pnpm check-prelude && \
	  RUNNER=$(CODEMODE_TARGET_DIR)/release/$(CODEMODE_BINARY) pnpm test

.PHONY: install-codemode-binary
install-codemode-binary: build-codemode-binary
	install -D -m 755 $(CODEMODE_TARGET_DIR)/release/$(CODEMODE_BINARY) $(DESTDIR)$(PREFIX)/bin/$(CODEMODE_BINARY)

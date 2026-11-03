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

# The tiny-js sandbox VM is a Rust program, built with cargo from sources vendored out of Cargo.lock into
# lib/tiny-js-sandbox/vendor (not in git), then built offline. Dune does not build it: run these
# targets (needs a Rust toolchain, 1.87 or later).
TINY_JS_DIR := lib/tiny-js-sandbox
TINY_JS_TARGET_DIR := $(CURDIR)/_build/tiny-js-sandbox
TINY_JS_BINARY := tiny-js-sandbox
TINY_JS_CARGO_FLAGS := --config vendor/config.toml --frozen
PREFIX ?= $(or $(OPAM_SWITCH_PREFIX),/usr/local)

# Downloads exactly the crates (and checksums) pinned by Cargo.lock; rerun when Cargo.lock changes.
# `cargo vendor` prints the source-replacement config, which the build targets pass to cargo.
.PHONY: rust-vendor
rust-vendor:
	cd $(TINY_JS_DIR) && rm -rf vendor && cargo vendor --locked vendor > vendor.config.tmp \
	  && mv vendor.config.tmp vendor/config.toml

$(TINY_JS_DIR)/vendor/config.toml: $(TINY_JS_DIR)/Cargo.lock
	$(MAKE) rust-vendor

.PHONY: build-tiny-js-binary
build-tiny-js-binary: $(TINY_JS_DIR)/vendor/config.toml
	cd $(TINY_JS_DIR) && CARGO_TARGET_DIR=$(TINY_JS_TARGET_DIR) cargo build --release $(TINY_JS_CARGO_FLAGS)
	@# Also reachable at the conventional cargo location (git-ignored), where the OCaml tests look.
	mkdir -p $(TINY_JS_DIR)/target/release
	ln -sf $(TINY_JS_TARGET_DIR)/release/$(TINY_JS_BINARY) $(TINY_JS_DIR)/target/release/$(TINY_JS_BINARY)

.PHONY: test-tiny-js-binary
test-tiny-js-binary: $(TINY_JS_DIR)/vendor/config.toml
	cd $(TINY_JS_DIR) && CARGO_TARGET_DIR=$(TINY_JS_TARGET_DIR) cargo test --release $(TINY_JS_CARGO_FLAGS)

install-tiny-js-binary:
	cargo install --path=$(TINY_JS_DIR) --locked

# Builds the runner binary, then runs the OCaml client tests (lib/tiny_js) against it, in addition to the
# scripted-runner tests. Without the binary the integration tests skip themselves.
.PHONY: test-tiny-js
test-tiny-js: build-tiny-js-binary
	TINY_JS_REQUIRE_BINARY=1 TINY_JS_SANDBOX_BIN=$(TINY_JS_TARGET_DIR)/release/$(TINY_JS_BINARY) dune test --force test/tiny_js

# Runs pi-codemode's sandbox tests against the binary (needs node and pnpm).
.PHONY: conformance-tiny-js-binary
conformance-tiny-js-binary: build-tiny-js-binary
	cd $(TINY_JS_DIR)/conformance && pnpm install --frozen-lockfile && pnpm check-prelude && \
	  RUNNER=$(TINY_JS_TARGET_DIR)/release/$(TINY_JS_BINARY) pnpm test

.PHONY: install-tiny-js-binary
install-tiny-js-binary: build-tiny-js-binary
	install -D -m 755 $(TINY_JS_TARGET_DIR)/release/$(TINY_JS_BINARY) $(DESTDIR)$(PREFIX)/bin/$(TINY_JS_BINARY)

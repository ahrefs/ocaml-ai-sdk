.PHONY: build clean test examples tool

build:
	dune build

clean:
	dune clean

test:
	dune runtest

format:
	dune build @fmt --auto-promote

examples: build
	@echo "Run examples with:"
	@echo "  dune exec examples/one_shot.exe"
	@echo "  dune exec examples/multi_turn.exe"
	@echo "  dune exec examples/session_resume.exe"

tool: build
	dune exec tool/main.exe -- $(ARGS)

(lang dune 3.21)

(using melange 0.1)

(using directory-targets 0.1)

(name ocaml-ai-sdk)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (format
   (progn
    (ignore-stdout (cat %{project_root}/.ocamlformat))
    (run ocamlformat-mlx
     --disable-conf-files --enable-outside-detected-project
     --profile=default --break-cases=toplevel --no-break-infix-before-func
     --break-infix=fit-or-vertical --cases-exp-indent=2 --doc-comments=before
     --exp-grouping=preserve --leading-nested-match-parens --let-and=sparse
     -m 120 --max-indent=2 --module-item-spacing=preserve --nested-match=align
     --parens-ite --parens-tuple=multi-line-only --no-parse-docstrings
     --type-decl=sparse %{input-file})))
  (preprocess
   (run mlx-pp %{input-file}))))

(generate_opam_files true)

(source
 (github username/reponame))

(authors "Author Name <author@example.com>")

(maintainers "Maintainer Name <maintainer@example.com>")

(license LICENSE)

(documentation https://url/to/documentation)

(package
 (name ocaml-ai-sdk)
 (synopsis "OCaml AI SDK - Provider abstraction for AI models")
 (description "Type-safe, provider-agnostic AI model abstraction inspired by Vercel AI SDK")
 (depends
  (ocaml (>= 4.14))
  (lwt (>= 5.9))
  (yojson (>= 2.2))
  (jsonschema (>= 0.1))
  (melange-json-native (>= 2.0))
  (cohttp-lwt-unix (>= 5.3))
  (lwt_ssl (>= 1.2))
  (devkit (>= 1.20240429))
  (alcotest :with-test)))

(package
 (name claude_agent_sdk)
 (allow_empty)
 (synopsis "port of the official claude-agent-sdk, in OCaml")
 (description "Claude Agent SDK for OCaml")
 (depends ocaml)
 (tags
  ("claude" "agent" "sdk" "ocaml")))

(package
 (name ai-sdk-react)
 (allow_empty)
 (synopsis "Melange bindings for @ai-sdk/react")
 (description "Type-safe OCaml/Melange bindings for Vercel AI SDK React hooks (useChat, useCompletion)")
 (depends
  (ocaml (>= 4.14))
  (melange (>= 4.0.0))))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html

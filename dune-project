(lang dune 3.21)

(using melange 0.1)

(using directory-targets 0.1)

(name ocaml-ai-sdk)

(version 0.1)

; There's an issues with the ocamlformat-mlx formatter version priting, so we're using the formatter arguments
; directly to avoid reading the .ocamlformat file when formatting mlx files. To replace when the version issue
; is fixed.

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (format
   (progn
    (ignore-stdout
     (cat %{project_root}/.ocamlformat))
    (run
     ocamlformat-mlx
     --disable-conf-files
     --enable-outside-detected-project
     --profile=default
     --break-cases=toplevel
     --no-break-infix-before-func
     --break-infix=fit-or-vertical
     --cases-exp-indent=2
     --doc-comments=before
     --exp-grouping=preserve
     --leading-nested-match-parens
     --let-and=sparse
     -m
     120
     --max-indent=2
     --module-item-spacing=preserve
     --nested-match=align
     --parens-ite
     --parens-tuple=multi-line-only
     --no-parse-docstrings
     --type-decl=sparse
     %{input-file})))
  (preprocess
   (run mlx-pp %{input-file}))))

(generate_opam_files true)

(source
 (github ahrefs/ocaml-ai-sdk))

(authors "Ahrefs")

(maintainers "José Nogueira <jose.nogueira@ahrefs.com>")

(license MIT)

(documentation https://github.com/ahrefs/ocaml-ai-sdk)

(package
 (name ocaml-ai-sdk)
 (synopsis "OCaml AI SDK - Provider abstraction for AI models")
 (description
  "Type-safe, provider-agnostic AI model abstraction inspired by Vercel AI SDK")
 (depends
  (ocaml
   (>= 4.14))
  (lwt
   (>= 5.9))
  (yojson
   (>= 2.2))
  (jsonschema
   (>= 0.1))
  (melange-json-native
   (>= 2.0))
  (cohttp-lwt-unix
   (>= 5.3))
  (lwt_ssl
   (>= 1.2))
  (base64
   (>= 1.3))
  (ppx_deriving
   (>= 5.2))
  (lwt_ppx
   (>= 5.9))
  (re2
   (>= 0.16))
  (uuseg
   (>= 17.0))
  (trace
   (>= 0.12))
  (alcotest :with-test)))

(package
 (name ai-sdk-react)
 (synopsis "Melange bindings for @ai-sdk/react")
 (description "Type-safe OCaml/Melange bindings for Vercel AI SDK)")
 (depends
  (ocaml
   (>= 4.14))
  (melange
   (>= 4.0.0))))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html

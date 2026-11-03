//! The in-memory module registry and its import glue, driven through the library (the binary has
//! no way to register modules yet).

use rquickjs::{Context, Ctx, Runtime};
use tiny_js_sandbox::{
    modules::{AddError, Modules, MAX_NAME_BYTES},
    vm::create_context,
};

fn setup() -> (Runtime, Context, Modules) {
    let runtime = Runtime::new().unwrap();
    let modules = Modules::default();
    modules.install(&runtime);
    let context = create_context(&runtime, false).unwrap();
    (runtime, context, modules)
}

/// Runs `script`, drains the job queue, and returns `String(globalThis.out)`.
fn run(runtime: &Runtime, context: &Context, script: &str) -> String {
    context.with(|ctx: Ctx<'_>| {
        ctx.eval::<(), _>(script).unwrap();
    });
    while runtime.execute_pending_job().unwrap() {}
    context.with(|ctx: Ctx<'_>| ctx.eval::<String, _>("String(globalThis.out)").unwrap())
}

#[test]
fn dynamic_import_reaches_a_registered_module() {
    let (runtime, context, modules) = setup();
    modules
        .add(
            "lodash",
            "export const chunk = (a, n) => [a.slice(0, n), a.slice(n)]; export default 7;".into(),
        )
        .unwrap();
    let out = run(
        &runtime,
        &context,
        r#"import("lodash").then(m => { globalThis.out = JSON.stringify(m.chunk([1, 2, 3], 1)) + m.default; });"#,
    );
    assert_eq!(out, "[[1],[2,3]]7");
}

#[test]
fn modules_import_each_other_by_exact_name() {
    let (runtime, context, modules) = setup();
    modules.add("@scope/base", "export const x = 40;".into()).unwrap();
    modules
        .add(
            "app",
            r#"import { x } from "@scope/base"; export const y = x + 2;"#.into(),
        )
        .unwrap();
    let out = run(
        &runtime,
        &context,
        r#"import("app").then(m => { globalThis.out = m.y; });"#,
    );
    assert_eq!(out, "42");
}

#[test]
fn a_module_is_evaluated_once() {
    let (runtime, context, modules) = setup();
    modules
        .add(
            "counter",
            "globalThis.n = (globalThis.n ?? 0) + 1; export default 1;".into(),
        )
        .unwrap();
    let out = run(
        &runtime,
        &context,
        r#"import("counter").then(() => import("counter")).then(() => { globalThis.out = globalThis.n; });"#,
    );
    assert_eq!(out, "1");
}

#[test]
fn unknown_and_relative_specifiers_reject() {
    let (runtime, context, modules) = setup();
    modules.add("known", "export default 1;".into()).unwrap();
    for specifier in ["missing", "./known", "../known", "/etc/passwd", "node:fs"] {
        let out = run(
            &runtime,
            &context,
            &format!(
                r#"import("{specifier}").then(() => {{ globalThis.out = "loaded"; }}, e => {{ globalThis.out = "rejected"; }});"#
            ),
        );
        assert_eq!(out, "rejected", "{specifier}");
    }
}

#[test]
fn registration_does_not_parse_so_a_syntax_error_surfaces_on_import() {
    let (runtime, context, modules) = setup();
    modules.add("broken", "export const = ;".into()).unwrap();
    let out = run(
        &runtime,
        &context,
        r#"import("broken").then(() => { globalThis.out = "loaded"; }, e => { globalThis.out = e.name; });"#,
    );
    assert_eq!(out, "SyntaxError");
}

#[test]
fn a_module_added_after_the_runtime_started_is_importable() {
    let (runtime, context, modules) = setup();
    assert_eq!(
        run(
            &runtime,
            &context,
            r#"import("late").then(() => { globalThis.out = "ok"; }, () => { globalThis.out = "no"; });"#
        ),
        "no"
    );
    modules.add("late", "export default 1;".into()).unwrap();
    assert_eq!(
        run(
            &runtime,
            &context,
            r#"import("late").then(() => { globalThis.out = "ok"; }, () => { globalThis.out = "no"; });"#
        ),
        "ok"
    );
}

#[test]
fn names_are_validated_and_unique() {
    let modules = Modules::default();
    let too_long = "a".repeat(MAX_NAME_BYTES + 1);
    for bad in [
        "",
        ".hidden",
        "./x",
        "has space",
        "new\nline",
        "naïve",
        too_long.as_str(),
    ] {
        assert_eq!(modules.add(bad, String::new()), Err(AddError::InvalidName), "{bad:?}");
    }
    assert_eq!(modules.add("lodash", String::new()), Ok(()));
    assert_eq!(modules.add("lodash", String::new()), Err(AddError::Duplicate));
    assert_eq!(modules.add(&"a".repeat(MAX_NAME_BYTES), String::new()), Ok(()));
}

#[test]
fn a_name_stays_taken_after_its_module_was_imported() {
    let (runtime, context, modules) = setup();
    modules.add("once", "export default 1;".into()).unwrap();
    run(
        &runtime,
        &context,
        r#"import("once").then(() => { globalThis.out = 1; });"#,
    );
    assert_eq!(
        modules.add("once", "export default 2;".into()),
        Err(AddError::Duplicate)
    );
}

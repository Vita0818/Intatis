use serde_json::{Value, json};
use std::process::Command;

fn invoke(operation: &str, request: Value) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_intatis-rbook-helper"))
        .arg("json-v1")
        .env("INTATIS_DOCUMENT_OPERATION", operation)
        .env("INTATIS_DOCUMENT_REQUEST", request.to_string())
        .output()
        .expect("run helper");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 stdout");
    assert_eq!(
        stdout.lines().count(),
        1,
        "stdout must contain one JSON envelope"
    );
    serde_json::from_str(stdout.trim_end()).expect("decode envelope")
}

#[test]
fn emits_fixed_validation_envelope_for_unknown_fields() {
    let response = invoke(
        "write",
        json!({
            "schema_version": 1,
            "engine": "rbook",
            "expected_version": "0.7.10",
            "operation": "write",
            "payload": {
                "format": "epub",
                "mode": "create",
                "output_path": "/tmp/book.epub",
                "operations": [],
                "allowed_asset_paths": [],
                "unexpected": true
            }
        }),
    );
    assert_eq!(response["schema_version"], 1);
    assert_eq!(response["ok"], false);
    assert_eq!(response["code"], "validation_failed");
    assert_eq!(response["summary"], "rbook request validation failed");
    assert_eq!(response["engine_versions"]["rbook"], "0.7.10");
}

#[test]
fn distinguishes_version_and_operation_failures() {
    let version = invoke(
        "write",
        json!({
            "schema_version": 1,
            "engine": "rbook",
            "expected_version": "0.7.9",
            "operation": "write",
            "payload": {}
        }),
    );
    assert_eq!(version["code"], "backend_version_mismatch");

    let operation = invoke(
        "delete",
        json!({
            "schema_version": 1,
            "engine": "rbook",
            "expected_version": "0.7.10",
            "operation": "delete",
            "payload": {}
        }),
    );
    assert_eq!(operation["code"], "unsupported_operation");
}

//! Conformance against the shared examples in `schemas/protocol/examples/`.
//! The Swift tests read the same files.

use std::{fs, path::PathBuf};

use cwb_protocol::{Message, schema};
use serde_json::Value;

fn examples(kind: &str) -> Vec<(String, Value)> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/protocol/examples")
        .join(kind);
    let mut out: Vec<_> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .map(|entry| entry.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .map(|p| {
            let text = fs::read_to_string(&p).unwrap();
            let name = p.file_name().unwrap().to_string_lossy().into_owned();
            let value = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
            (name, value)
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    assert!(!out.is_empty(), "no examples in {}", dir.display());
    out
}

#[test]
fn schema_is_valid_draft_2020_12() {
    let schema: Value = serde_json::from_str(schema::SCHEMA_V1).unwrap();
    assert!(jsonschema::meta::is_valid(&schema));
}

#[test]
fn valid_examples_pass_schema_and_round_trip_through_rust_types() {
    for (name, value) in examples("valid") {
        schema::validate(&value).unwrap_or_else(|e| panic!("{name}: {e:#?}"));
        let message: Message =
            serde_json::from_value(value.clone()).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(message.protocol_version(), cwb_protocol::PROTOCOL_VERSION);
        let reencoded = serde_json::to_value(&message).unwrap();
        assert_eq!(reencoded, value, "{name}: re-encoding changed the message");
        schema::validate(&reencoded).unwrap_or_else(|e| panic!("{name} re-encoded: {e:#?}"));
        if let Message::SampleBatch(batch) = &message {
            batch
                .check_contiguous()
                .unwrap_or_else(|e| panic!("{name}: {e}"));
        }
    }
}

#[test]
fn valid_examples_cover_every_message_type() {
    let schema: Value = serde_json::from_str(schema::SCHEMA_V1).unwrap();
    let mut expected: Vec<String> = schema["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            r["$ref"]
                .as_str()
                .unwrap()
                .rsplit('/')
                .next()
                .unwrap()
                .to_owned()
        })
        .collect();
    let mut seen: Vec<String> = examples("valid")
        .into_iter()
        .map(|(_, v)| v["type"].as_str().unwrap().to_owned())
        .collect();
    expected.sort();
    seen.sort();
    seen.dedup();
    assert_eq!(seen, expected);
}

#[test]
fn invalid_examples_fail_schema() {
    for (name, value) in examples("invalid") {
        assert!(
            schema::validate(&value).is_err(),
            "{name} should fail schema validation"
        );
    }
}

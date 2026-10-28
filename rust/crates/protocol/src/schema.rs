//! Validation against the committed JSON Schema.

use std::{collections::HashMap, sync::LazyLock};

use jsonschema::Validator;
use serde_json::Value;

/// The v1 schema, embedded at build time from `schemas/protocol/`.
pub const SCHEMA_V1: &str = include_str!("../../../../schemas/protocol/v1.schema.json");

static ROOT: LazyLock<Value> =
    LazyLock::new(|| serde_json::from_str(SCHEMA_V1).expect("v1 schema is valid JSON"));

static VALIDATOR: LazyLock<Validator> = LazyLock::new(|| compile(&ROOT));

/// One validator per message type, so errors name the field at fault instead
/// of only reporting that no `oneOf` branch matched.
static BY_TYPE: LazyLock<HashMap<String, Validator>> = LazyLock::new(|| {
    ROOT["oneOf"]
        .as_array()
        .expect("root oneOf")
        .iter()
        .map(|branch| {
            let reference = branch["$ref"].as_str().expect("oneOf entries are $refs");
            let name = reference.rsplit('/').next().expect("ref name").to_owned();
            let mut schema = ROOT.clone();
            let object = schema.as_object_mut().expect("schema object");
            object.remove("oneOf");
            object.insert("$ref".into(), Value::String(reference.to_owned()));
            (name, compile(&schema))
        })
        .collect()
});

fn compile(schema: &Value) -> Validator {
    jsonschema::draft202012::new(schema).expect("v1 schema compiles")
}

/// Validates a JSON value against the v1 schema, returning every error found.
pub fn validate(instance: &Value) -> Result<(), Vec<String>> {
    let message_type = instance.get("type").and_then(Value::as_str);
    let validator = match message_type.and_then(|t| BY_TYPE.get(t)) {
        Some(specific) => specific,
        None => &*VALIDATOR,
    };
    let errors: Vec<String> = validator
        .iter_errors(instance)
        .map(|e| {
            let path = e.instance_path().to_string();
            let path = if path.is_empty() {
                "/".to_owned()
            } else {
                path
            };
            format!("{path}: {e}")
        })
        .collect();
    if errors.is_empty() {
        // The per-type schema is a subset check; the full schema is the contract.
        if message_type.is_some() && !VALIDATOR.is_valid(instance) {
            return Err(vec!["/: does not match the v1 schema".into()]);
        }
        Ok(())
    } else {
        Err(errors)
    }
}

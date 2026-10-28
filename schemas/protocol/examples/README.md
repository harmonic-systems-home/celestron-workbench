# Protocol examples

Shared conformance fixtures for [v1.schema.json](../v1.schema.json). The Rust and Swift test suites both read this folder:

- every file in `valid/` must pass the schema and decode into the native message types, and
- every file in `invalid/` must fail the schema.

All identifiers are fictitious.

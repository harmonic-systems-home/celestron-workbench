//! `cwb`: Celestron Workbench command-line tools.
//!
//! Session, replay and report commands arrive in later milestones. Nothing
//! here can move a mount.

use std::{fs, path::PathBuf, process::ExitCode};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde_json::Value;

#[derive(Parser)]
#[command(name = "cwb", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create the database if needed and apply pending migrations.
    Migrate {
        /// Path to the SQLite database (keep it outside this repo).
        #[arg(long, env = "CWB_DB")]
        db: PathBuf,
    },
    /// Validate protocol messages against the v1 schema.
    /// Accepts .json files (one message) and .ndjson files (one per line).
    Validate {
        #[arg(required = true)]
        files: Vec<PathBuf>,
    },
    /// Print the software, protocol and database schema versions.
    Versions,
}

fn main() -> Result<ExitCode> {
    match Cli::parse().command {
        Command::Migrate { db } => {
            let (_, applied) =
                cwb_storage::open(&db).with_context(|| format!("opening {}", db.display()))?;
            if applied.is_empty() {
                println!(
                    "{}: already at schema version {}",
                    db.display(),
                    cwb_storage::SCHEMA_VERSION
                );
            } else {
                println!("{}: applied migrations {applied:?}", db.display());
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Validate { files } => validate(&files),
        Command::Versions => {
            println!("cwb {}", env!("CARGO_PKG_VERSION"));
            println!("protocol {}", cwb_protocol::PROTOCOL_VERSION);
            println!("database schema {}", cwb_storage::SCHEMA_VERSION);
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn validate(files: &[PathBuf]) -> Result<ExitCode> {
    let mut failures = 0usize;
    let mut checked = 0usize;
    for path in files {
        let text =
            fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let ndjson = path.extension().is_some_and(|e| e == "ndjson");
        let documents: Vec<(usize, &str)> = if ndjson {
            text.lines()
                .enumerate()
                .filter(|(_, l)| !l.trim().is_empty())
                .map(|(i, l)| (i + 1, l))
                .collect()
        } else {
            vec![(1, text.as_str())]
        };
        for (line, doc) in documents {
            checked += 1;
            let location = if ndjson {
                format!("{}:{line}", path.display())
            } else {
                path.display().to_string()
            };
            let errors = match serde_json::from_str::<Value>(doc) {
                Err(e) => vec![format!("not JSON: {e}")],
                Ok(value) => check_message(&value),
            };
            for error in &errors {
                eprintln!("{location}: {error}");
            }
            if !errors.is_empty() {
                failures += 1;
            }
        }
    }
    println!("{checked} message(s) checked, {failures} invalid");
    Ok(if failures == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

fn check_message(value: &Value) -> Vec<String> {
    if let Err(errors) = cwb_protocol::schema::validate(value) {
        return errors;
    }
    match serde_json::from_value::<cwb_protocol::Message>(value.clone()) {
        Err(e) => vec![format!("schema-valid but not decodable: {e}")],
        Ok(cwb_protocol::Message::SampleBatch(batch)) => {
            batch.check_contiguous().err().into_iter().collect()
        }
        Ok(_) => Vec::new(),
    }
}

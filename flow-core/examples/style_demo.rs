//! Trains style learning on a written persona and compares output before and after.
//!
//! Runs against the deployed worker with a throwaway database:
//!   cargo run --example style_demo -- examples/personas/maya.json

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};

use flow::ffi::*;
use serde::Deserialize;

#[derive(Deserialize)]
struct Persona {
    name: String,
    contacts: HashMap<String, String>,
    messages: Vec<Message>,
    corrections: Vec<Correction>,
    held_out: Vec<Prompt>,
}

#[derive(Deserialize, serde::Serialize)]
struct Message {
    category: String,
    text: String,
}

#[derive(Deserialize)]
struct Correction {
    contact: String,
    said: String,
    sent: String,
}

#[derive(Deserialize)]
struct Prompt {
    contact: String,
    said: String,
}

fn cstring(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn take(ptr: *mut c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let value = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
    flow_free_string(ptr);
    Some(value)
}

fn format(handle: *mut FlowHandle, persona: &Persona, contact: &str, said: &str) -> String {
    let contact_name = cstring(&persona.contacts[contact]);
    let text = cstring(said);
    let app = cstring("Messages");
    take(flow_format_text(handle, text.as_ptr(), app.as_ptr(), contact_name.as_ptr()))
        .unwrap_or_else(|| format!("<error: {}>", take(flow_get_last_error(handle)).unwrap_or_default()))
}

fn run_held_out(handle: *mut FlowHandle, persona: &Persona) -> Vec<String> {
    persona
        .held_out
        .iter()
        .map(|p| format(handle, persona, &p.contact, &p.said))
        .collect()
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "examples/personas/maya.json".to_string());
    let persona: Persona = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();

    let db = std::env::temp_dir().join(format!("flow-style-demo-{}.db", std::process::id()));
    let db_path = cstring(db.to_str().unwrap());
    let handle = flow_init(db_path.as_ptr());
    assert!(!handle.is_null(), "flow_init failed");

    println!("== {}: baseline, nothing learned", persona.name);
    let before = run_held_out(handle, &persona);
    flow_reset_style_learning(handle);

    let messages = cstring(&serde_json::to_string(&persona.messages).unwrap());
    let imported = flow_import_style_examples_json(handle, messages.as_ptr());
    println!("\n== imported {imported} messages {} wrote", persona.name);

    for c in &persona.corrections {
        let output = format(handle, &persona, &c.contact, &c.said);
        let sent = cstring(&c.sent);
        flow_record_final_text(handle, sent.as_ptr());
        println!("  [{}] flow: {output:?}\n  {:>w$}  sent: {:?}", c.contact, "", c.sent, w = c.contact.len() + 2);
    }

    println!("\n== building style profile");
    if flow_rebuild_style_profile(handle) {
        println!("{}", take(flow_get_style_profile(handle)).unwrap_or_default());
    } else {
        println!("failed: {}", take(flow_get_last_error(handle)).unwrap_or_default());
    }

    println!("\n== after learning");
    let after = run_held_out(handle, &persona);
    for ((prompt, before), after) in persona.held_out.iter().zip(&before).zip(&after) {
        println!("[{}] said: {:?}", prompt.contact, prompt.said);
        println!("    before: {before:?}");
        println!("    after:  {after:?}");
    }

    println!("\n== edit stats {}", take(flow_get_style_stats_json(handle)).unwrap_or_default());

    flow_destroy(handle);
    let _ = std::fs::remove_file(&db);
}

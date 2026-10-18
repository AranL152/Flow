//! Inert requests for native sources. There are no model-generated paths or sends.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttachmentPlan {
    pub message: String,
    pub command: String,
    pub request: Option<AttachmentRequest>,
    pub clarification: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_terms_survive_the_protocol_and_reject_paths_or_wrong_sources() {
        let read = |source: &str, query: serde_json::Value| serde_json::from_value::<AttachmentPlan>(serde_json::json!({
            "message": "Here's the file.", "command": "Flow find my robotics presentation",
            "request": { "source": source, "kind": "presentation", "query": query }
        })).unwrap();
        let plan = read("file_search", serde_json::json!("robotics"));
        assert!(plan.validate());
        assert_eq!(serde_json::to_value(plan).unwrap()["request"]["query"], "robotics");
        for bad in ["", "   ", "/etc/passwd", "..\\secret", "robotics\nsecret"] {
            assert!(!read("file_search", serde_json::json!(bad)).validate());
        }
        assert!(!read("file_search", serde_json::Value::Null).validate());
        assert!(!read("clipboard", serde_json::json!("robotics")).validate());
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttachmentRequest {
    pub source: AttachmentSource,
    pub kind: AttachmentKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentSource { Clipboard, RecentDownload, FileSearch }

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentKind { Any, Image, Pdf, Presentation }

impl AttachmentPlan {
    pub fn validate(&self) -> bool {
        self.message.len() <= 20000 && !self.command.is_empty() && self.command.len() <= 20000 &&
        (self.request.is_some() != self.clarification.is_some()) &&
        self.clarification.as_ref().is_none_or(|s| !s.trim().is_empty() && s.len() <= 2000) &&
        self.request.as_ref().is_none_or(|r| match r.source {
            AttachmentSource::FileSearch => r.query.as_ref().is_some_and(|q|
                !q.trim().is_empty() && q.chars().count() <= 160 && q.split_whitespace().count() <= 12 &&
                q.chars().any(char::is_alphanumeric) && !q.chars().any(|c| c.is_control() || c == '/' || c == '\\')),
            _ => r.query.is_none(),
        })
    }
}

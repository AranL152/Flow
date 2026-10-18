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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttachmentRequest {
    pub source: AttachmentSource,
    pub kind: AttachmentKind,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentSource { Clipboard, RecentDownload }

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentKind { Any, Image, Pdf, Presentation }

impl AttachmentPlan {
    pub fn validate(&self) -> bool {
        self.message.len() <= 20000 && !self.command.is_empty() && self.command.len() <= 20000 &&
        (self.request.is_some() != self.clarification.is_some()) &&
        self.clarification.as_ref().is_none_or(|s| !s.trim().is_empty() && s.len() <= 2000)
    }
}

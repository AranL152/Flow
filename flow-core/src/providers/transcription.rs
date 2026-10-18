//! Transcription provider trait and types

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::AudioData;
use crate::error::Result;

/// Return false to cancel. Empty strings are liveness checks, not tokens.
pub type DictationDelta = Arc<dyn Fn(&str) -> bool + Send + Sync>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShortcutDefinition {
    pub trigger: String,
    pub replacement: String,
    pub case_sensitive: bool,
}

/// Request for transcription
#[derive(Debug, Clone)]
pub struct TranscriptionRequest {
    /// Raw audio data (16-bit PCM)
    pub audio: AudioData,
    /// Sample rate of the audio
    pub sample_rate: u32,
    /// Optional language hint (ISO 639-1 code, e.g., "en")
    pub language: Option<String>,
    /// Optional prompt to guide transcription
    pub prompt: Option<String>,
    /// Optional completion parameters for combined transcription+completion
    pub completion: Option<CompletionParams>,
    /// Finalized real-time ASR, supplied only to the Auto worker. Never interim text.
    pub final_transcript: Option<String>,
}

/// Parameters for completion (used in combined transcription+completion flow)
#[derive(Debug, Clone)]
pub struct CompletionParams {
    /// Writing mode (e.g., "formal", "casual", "very_casual", "excited")
    pub mode: String,
    /// App context for formatting
    pub app_context: Option<String>,
    /// Shortcut replacement texts that must be preserved exactly
    pub shortcuts_triggered: Vec<String>,
    /// Enabled static snippets expanded immediately after cloud ASR.
    pub shortcut_definitions: Vec<ShortcutDefinition>,
    pub attachment_commands_enabled: bool,
    /// Voice instruction (e.g., "reject him politely", "translate to Spanish")
    /// When present, worker uses instruction mode instead of normal formatting
    pub voice_instruction: Option<String>,
    /// User style profile and examples, see `style::build_personalization`
    pub personalization: Option<String>,
    /// Skip formatting and voice commands when returning raw dictation.
    pub auto_rewriting_enabled: bool,
}

impl TranscriptionRequest {
    pub fn new(audio: AudioData, sample_rate: u32) -> Self {
        Self {
            audio,
            sample_rate,
            language: None,
            prompt: None,
            completion: None,
            final_transcript: None,
        }
    }

    pub fn with_language(mut self, language: impl Into<String>) -> Self {
        self.language = Some(language.into());
        self
    }

    pub fn with_prompt(mut self, prompt: impl Into<String>) -> Self {
        self.prompt = Some(prompt.into());
        self
    }

    pub fn with_completion(mut self, params: CompletionParams) -> Self {
        self.completion = Some(params);
        self
    }
}

/// Response from transcription
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptionResponse {
    /// Transcribed text
    pub text: String,
    /// Confidence score (0.0 - 1.0) if available
    pub confidence: Option<f32>,
    /// Detected language if available
    pub language: Option<String>,
    /// Duration of audio in milliseconds
    pub duration_ms: u64,
    /// Individual word segments if available
    pub segments: Option<Vec<TranscriptionSegment>>,
    /// Completed/formatted text if worker performed completion
    #[serde(default)]
    pub completed_text: Option<String>,
    #[serde(default)]
    pub attachment: Option<crate::attachments::AttachmentPlan>,
}

/// A segment of transcribed text with timing
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptionSegment {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub confidence: Option<f32>,
}

/// Trait for transcription providers
#[async_trait]
pub trait TranscriptionProvider: Send + Sync {
    /// Get the provider name
    fn name(&self) -> &'static str;

    /// Transcribe audio to text
    async fn transcribe(&self, request: TranscriptionRequest) -> Result<TranscriptionResponse>;

    /// Providers without token support keep the buffered path; no fake deltas.
    async fn transcribe_stream(&self, request: TranscriptionRequest, on_delta: DictationDelta) -> Result<TranscriptionResponse> {
        if !on_delta("") { return Err(crate::error::Error::Transcription("Dictation cancelled".into())); }
        let result = self.transcribe(request).await?;
        if !on_delta("") { return Err(crate::error::Error::Transcription("Dictation cancelled".into())); }
        Ok(result)
    }

    /// Check if the provider is configured and ready
    fn is_configured(&self) -> bool;
}

//! Cloud ("Auto") provider backed by the flow-worker-langgraph Cloudflare Worker (deployed as base10-proxy)
//!
//! Combined transcription and completion in a single worker request.
//! Whisper and the formatting LLM run on Workers AI, so no API keys live in the client.

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::{debug, error};

use crate::error::{Error, Result};

use super::{
    TranscriptionCompletionParams as CompletionParams, TranscriptionProvider, TranscriptionRequest,
    TranscriptionResponse,
};
use crate::style::{ExampleSource, StyleExample};

const BASE10_PROXY_URL: &str = "https://base10-proxy.old-resonance-ed75.workers.dev";
const BASE10_VALIDATE_URL: &str =
    "https://base10-proxy.old-resonance-ed75.workers.dev/validate-corrections";
const STYLE_PROFILE_URL: &str = "https://base10-proxy.old-resonance-ed75.workers.dev/style-profile";

/// Examples sent per profile build, newest first
const PROFILE_SAMPLE_SIZE: usize = 200;

/// Auto transcription provider (with integrated completion)
pub struct AutoTranscriptionProvider {
    client: Client,
}

/// A correction pair to validate
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorrectionPair {
    pub original: String,
    pub corrected: String,
}

/// Validation result for a correction
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorrectionValidation {
    pub original: String,
    pub corrected: String,
    pub valid: bool,
    pub reason: Option<String>,
}

/// Request to validate corrections
#[derive(Debug, Serialize)]
struct ValidateCorrectionsRequest {
    corrections: Vec<CorrectionPair>,
}

/// Response from validation endpoint
#[derive(Debug, Deserialize)]
struct ValidateCorrectionsResponse {
    results: Vec<CorrectionValidation>,
}

/// Validate corrections using AI via the Flow worker
pub async fn validate_corrections(
    corrections: Vec<CorrectionPair>,
) -> Result<Vec<CorrectionValidation>> {
    if corrections.is_empty() {
        return Ok(vec![]);
    }

    let client = Client::new();
    let request = ValidateCorrectionsRequest { corrections };

    debug!(
        "Validating {} corrections via worker",
        request.corrections.len()
    );

    let response = client
        .post(BASE10_VALIDATE_URL)
        .json(&request)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        error!("Validation worker error: {} - {}", status, error_text);
        return Err(Error::Transcription(format!(
            "Validation error: {} - {}",
            status, error_text
        )));
    }

    let validation_response: ValidateCorrectionsResponse = response.json().await?;
    Ok(validation_response.results)
}

async fn post_worker<T: Serialize, R: serde::de::DeserializeOwned>(
    url: &str,
    body: &T,
) -> Result<R> {
    let response = Client::new().post(url).json(body).send().await?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        error!("Worker error: {} - {}", status, error_text);
        return Err(Error::Transcription(format!(
            "Worker error: {} - {}",
            status, error_text
        )));
    }

    Ok(response.json().await?)
}

/// Format typed text through the worker, as if it had been dictated
pub async fn format_text(text: &str, completion: CompletionParams) -> Result<String> {
    let request = WorkerRequest {
        whisper_input: WhisperInput {
            audio: None,
            text: Some(text.to_string()),
            whisper_params: WhisperParams {
                audio_language: "en".to_string(),
            },
        },
        completion: completion.into(),
    };

    let response: WorkerResponse = post_worker(BASE10_PROXY_URL, &request).await?;
    Ok(response.text)
}

#[derive(Debug, Serialize)]
struct ProfileExample<'a> {
    category: &'a str,
    sent: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    formatter_wrote: Option<&'a str>,
}

#[derive(Debug, Serialize)]
struct StyleProfileRequest<'a> {
    examples: Vec<ProfileExample<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    current_profile: Option<&'a str>,
}

#[derive(Debug, Deserialize)]
struct StyleProfileResponse {
    profile: String,
}

/// Summarise the user's messages into a Markdown style profile
pub async fn build_style_profile(
    examples: &[StyleExample],
    current_profile: Option<&str>,
) -> Result<String> {
    let request = StyleProfileRequest {
        examples: examples
            .iter()
            .filter(|e| !e.sent.trim().is_empty())
            .take(PROFILE_SAMPLE_SIZE)
            .map(|e| ProfileExample {
                category: &e.category,
                sent: &e.sent,
                formatter_wrote: (e.edited && e.source == ExampleSource::Dictation)
                    .then_some(e.flow_output.as_str()),
            })
            .collect(),
        current_profile,
    };

    if request.examples.is_empty() {
        return Err(Error::Transcription(
            "No examples to build a profile from".to_string(),
        ));
    }

    let response: StyleProfileResponse = post_worker(STYLE_PROFILE_URL, &request).await?;
    Ok(response.profile)
}

impl AutoTranscriptionProvider {
    pub fn new(_api_key: Option<String>) -> Self {
        Self {
            client: Client::new(),
        }
    }
}

#[derive(Debug, Serialize)]
struct WorkerRequest {
    whisper_input: WhisperInput,
    completion: WorkerCompletionParams,
}

#[derive(Debug, Serialize)]
struct WhisperInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    audio: Option<AudioInput>,
    /// Typed text; the worker skips transcription when set
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    whisper_params: WhisperParams,
}

#[derive(Debug, Serialize)]
struct AudioInput {
    audio_b64: String,
}

#[derive(Debug, Serialize)]
struct WhisperParams {
    audio_language: String,
}

#[derive(Debug, Serialize)]
struct WorkerCompletionParams {
    mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_context: Option<String>,
    shortcuts_triggered: Vec<String>,
    shortcut_definitions: Vec<super::transcription::ShortcutDefinition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    voice_instruction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    personalization: Option<String>,
    auto_rewriting_enabled: bool,
    attachment_commands_enabled: bool,
    attachment_search_enabled: bool,
}

impl From<CompletionParams> for WorkerCompletionParams {
    fn from(params: CompletionParams) -> Self {
        Self {
            mode: params.mode,
            app_context: params.app_context,
            shortcuts_triggered: params.shortcuts_triggered,
            shortcut_definitions: params.shortcut_definitions,
            voice_instruction: params.voice_instruction,
            personalization: params.personalization,
            auto_rewriting_enabled: params.auto_rewriting_enabled,
            attachment_commands_enabled: params.attachment_commands_enabled,
            attachment_search_enabled: params.attachment_commands_enabled,
        }
    }
}

#[derive(Debug, Deserialize)]
struct WorkerResponse {
    transcription: String,
    text: String,
    #[serde(default)]
    attachment: Option<crate::attachments::AttachmentPlan>,
    #[serde(default)]
    attachment_protocol: Option<u8>,
    #[serde(default)]
    language: Option<String>,
}

#[async_trait]
impl TranscriptionProvider for AutoTranscriptionProvider {
    fn name(&self) -> &'static str {
        "Auto (Cloud)"
    }

    async fn transcribe(&self, request: TranscriptionRequest) -> Result<TranscriptionResponse> {
        let wav_data = pcm_to_wav(&request.audio, request.sample_rate, 1);
        let audio_base64 = STANDARD.encode(&wav_data);
        let language = request.language.as_deref().unwrap_or("auto").to_string();

        // Completion params are required
        let completion = request.completion.ok_or_else(|| {
            Error::Transcription("Completion params required for auto mode".to_string())
        })?;

        let worker_request = WorkerRequest {
            whisper_input: WhisperInput {
                audio: Some(AudioInput {
                    audio_b64: audio_base64,
                }),
                text: None,
                whisper_params: WhisperParams {
                    audio_language: language,
                },
            },
            completion: completion.into(),
        };

        debug!("Sending combined transcription+completion request to worker");

        let response = self
            .client
            .post(BASE10_PROXY_URL)
            .json(&worker_request)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            error!("Worker error: {} - {}", status, error_text);
            return Err(Error::Transcription(format!(
                "Worker error: {} - {}",
                status, error_text
            )));
        }

        let worker_response: WorkerResponse = response.json().await?;
        if worker_request.completion.attachment_commands_enabled && worker_response.attachment_protocol != Some(1) {
            return Err(Error::Transcription("Update the Flow worker to support attachment commands".into()));
        }
        if worker_response.attachment.as_ref().is_some_and(|p| !p.validate()) {
            return Err(Error::Transcription("Invalid attachment plan".into()));
        }

        let samples = request.audio.len() / 2;
        let duration_ms = (samples as u64 * 1000) / request.sample_rate as u64;

        Ok(TranscriptionResponse {
            text: worker_response.transcription,
            confidence: None,
            language: worker_response.language,
            duration_ms,
            segments: None,
            completed_text: Some(worker_response.text),
            attachment: worker_response.attachment,
        })
    }

    fn is_configured(&self) -> bool {
        true
    }

    async fn transcribe_stream(&self, request: TranscriptionRequest, on_delta: super::DictationDelta) -> Result<TranscriptionResponse> {
        if !on_delta("") { return Err(Error::Transcription("Dictation cancelled".into())); }
        let completion = request.completion.ok_or_else(|| Error::Transcription("Completion params required for Auto mode".into()))?;
        let body = WorkerRequest { whisper_input: WhisperInput {
            audio: request.final_transcript.is_none().then(|| AudioInput {
                audio_b64: STANDARD.encode(pcm_to_wav(&request.audio, request.sample_rate, 1)),
            }), text: request.final_transcript,
            whisper_params: WhisperParams { audio_language: request.language.unwrap_or_else(|| "auto".into()) },
        }, completion: completion.into() };
        let endpoint = std::env::var("FLOW_STREAM_ENDPOINT").unwrap_or_else(|_| format!("{BASE10_PROXY_URL}/transcribe-stream"));
        if request.sample_rate == 0 { return Err(Error::Transcription("Invalid sample rate".into())); }
        let pending_response = self.client.post(endpoint).json(&body).timeout(std::time::Duration::from_secs(90)).send();
        tokio::pin!(pending_response);
        let response = loop {
            tokio::select! {
                response = &mut pending_response => break response?,
                _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                    if !on_delta("") { return Err(Error::Transcription("Dictation cancelled".into())); }
                }
            }
        };
        let duration_ms = (request.audio.len() as u64 / 2 * 1000) / u64::from(request.sample_rate);
        if body.completion.attachment_commands_enabled {
            super::dictation_stream::consume_with_attachments(response, duration_ms, on_delta, true).await
        } else {
            super::dictation_stream::consume(response, duration_ms, on_delta).await
        }
    }
}

fn pcm_to_wav(pcm: &[u8], sample_rate: u32, channels: u16) -> Vec<u8> {
    let bits_per_sample: u16 = 16;
    let byte_rate = sample_rate * u32::from(channels) * u32::from(bits_per_sample) / 8;
    let block_align = channels * bits_per_sample / 8;
    let data_size = pcm.len() as u32;
    let file_size = 36 + data_size;

    let mut wav = Vec::with_capacity(44 + pcm.len());

    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&file_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());
    wav.extend_from_slice(pcm);

    wav
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pcm_to_wav() {
        let pcm = vec![0u8; 32000];
        let wav = pcm_to_wav(&pcm, 16000, 1);

        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(wav.len(), 44 + 32000);
    }

    #[test]
    fn test_provider_always_configured() {
        let provider = AutoTranscriptionProvider::new(None);
        assert!(provider.is_configured());
    }
}

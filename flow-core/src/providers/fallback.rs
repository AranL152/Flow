//! Fallback transcription provider: a primary provider with an automatic
//! cloud fallback.
//!
//! Local Whisper can fail for benign reasons - the model is still downloading,
//! a Metal/inference error, or an empty result on very short or silent audio.
//! Without a fallback those failures lose the user's dictation. This decorator
//! tries the primary provider first and transparently retries against a cloud
//! provider only when the primary errors or returns no usable text. When the
//! primary succeeds, its response is returned unchanged so accuracy is
//! identical to running the primary alone.

use async_trait::async_trait;
use std::sync::Arc;
use tracing::warn;

use super::{TranscriptionProvider, TranscriptionRequest, TranscriptionResponse};
use crate::error::{Error, Result};

/// Wraps a primary transcription provider and falls back to a secondary
/// provider when the primary fails or produces an empty result.
pub struct FallbackTranscriptionProvider {
    primary: Arc<dyn TranscriptionProvider>,
    fallback: Arc<dyn TranscriptionProvider>,
}

impl FallbackTranscriptionProvider {
    pub fn new(
        primary: Arc<dyn TranscriptionProvider>,
        fallback: Arc<dyn TranscriptionProvider>,
    ) -> Self {
        Self { primary, fallback }
    }
}

/// A response is usable when it has non-empty transcription text or already
/// carries completed text from an integrated worker.
fn is_usable(response: &TranscriptionResponse) -> bool {
    !response.text.trim().is_empty()
        || response
            .completed_text
            .as_deref()
            .is_some_and(|t| !t.trim().is_empty())
}

#[async_trait]
impl TranscriptionProvider for FallbackTranscriptionProvider {
    fn name(&self) -> &'static str {
        self.primary.name()
    }

    async fn transcribe(&self, request: TranscriptionRequest) -> Result<TranscriptionResponse> {
        match self.primary.transcribe(request.clone()).await {
            Ok(response) if is_usable(&response) => Ok(response),
            Ok(_) => {
                warn!(
                    "Primary transcription '{}' returned empty result, falling back to '{}'",
                    self.primary.name(),
                    self.fallback.name()
                );
                self.fallback.transcribe(request).await
            }
            Err(primary_err) => {
                warn!(
                    "Primary transcription '{}' failed ({}), falling back to '{}'",
                    self.primary.name(),
                    primary_err,
                    self.fallback.name()
                );
                self.fallback
                    .transcribe(request)
                    .await
                    .map_err(|fallback_err| {
                        Error::Transcription(format!(
                            "primary ({}) failed: {primary_err}; fallback ({}) failed: {fallback_err}",
                            self.primary.name(),
                            self.fallback.name()
                        ))
                    })
            }
        }
    }

    fn is_configured(&self) -> bool {
        self.primary.is_configured() || self.fallback.is_configured()
    }

    async fn transcribe_stream(&self, request: TranscriptionRequest, on_delta: super::DictationDelta) -> Result<TranscriptionResponse> {
        // A partially emitted response must never be silently replaced by a retry.
        let emitted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = emitted.clone();
        let next = on_delta.clone();
        let tracked: super::DictationDelta = Arc::new(move |text| {
            if !text.is_empty() { flag.store(true, std::sync::atomic::Ordering::Relaxed); }
            next(text)
        });
        match self.primary.transcribe_stream(request.clone(), tracked).await {
            Ok(response) if is_usable(&response) => Ok(response),
            result if emitted.load(std::sync::atomic::Ordering::Relaxed) => result,
            _ => {
                if !on_delta("") { return Err(Error::Transcription("Dictation cancelled".into())); }
                self.fallback.transcribe_stream(request, on_delta).await
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;

    /// Configurable mock provider that records how many times it was called.
    struct MockProvider {
        name: &'static str,
        result: Mutex<Option<Result<TranscriptionResponse>>>,
        calls: Mutex<usize>,
        configured: bool,
    }

    impl MockProvider {
        fn ok(name: &'static str, text: &str) -> Arc<Self> {
            Arc::new(Self {
                name,
                result: Mutex::new(Some(Ok(response(text, None)))),
                calls: Mutex::new(0),
                configured: true,
            })
        }

        fn err(name: &'static str) -> Arc<Self> {
            Arc::new(Self {
                name,
                result: Mutex::new(Some(Err(Error::Transcription("boom".into())))),
                calls: Mutex::new(0),
                configured: true,
            })
        }

        fn empty(name: &'static str) -> Arc<Self> {
            Arc::new(Self {
                name,
                result: Mutex::new(Some(Ok(response("   ", None)))),
                calls: Mutex::new(0),
                configured: true,
            })
        }

        fn call_count(&self) -> usize {
            *self.calls.lock()
        }
    }

    fn response(text: &str, completed: Option<&str>) -> TranscriptionResponse {
        TranscriptionResponse {
            text: text.to_string(),
            confidence: None,
            language: Some("en".to_string()),
            duration_ms: 0,
            segments: None,
            completed_text: completed.map(|s| s.to_string()),
        }
    }

    fn request() -> TranscriptionRequest {
        TranscriptionRequest::new(vec![0u8; 16], 16_000)
    }

    #[async_trait]
    impl TranscriptionProvider for MockProvider {
        fn name(&self) -> &'static str {
            self.name
        }

        async fn transcribe(
            &self,
            _request: TranscriptionRequest,
        ) -> Result<TranscriptionResponse> {
            *self.calls.lock() += 1;
            self.result.lock().take().expect("mock called twice")
        }

        fn is_configured(&self) -> bool {
            self.configured
        }
    }

    #[tokio::test]
    async fn uses_primary_when_it_succeeds() {
        let primary = MockProvider::ok("primary", "hello world");
        let fallback = MockProvider::ok("fallback", "should not run");
        let provider =
            FallbackTranscriptionProvider::new(primary.clone(), fallback.clone());

        let out = provider.transcribe(request()).await.unwrap();

        assert_eq!(out.text, "hello world");
        assert_eq!(primary.call_count(), 1);
        assert_eq!(fallback.call_count(), 0);
    }

    #[tokio::test]
    async fn falls_back_when_primary_errors() {
        let primary = MockProvider::err("primary");
        let fallback = MockProvider::ok("fallback", "recovered");
        let provider =
            FallbackTranscriptionProvider::new(primary.clone(), fallback.clone());

        let out = provider.transcribe(request()).await.unwrap();

        assert_eq!(out.text, "recovered");
        assert_eq!(primary.call_count(), 1);
        assert_eq!(fallback.call_count(), 1);
    }

    #[tokio::test]
    async fn falls_back_when_primary_is_empty() {
        let primary = MockProvider::empty("primary");
        let fallback = MockProvider::ok("fallback", "recovered");
        let provider =
            FallbackTranscriptionProvider::new(primary.clone(), fallback.clone());

        let out = provider.transcribe(request()).await.unwrap();

        assert_eq!(out.text, "recovered");
        assert_eq!(fallback.call_count(), 1);
    }

    #[tokio::test]
    async fn surfaces_both_errors_when_fallback_also_fails() {
        let primary = MockProvider::err("primary");
        let fallback = MockProvider::err("fallback");
        let provider = FallbackTranscriptionProvider::new(primary, fallback);

        let err = provider.transcribe(request()).await.unwrap_err();
        let message = err.to_string();

        assert!(message.contains("primary"));
        assert!(message.contains("fallback"));
    }

    #[tokio::test]
    async fn completed_text_counts_as_usable() {
        let primary = Arc::new(MockProvider {
            name: "primary",
            result: Mutex::new(Some(Ok(response("", Some("formatted output"))))),
            calls: Mutex::new(0),
            configured: true,
        });
        let fallback = MockProvider::ok("fallback", "should not run");
        let provider =
            FallbackTranscriptionProvider::new(primary, fallback.clone());

        let out = provider.transcribe(request()).await.unwrap();

        assert_eq!(out.completed_text.as_deref(), Some("formatted output"));
        assert_eq!(fallback.call_count(), 0);
    }
}

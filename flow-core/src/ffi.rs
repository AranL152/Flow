//! FFI layer for Swift integration
//!
//! Provides C-compatible functions that can be called from Swift.
//! Uses opaque pointers and C strings for cross-language compatibility.

// FFI functions necessarily work with raw pointers - this is expected behavior
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use parking_lot::Mutex;
use serde::Serialize;
use tokio::runtime::Runtime;
use tracing::{debug, error};

use crate::apps::AppTracker;
use crate::audio::{AudioCapture, CaptureState};
use crate::contacts::{ContactClassifier, ContactInput};
use crate::learning::LearningEngine;
use crate::macos_messages::MessagesDetector;
use crate::modes::{StyleLearner, WritingMode, WritingModeEngine};
use crate::providers::{
    AutoTranscriptionProvider, CompletionProvider, CompletionRequest,
    FallbackTranscriptionProvider, GeminiCompletionProvider, GeminiTranscriptionProvider,
    LocalWhisperTranscriptionProvider, OpenAICompletionProvider, OpenAITranscriptionProvider,
    OpenRouterCompletionProvider, TranscriptionCompletionParams, TranscriptionProvider,
    TranscriptionRequest, WhisperModel,
};
use crate::shortcuts::ShortcutsEngine;
use crate::storage::{
    SETTING_AUTO_REWRITING_ENABLED, SETTING_CLOUD_TRANSCRIPTION_PROVIDER,
    SETTING_COMPLETION_PROVIDER, SETTING_GEMINI_API_KEY, SETTING_IMESSAGE_IMPORTED_THROUGH,
    SETTING_LOCAL_WHISPER_MODEL, SETTING_OPENAI_API_KEY, SETTING_OPENAI_BASE_URL,
    SETTING_OPENROUTER_API_KEY, SETTING_REWRITE_STRENGTH, SETTING_STYLE_PROFILE,
    SETTING_STYLE_PROFILE_EXAMPLE_COUNT, SETTING_TRANSCRIPTION_FALLBACK,
    SETTING_USE_LOCAL_TRANSCRIPTION, Storage,
};
use crate::style::{self, PendingDictation, RewriteStrength, StyleExample};
use crate::types::{
    ContactCategory, Shortcut, Transcription, TranscriptionHistoryEntry, TranscriptionStatus,
};

/// Log with timestamp
macro_rules! log_with_time {
    ($($arg:tt)*) => {{
        use std::io::Write;
        let now = chrono::Local::now();
        println!("[{}] {}", now.format("%Y-%m-%d %H:%M:%S%.3f"), format!($($arg)*));
        let _ = std::io::stdout().flush();
    }};
}

/// Examples loaded when choosing which to show the formatter
const STYLE_EXAMPLE_POOL: usize = 5000;

/// Opaque handle to the Flow engine
pub struct FlowHandle {
    runtime: Runtime,
    storage: Storage,
    audio: Mutex<Option<AudioCapture>>,
    last_audio: Mutex<Option<crate::AudioData>>,
    last_audio_sample_rate: Mutex<Option<u32>>,
    last_error: Mutex<Option<String>>,
    transcription: Arc<dyn TranscriptionProvider>,
    completion: Arc<dyn CompletionProvider>,
    shortcuts: ShortcutsEngine,
    learning: LearningEngine,
    modes: Mutex<WritingModeEngine>,
    app_tracker: AppTracker,
    style_learner: Mutex<StyleLearner>,
    is_model_loading: Arc<AtomicBool>,
    contact_classifier: ContactClassifier,
    /// Captured contact name at recording start (for Messages.app context)
    captured_contact: Mutex<Option<String>>,
    /// Temporary storage for audio between stop and transcribe (ensures mic is fully released)
    pending_audio: Mutex<Option<crate::AudioData>>,
    pending_sample_rate: Mutex<Option<u32>>,
    /// Last dictation, waiting for the text the user finally sent
    pending_dictation: Mutex<Option<PendingDictation>>,
    pending_attachment: Mutex<Option<crate::attachments::AttachmentPlan>>,
    live_rewrite: Mutex<Option<LiveRewritePrefix>>,
    live_rewrite_epoch: AtomicU64,
}

struct LiveRewritePrefix {
    app: Option<String>,
    contact: Option<String>,
    mode: String,
    prefix: crate::providers::StableRewritePrefix,
}

/// Demo conversation state, requests and explicit Send receipts. Caller serializes
/// calls; returned JSON is owned by the caller and freed with flow_free_string.
#[unsafe(no_mangle)]
pub extern "C" fn flow_demo_dispatch(
    handle: *mut FlowHandle,
    request: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let handle = unsafe { &*handle };
    let result = c_str(request)
        .ok_or_else(|| "Missing request".to_string())
        .and_then(|s| serde_json::from_str(s).map_err(|e| format!("Invalid JSON: {e}")))
        .and_then(|request| crate::demo::dispatch(&handle.storage, request));
    match result {
        Ok(value) => into_c_string(value.to_string()),
        Err(error) => into_c_string(serde_json::json!({"error": error}).to_string()),
    }
}

#[derive(Serialize)]
struct TranscriptionSummary {
    id: String,
    status: TranscriptionStatus,
    text: String,
    raw_text: String,
    error: Option<String>,
    duration_ms: u64,
    created_at: String,
    app_name: Option<String>,
}

/// Result callback type for async operations
pub type ResultCallback = extern "C" fn(success: bool, result: *const c_char, context: *mut c_void);

fn set_last_error(handle: &FlowHandle, message: impl Into<String>) {
    *handle.last_error.lock() = Some(message.into());
}

/// Check if Whisper model files exist in the models directory
fn check_model_files_exist(model: WhisperModel, models_dir: &std::path::Path) -> bool {
    let (model_id, _) = model.model_id();
    let model_name = model_id.split('/').next_back().unwrap();

    let config_path = models_dir.join(format!("{}-config.json", model_name));
    let tokenizer_path = models_dir.join(format!("{}-tokenizer.json", model_name));
    let weights_path = models_dir.join(format!("{}-model.safetensors", model_name));

    config_path.exists() && tokenizer_path.exists() && weights_path.exists()
}

fn clear_last_error(handle: &FlowHandle) {
    *handle.last_error.lock() = None;
}

/// Whether local transcription should fall back to the cloud on failure.
/// Defaults to enabled so a missing or still-downloading model never loses a dictation.
fn transcription_fallback_enabled(storage: &Storage) -> bool {
    storage
        .get_setting(SETTING_TRANSCRIPTION_FALLBACK)
        .ok()
        .flatten()
        .map(|s| s != "false")
        .unwrap_or(true)
}

/// Build the cloud provider used as a fallback for local transcription.
/// Uses OpenAI when it is the configured cloud provider and a key exists,
/// otherwise the keyless Auto (Base10) worker.
fn build_cloud_fallback(storage: &Storage) -> Arc<dyn TranscriptionProvider> {
    let cloud_provider = storage
        .get_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER)
        .ok()
        .flatten();

    if cloud_provider.as_deref() == Some("openai") {
        if let Ok(Some(key)) = storage.get_setting(SETTING_OPENAI_API_KEY) {
            if !key.is_empty() {
                let base_url = storage
                    .get_setting(SETTING_OPENAI_BASE_URL)
                    .ok()
                    .flatten()
                    .filter(|url| !url.is_empty());
                return Arc::new(OpenAITranscriptionProvider::new(Some(key), base_url));
            }
        }
    }

    Arc::new(AutoTranscriptionProvider::new(None))
}

/// Wrap a local primary provider with a cloud fallback when fallback is enabled.
fn wrap_with_fallback(
    storage: &Storage,
    primary: Arc<dyn TranscriptionProvider>,
) -> Arc<dyn TranscriptionProvider> {
    if transcription_fallback_enabled(storage) {
        let fallback = build_cloud_fallback(storage);
        Arc::new(FallbackTranscriptionProvider::new(primary, fallback))
    } else {
        primary
    }
}

fn estimate_duration_ms(bytes: usize, sample_rate: u32) -> u64 {
    let samples = bytes / 2;
    (samples as u64 * 1000) / sample_rate as u64
}

fn load_persisted_configuration(handle: &mut FlowHandle) {
    // Load all API keys
    let openai_key = handle
        .storage
        .get_setting(SETTING_OPENAI_API_KEY)
        .ok()
        .flatten();
    let openai_base_url = handle
        .storage
        .get_setting(SETTING_OPENAI_BASE_URL)
        .ok()
        .flatten()
        .filter(|s| !s.is_empty());
    let gemini_key = handle
        .storage
        .get_setting(SETTING_GEMINI_API_KEY)
        .ok()
        .flatten();
    let openrouter_key = handle
        .storage
        .get_setting(SETTING_OPENROUTER_API_KEY)
        .ok()
        .flatten();

    // Load saved provider preferences
    let saved_completion_provider = handle
        .storage
        .get_setting(SETTING_COMPLETION_PROVIDER)
        .ok()
        .flatten();

    let saved_cloud_transcription = handle
        .storage
        .get_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER)
        .ok()
        .flatten();

    let use_local_transcription = handle
        .storage
        .get_setting(SETTING_USE_LOCAL_TRANSCRIPTION)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(false);

    // Log what we found for debugging
    tracing::info!("Loading persisted config:");
    tracing::info!(
        "  OpenAI key: {}",
        if openai_key.is_some() { "SET" } else { "NONE" }
    );
    tracing::info!(
        "  Gemini key: {}",
        if gemini_key.is_some() { "SET" } else { "NONE" }
    );
    tracing::info!(
        "  OpenRouter key: {}",
        if openrouter_key.is_some() {
            "SET"
        } else {
            "NONE"
        }
    );
    tracing::info!(
        "  Saved completion provider: {:?}",
        saved_completion_provider
    );
    tracing::info!(
        "  Saved cloud transcription: {:?}",
        saved_cloud_transcription
    );
    tracing::info!("  Use local transcription: {}", use_local_transcription);

    // Initialize completion provider based on saved preference
    match saved_completion_provider.as_deref() {
        Some("gemini") => {
            debug!("Restoring Gemini completion provider from database");
            handle.completion = Arc::new(GeminiCompletionProvider::new(gemini_key.clone()));
        }
        Some("openrouter") => {
            debug!("Restoring OpenRouter completion provider from database");
            handle.completion = Arc::new(OpenRouterCompletionProvider::new(openrouter_key));
        }
        _ => {
            debug!("Restoring OpenAI completion provider from database");
            handle.completion = Arc::new(OpenAICompletionProvider::new(
                openai_key.clone(),
                openai_base_url.clone(),
            ));
        }
    }

    // Initialize transcription provider separately
    if use_local_transcription {
        // Local whisper will be initialized by flow_set_transcription_mode
        // For now, set a placeholder that will be replaced
        debug!("Local transcription enabled, will be initialized separately");
        handle.transcription = Arc::new(AutoTranscriptionProvider::new(None));
    } else {
        // Cloud transcription - check which provider
        match saved_cloud_transcription.as_deref() {
            Some("openai") => {
                debug!("Restoring OpenAI transcription provider from database");
                handle.transcription = Arc::new(OpenAITranscriptionProvider::new(
                    openai_key,
                    openai_base_url,
                ));
            }
            _ => {
                // Default to Auto (worker handles transcription + completion)
                debug!("Using Auto transcription provider (default)");
                handle.transcription = Arc::new(AutoTranscriptionProvider::new(None));
            }
        }
    }
}

// ============ Lifecycle ============

/// Initialize the Flow engine
///
/// Returns an opaque handle that must be passed to all other functions.
///
/// # Arguments
/// - `db_path` - Path to the SQLite database file, or NULL for default location
///
/// # Returns
/// Opaque handle to the engine, or NULL on failure
#[unsafe(no_mangle)]
pub extern "C" fn flow_init(db_path: *const c_char) -> *mut FlowHandle {
    let db_path = if db_path.is_null() {
        // default to app support directory
        dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("flow")
            .join("flow.db")
    } else {
        let path_str = match unsafe { CStr::from_ptr(db_path) }.to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        };
        PathBuf::from(path_str)
    };

    // ensure parent directory exists
    if let Some(parent) = db_path.parent()
        && let Err(e) = std::fs::create_dir_all(parent)
    {
        error!("Failed to create data directory: {}", e);
        return ptr::null_mut();
    }

    let runtime = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            error!("Failed to create async runtime: {}", e);
            return ptr::null_mut();
        }
    };

    let storage = match Storage::open(&db_path) {
        Ok(s) => s,
        Err(e) => {
            error!("Failed to open storage: {}", e);
            return ptr::null_mut();
        }
    };

    let shortcuts =
        ShortcutsEngine::from_storage(&storage).unwrap_or_else(|_| ShortcutsEngine::new());
    let learning = LearningEngine::from_storage(&storage).unwrap_or_else(|_| LearningEngine::new());
    let modes = WritingModeEngine::new(WritingMode::Casual);
    let app_tracker = AppTracker::new();
    let style_learner = StyleLearner::new();
    let contact_classifier = ContactClassifier::new();

    let mut handle = FlowHandle {
        runtime,
        storage,
        audio: Mutex::new(None),
        last_audio: Mutex::new(None),
        last_audio_sample_rate: Mutex::new(None),
        last_error: Mutex::new(None),
        transcription: Arc::new(OpenAITranscriptionProvider::new(None, None)),
        completion: Arc::new(OpenAICompletionProvider::new(None, None)),
        shortcuts,
        learning,
        modes: Mutex::new(modes),
        app_tracker,
        style_learner: Mutex::new(style_learner),
        is_model_loading: Arc::new(AtomicBool::new(false)),
        contact_classifier,
        captured_contact: Mutex::new(None),
        pending_audio: Mutex::new(None),
        pending_sample_rate: Mutex::new(None),
        pending_dictation: Mutex::new(None),
        pending_attachment: Mutex::new(None),
        live_rewrite: Mutex::new(None),
        live_rewrite_epoch: AtomicU64::new(0),
    };

    load_persisted_configuration(&mut handle);

    // Load transcription mode (local vs remote Whisper)
    let use_local = handle
        .storage
        .get_setting(SETTING_USE_LOCAL_TRANSCRIPTION)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(false);

    if use_local {
        log_with_time!("🔧 [INIT] Loading local Whisper transcription from database");
        let model_str = handle
            .storage
            .get_setting(SETTING_LOCAL_WHISPER_MODEL)
            .ok()
            .flatten();
        let model = WhisperModel::all()
            .iter()
            .find(|m| {
                let (id, _) = m.model_id();
                Some(id) == model_str.as_deref()
            })
            .copied()
            .unwrap_or(WhisperModel::Quality);

        // Get models directory
        match crate::whisper_models::get_models_dir() {
            Ok(models_dir) => {
                let local: Arc<dyn TranscriptionProvider> =
                    Arc::new(LocalWhisperTranscriptionProvider::new(model, models_dir));
                handle.transcription = wrap_with_fallback(&handle.storage, local);
                log_with_time!("✅ [INIT] Using local Whisper model: {:?}", model);
            }
            Err(e) => {
                error!("Failed to get models directory: {}", e);
                log_with_time!(
                    "⚠️ [INIT] Failed to load local Whisper, falling back to remote: {}",
                    e
                );
                handle.transcription = build_cloud_fallback(&handle.storage);
            }
        }
    } else {
        log_with_time!(
            "☁️ [INIT] Using cloud transcription: {}",
            handle.transcription.name()
        );
    }

    debug!("Flow engine initialized");

    Box::into_raw(Box::new(handle))
}

/// Destroy the Flow engine and free resources
#[unsafe(no_mangle)]
pub extern "C" fn flow_destroy(handle: *mut FlowHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
        debug!("Flow engine destroyed");
    }
}

// ============ Audio ============

/// Copy mono Float32 microphone samples for live, unformatted captions.
/// Does not drain or change audio used for final transcription. `offset` is a
/// sample index from recording start; advance it by the returned sample count.
/// Output capacity is capped at 65536 frames. Returns 0 when caught up.
/// After Stop, the remaining cached PCM is readable until transcription starts.
#[unsafe(no_mangle)]
pub extern "C" fn flow_read_recording_samples(
    handle: *mut FlowHandle,
    offset: u64,
    output: *mut f32,
    capacity: usize,
    sample_rate: *mut u32,
) -> usize {
    if handle.is_null() || output.is_null() || sample_rate.is_null() || capacity == 0 {
        return 0;
    }
    let Ok(offset) = usize::try_from(offset) else { return 0; };
    let handle = unsafe { &*handle };
    let output = unsafe { std::slice::from_raw_parts_mut(output, capacity.min(65536)) };
    unsafe { *sample_rate = 0; }
    let audio = handle.audio.lock();
    if let Some(capture) = audio.as_ref() {
        unsafe { *sample_rate = capture.sample_rate(); }
        return capture.read_samples(offset, output);
    }
    // Stop has released the microphone. Drain the final caption tail from the
    // existing cached audio before the final transcription consumes it.
    if let (Some(pcm), Some(rate)) = (handle.pending_audio.lock().as_ref(), *handle.pending_sample_rate.lock()) {
        unsafe { *sample_rate = rate; }
        let Some(start) = offset.checked_mul(2).filter(|start| *start <= pcm.len()) else { return 0; };
        let count = ((pcm.len() - start) / 2).min(output.len());
        for (sample, bytes) in output[..count].iter_mut().zip(pcm[start..].chunks_exact(2)) {
            *sample = f32::from(i16::from_le_bytes([bytes[0], bytes[1]])) / 32767.0;
        }
        return count;
    }
    0
}

/// Start audio recording
/// Returns true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_start_recording(handle: *mut FlowHandle) -> bool {
    start_recording(handle, None)
}

/// Swift supplies the contact from its already-authorized native AX connection.
/// A null contact explicitly means no contact; it never invokes AppleScript.
#[unsafe(no_mangle)]
pub extern "C" fn flow_start_recording_with_contact(handle: *mut FlowHandle, contact: *const c_char) -> bool {
    start_recording(handle, Some(c_str(contact).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)))
}

fn start_recording(handle: *mut FlowHandle, native_contact: Option<Option<String>>) -> bool {
    if handle.is_null() { return false; }
    let handle = unsafe { &*handle };
    handle.live_rewrite_epoch.fetch_add(1, Ordering::SeqCst);
    *handle.live_rewrite.lock() = None;

    // Capture the active Messages contact at recording START (before any focus changes)
    // This ensures we get the correct contact context for the transcription
    let current_app = handle.app_tracker.current_app();
    let is_messages = current_app
        .as_ref()
        .map(|ctx| {
            ctx.app_name.to_lowercase().contains("messages")
                || ctx.bundle_id.as_deref() == Some("com.apple.MobileSMS")
        })
        .unwrap_or(false);

    if let Some(contact) = native_contact {
        *handle.captured_contact.lock() = contact;
    } else if is_messages {
        match MessagesDetector::get_active_contact() {
            Ok(Some(contact_name)) => {
                debug!(
                    "Captured Messages contact at recording start: {}",
                    contact_name
                );
                *handle.captured_contact.lock() = Some(contact_name);
            }
            Ok(None) => {
                debug!("Messages active but no conversation detected at recording start");
                *handle.captured_contact.lock() = None;
            }
            Err(e) => {
                debug!(
                    "Failed to capture Messages contact at recording start: {}",
                    e
                );
                *handle.captured_contact.lock() = None;
            }
        }
    } else {
        *handle.captured_contact.lock() = None;
    }

    let mut audio_lock = handle.audio.lock();

    // create new audio capture if needed
    if audio_lock.is_none() {
        match AudioCapture::new() {
            Ok(capture) => *audio_lock = Some(capture),
            Err(e) => {
                let message = format!("Failed to create audio capture: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
        }
    }

    if let Some(ref mut capture) = *audio_lock {
        match capture.start() {
            Ok(_) => {
                clear_last_error(handle);
                true
            }
            Err(e) => {
                let message = format!("Failed to start recording: {e}");
                error!("{message}");
                set_last_error(handle, message);
                false
            }
        }
    } else {
        set_last_error(handle, "Audio capture unavailable");
        false
    }
}

/// Stop audio recording and get the duration
///
/// This function extracts audio data and fully releases the microphone device.
///
/// # Arguments
/// - `handle` - Engine handle
///
/// # Returns
/// Duration in milliseconds, or 0 on failure
#[unsafe(no_mangle)]
pub extern "C" fn flow_stop_recording(handle: *mut FlowHandle) -> u64 {
    let handle = unsafe { &*handle };
    let mut audio_lock = handle.audio.lock();

    // Take ownership of AudioCapture (removes it from the Option)
    // This causes it to be dropped after this block, releasing the CPAL device
    if let Some(mut capture) = audio_lock.take() {
        let duration = capture.buffer_duration_ms();

        match capture.stop_stream() {
            Ok(_) => {
                // Extract and cache audio data before dropping AudioCapture
                let sample_rate = capture.sample_rate();
                let audio_data = capture.take_buffered_audio();

                *handle.pending_audio.lock() = Some(audio_data);
                *handle.pending_sample_rate.lock() = Some(sample_rate);

                // AudioCapture is dropped here - CPAL device fully released
                drop(capture);

                clear_last_error(handle);
                duration
            }
            Err(e) => {
                let message = format!("Failed to stop recording: {e}");
                error!("{message}");
                set_last_error(handle, message);

                // Still drop capture even on error
                drop(capture);
                0
            }
        }
    } else {
        set_last_error(handle, "Audio capture unavailable");
        0
    }
}

/// Check if currently recording
#[unsafe(no_mangle)]
pub extern "C" fn flow_is_recording(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };
    let audio_lock = handle.audio.lock();

    if let Some(ref capture) = *audio_lock {
        capture.state() == CaptureState::Recording
    } else {
        false
    }
}

/// Get current audio level (RMS amplitude) from the recording
/// Returns a value between 0.0 and 1.0, or 0.0 if not recording
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_audio_level(handle: *mut FlowHandle) -> f32 {
    let handle = unsafe { &*handle };
    let audio_lock = handle.audio.lock();

    if let Some(ref capture) = *audio_lock {
        if capture.state() == CaptureState::Recording {
            capture.current_audio_level()
        } else {
            0.0
        }
    } else {
        0.0
    }
}

// ============ Transcription ============

fn transcribe_with_audio(
    handle: &FlowHandle,
    audio_data: crate::AudioData,
    sample_rate: u32,
    app_name: Option<String>,
    on_delta: Option<crate::providers::DictationDelta>,
    final_transcript: Option<String>,
) -> crate::error::Result<String> {
    *handle.pending_attachment.lock() = None;
    let captured = handle.captured_contact.lock().clone();
    let (mode, recipient) = resolve_recipient(handle, app_name.as_deref(), captured.as_deref());
    let category = style::category_key(recipient, Some(handle.app_tracker.current_category()));
    let contact = recipient_contact_key(recipient, captured.as_deref());

    let transcription_provider = Arc::clone(&handle.transcription);
    let app_context = handle.app_tracker.current_app();

    // Check if using local transcription
    let use_local_transcription = handle
        .storage
        .get_setting(SETTING_USE_LOCAL_TRANSCRIPTION)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(false);

    let format_context = format_context(app_name.as_deref(), recipient);
    let personalization = personalization_for(handle, "", &category, &contact);
    let auto_rewriting_enabled = handle
        .storage
        .get_setting(SETTING_AUTO_REWRITING_ENABLED)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(true);

    // Local Whisper ignores these params, but cloud fallback still needs them.
    // The worker receives an explicit switch so raw dictation works in Auto mode.
    let completion_params = Some(TranscriptionCompletionParams {
        stable_prefix: handle.live_rewrite.lock().take().filter(|cached|
            cached.app == app_name && cached.contact == captured && cached.mode == mode.worker_name()
        ).map(|cached| cached.prefix),
        mode: mode.worker_name().to_string(),
        app_context: format_context.clone(),
        shortcuts_triggered: Vec::new(),
        attachment_commands_enabled: uses_worker(&handle.storage) && !use_local_transcription,
        shortcut_definitions: handle.shortcuts.get_all().into_iter().map(|s| crate::providers::ShortcutDefinition {
            trigger: s.trigger, replacement: s.replacement, case_sensitive: s.case_sensitive,
        }).collect(),
        voice_instruction: None,
        personalization: if auto_rewriting_enabled {
            personalization
        } else {
            None
        },
        auto_rewriting_enabled,
    });

    // Perform transcription
    let transcription = handle.runtime.block_on(async {
        let mut request = TranscriptionRequest::new(audio_data, sample_rate);
        request.final_transcript = final_transcript;
        if let Some(params) = completion_params {
            request = request.with_completion(params);
        }
        if let Some(callback) = on_delta.clone() {
            transcription_provider.transcribe_stream(request, callback).await
        } else {
            transcription_provider.transcribe(request).await
        }
    })?;

    // Process shortcuts (always applied) and corrections (only if auto-rewriting enabled)
    let (text_with_shortcuts, triggered) = handle.shortcuts.process(&transcription.text);

    let (text_with_corrections, _) = if auto_rewriting_enabled {
        handle.learning.apply_corrections(&text_with_shortcuts)
    } else {
        (text_with_shortcuts.clone(), Vec::new())
    };

    // Determine final processed text based on auto-rewriting setting
    let processed_text = if !auto_rewriting_enabled {
        // Auto-rewriting disabled: return transcription with shortcuts only (no corrections, no AI)
        log_with_time!(
            "📝 [RUST] Auto-rewriting disabled - returning text with shortcuts only: {} chars",
            text_with_shortcuts.len()
        );
        if transcription.attachment.is_some() { transcription.completed_text.clone().unwrap_or(text_with_shortcuts) } else { text_with_shortcuts }
    } else if let Some(completed_text) = transcription.completed_text {
        // Worker completion available (cloud mode with auto-rewriting)
        log_with_time!(
            "✅ [RUST/AI] Worker completion received - Output: {} chars",
            completed_text.len()
        );
        completed_text
    } else if !use_local_transcription && handle.completion.is_configured() {
        // Cloud transcription without a worker (e.g. OpenAI Whisper) - run the
        // completion provider ourselves so the writing mode is actually applied
        let mut request = CompletionRequest::new(text_with_corrections.clone(), mode);
        if let Some(ref context) = format_context {
            request = request.with_app_context(context.clone());
        }
        if let Some(personalization) =
            personalization_for(handle, &text_with_corrections, &category, &contact)
        {
            request = request.with_personalization(personalization);
        }
        let completion_provider = Arc::clone(&handle.completion);
        match handle
            .runtime
            .block_on(async { completion_provider.complete(request).await })
        {
            Ok(response) => {
                log_with_time!(
                    "✅ [RUST/AI] Completion ({:?} mode) - Output: {} chars",
                    mode,
                    response.text.len()
                );
                response.text
            }
            Err(e) => {
                log_with_time!("⚠️ [RUST/AI] Completion failed, using raw text: {}", e);
                text_with_corrections.clone()
            }
        }
    } else {
        // Local transcription mode or cloud without completion - apply corrections
        let (text_with_corrections, _applied) =
            handle.learning.apply_corrections(&text_with_shortcuts);
        log_with_time!(
            "📝 [RUST] Local transcription mode - using corrected text: {} chars",
            text_with_corrections.len()
        );
        text_with_corrections
    };

    // Suppress unused warning for triggered shortcuts (used by worker)
    let _ = triggered;

    // Cancellation never promotes a partial response into history or learning.
    if on_delta.as_ref().is_some_and(|callback| !callback("")) {
        return Err(crate::error::Error::Transcription("Dictation cancelled".into()));
    }

    let mut record = Transcription::new(
        transcription.text,
        processed_text.clone(),
        transcription.confidence.unwrap_or(0.0),
        transcription.duration_ms,
    );
    if let Some(context) = app_context {
        record.app_context = Some(context);
    }
    if let Err(e) = handle.storage.save_transcription(&record) {
        error!("Failed to save transcription: {}", e);
    }

    let mut history = TranscriptionHistoryEntry::success(
        record.raw_text.clone(),
        processed_text.clone(),
        record.duration_ms,
    );
    history.app_context = record.app_context.clone();
    if let Err(e) = handle.storage.save_history_entry(&history) {
        error!("Failed to save transcription history: {}", e);
    }

    *handle.pending_dictation.lock() = (!processed_text.trim().is_empty()).then(|| PendingDictation {
        category,
        contact_key: contact,
        said: transcription.attachment.as_ref().map(|p| p.message.clone()).unwrap_or_else(|| record.raw_text.clone()),
        flow_output: processed_text.clone(),
    });
    *handle.pending_attachment.lock() = transcription.attachment;

    Ok(processed_text)
}

/// Pick the writing mode for a message, using the Messages contact when there is one
fn resolve_recipient(
    handle: &FlowHandle,
    app_name: Option<&str>,
    contact_name: Option<&str>,
) -> (WritingMode, Option<ContactCategory>) {
    let Some(name) = app_name else {
        return (WritingMode::Casual, None);
    };

    let is_messages = name.to_lowercase().contains("messages") || name == "com.apple.MobileSMS";
    if is_messages && let Some(contact_name) = contact_name {
        let category = handle.contact_classifier.classify(&ContactInput {
            name: contact_name.to_string(),
            organization: String::new(),
        });
        let mode = category.suggested_writing_mode();
        log_with_time!(
            "👤 [RUST] Messages contact classified as {:?}, using {:?} mode",
            category,
            mode
        );
        handle.contact_classifier.record_interaction(contact_name);
        return (mode, Some(category));
    }

    if is_messages {
        log_with_time!("👤 [RUST] No Messages contact captured, using app default mode");
    }
    let mut modes = handle.modes.lock();
    (modes.get_mode_with_storage(name, &handle.storage), None)
}

/// App context sent to the formatter, including who the message is for (category only, never the name)
fn format_context(app_name: Option<&str>, recipient: Option<ContactCategory>) -> Option<String> {
    match (app_name, recipient) {
        (Some(name), Some(category)) => Some(format!(
            "{}, writing to {}",
            name,
            category.recipient_context()
        )),
        (Some(name), None) => Some(name.to_string()),
        (None, _) => None,
    }
}

fn rewrite_strength(storage: &Storage) -> RewriteStrength {
    storage
        .get_setting(SETTING_REWRITE_STRENGTH)
        .ok()
        .flatten()
        .map(|s| RewriteStrength::parse(&s))
        .unwrap_or_default()
}

/// Contact key for the person a Messages dictation is for, empty otherwise
fn recipient_contact_key(recipient: Option<ContactCategory>, contact_name: Option<&str>) -> String {
    match (recipient, contact_name) {
        (Some(_), Some(name)) => style::contact_key(name),
        _ => String::new(),
    }
}

/// Profile, matching examples and rewrite strength for the prompt. None keeps the generic prompt.
fn personalization_for(
    handle: &FlowHandle,
    said: &str,
    category: &str,
    contact: &str,
) -> Option<String> {
    let strength = rewrite_strength(&handle.storage);
    let profile = handle
        .storage
        .get_setting(SETTING_STYLE_PROFILE)
        .ok()
        .flatten();
    let examples = handle
        .storage
        .get_style_examples(STYLE_EXAMPLE_POOL)
        .unwrap_or_default();
    let profile = profile.filter(|p| !p.trim().is_empty());
    let selected = style::select_examples(
        &examples,
        said,
        category,
        contact,
        style::EXAMPLES_PER_REQUEST,
    );
    let habits = style::measure_habits(&examples, category, contact);

    if profile.is_none() && selected.is_empty() && strength == RewriteStrength::Balanced {
        return None;
    }

    let same_person = selected
        .iter()
        .filter(|e| !contact.is_empty() && e.contact_key == contact)
        .count();
    log_with_time!(
        "🎨 [RUST] Personalizing with {} examples ({} from this person), profile: {}, habits: {}, strength: {}",
        selected.len(),
        same_person,
        profile.is_some(),
        habits.is_some(),
        strength.as_str()
    );
    Some(style::build_personalization(
        profile.as_deref(),
        &selected,
        category,
        habits.as_deref(),
        strength,
    ))
}

/// Transcribe the recorded audio and process it
///
/// # Arguments
/// - `handle` - Engine handle
/// - `app_name` - Name of the current app (for mode selection), or NULL
///
/// # Returns
/// Processed text (caller must free with flow_free_string), or NULL on failure
#[unsafe(no_mangle)]
pub extern "C" fn flow_transcribe(handle: *mut FlowHandle, app_name: *const c_char) -> *mut c_char {
    transcribe_pending(handle, app_name, None, None)
}

/// Receives real completion deltas on the transcription thread. Copy strings
/// before returning; return false to cancel. Empty strings check cancellation.
pub type DictationCallback = extern "C" fn(delta: *const c_char, context: *mut c_void) -> bool;

/// Stream formatting output for recorded audio. The returned completed string
/// is owned by the caller and must be released with flow_free_string. Failed or
/// cancelled streams return null and cannot become personalization evidence.
#[unsafe(no_mangle)]
pub extern "C" fn flow_transcribe_stream(
    handle: *mut FlowHandle,
    app_name: *const c_char,
    callback: extern "C" fn(delta: *const c_char, context: *mut c_void) -> bool,
    context: *mut c_void,
) -> *mut c_char {
    let context_address = context as usize;
    let on_delta = Some(Arc::new(move |delta: &str| {
        let Ok(delta) = CString::new(delta) else { return false; };
        callback(delta.as_ptr(), context_address as *mut c_void)
    }) as crate::providers::DictationDelta);
    transcribe_pending(handle, app_name, on_delta, None)
}

/// Format finalized real-time ASR through the recorded-audio pipeline. Stop
/// recording first. Preserves recipient context, attachment parsing, history,
/// retry audio and send-only learning. NULL uses the normal audio ASR fallback.
/// Only cloud Auto supports this path; no partial transcript is accepted.
#[unsafe(no_mangle)]
pub extern "C" fn flow_transcribe_realtime_stream(
    handle: *mut FlowHandle,
    app_name: *const c_char,
    final_transcript: *const c_char,
    callback: extern "C" fn(delta: *const c_char, context: *mut c_void) -> bool,
    context: *mut c_void,
) -> *mut c_char {
    if handle.is_null() { return ptr::null_mut(); }
    let engine = unsafe { &*handle };
    let transcript = c_str(final_transcript).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned);
    if transcript.as_ref().is_some_and(|s| s.chars().count() > 5000) {
        set_last_error(engine, "Real-time transcript exceeds 5000 characters"); return ptr::null_mut();
    }
    if transcript.is_some() && (!uses_worker(&engine.storage) ||
        engine.storage.get_setting(SETTING_USE_LOCAL_TRANSCRIPTION).ok().flatten().as_deref() == Some("true")) {
        set_last_error(engine, "Real-time transcription requires cloud Auto mode"); return ptr::null_mut();
    }
    let context_address = context as usize;
    let on_delta = Some(Arc::new(move |delta: &str| {
        let Ok(delta) = CString::new(delta) else { return false; };
        callback(delta.as_ptr(), context_address as *mut c_void)
    }) as crate::providers::DictationDelta);
    transcribe_pending(handle, app_name, on_delta, transcript)
}

/// Speculative formatting only: does not stop capture, consume audio, save
/// history, stage attachments or make a draft learnable. Final dictation must
/// still validate the complete recording through the normal pipeline.
#[unsafe(no_mangle)]
pub extern "C" fn flow_preview_rewrite_stream(
    handle: *mut FlowHandle,
    text: *const c_char,
    app_name: *const c_char,
    callback: extern "C" fn(delta: *const c_char, context: *mut c_void) -> bool,
    context: *mut c_void,
) -> *mut c_char {
    if handle.is_null() { return ptr::null_mut(); }
    let engine = unsafe { &*handle };
    let epoch = engine.live_rewrite_epoch.load(Ordering::SeqCst);
    let Some(text) = c_str(text).map(str::trim).filter(|s| !s.is_empty() && s.chars().count() <= 5000) else { return ptr::null_mut(); };
    if !uses_worker(&engine.storage) || engine.storage.get_setting(SETTING_USE_LOCAL_TRANSCRIPTION).ok().flatten().as_deref() == Some("true") { return ptr::null_mut(); }
    let app = c_str(app_name);
    let captured = engine.captured_contact.lock().clone();
    let recipient = if app.is_some_and(|s| s.to_lowercase().contains("messages") || s == "com.apple.MobileSMS") {
        captured.as_ref().map(|name| engine.contact_classifier.classify(&ContactInput { name: name.clone(), organization: String::new() }))
    } else { None };
    let mode = recipient.map(|r| r.suggested_writing_mode()).unwrap_or_else(|| engine.modes.lock().get_mode_with_storage(app.unwrap_or(""), &engine.storage));
    let category = style::category_key(recipient, Some(engine.app_tracker.current_category()));
    let contact = recipient_contact_key(recipient, captured.as_deref());
    let params = TranscriptionCompletionParams {
        stable_prefix: None,
        mode: mode.worker_name().into(), app_context: format_context(app, recipient),
        shortcuts_triggered: Vec::new(),
        shortcut_definitions: engine.shortcuts.get_all().into_iter().map(|s| crate::providers::ShortcutDefinition {
            trigger: s.trigger, replacement: s.replacement, case_sensitive: s.case_sensitive,
        }).collect(),
        attachment_commands_enabled: true, voice_instruction: None,
        personalization: personalization_for(engine, text, &category, &contact),
        auto_rewriting_enabled: engine.storage.get_setting(SETTING_AUTO_REWRITING_ENABLED).ok().flatten().as_deref() != Some("false"),
    };
    let mut request = TranscriptionRequest::new(Vec::new(), 16000).with_completion(params);
    request.final_transcript = Some(text.into()); // Typed preview; never promoted to final ASR.
    let address = context as usize;
    let on_delta = Arc::new(move |delta: &str| {
        let Ok(delta) = CString::new(delta) else { return false; };
        callback(delta.as_ptr(), address as *mut c_void)
    }) as crate::providers::DictationDelta;
    match engine.runtime.block_on(engine.transcription.transcribe_stream(request, on_delta)) {
        Ok(response) => {
            let Some(output) = response.completed_text.filter(|s| !s.trim().is_empty()) else { return ptr::null_mut(); };
            let finished_sentence = text.trim_end_matches(|c: char| c.is_whitespace() || ['"', '”', '’', '\''].contains(&c))
                .ends_with(['.', '!', '?']);
            if !finished_sentence { return into_c_string(output); }
            let mut cached = engine.live_rewrite.lock();
            if engine.live_rewrite_epoch.load(Ordering::SeqCst) != epoch { return into_c_string(output); }
            if let Some(previous) = cached.as_mut().filter(|c|
                c.app.as_deref() == app && c.contact == captured && c.mode == mode.worker_name()) {
                previous.prefix.source.push(' '); previous.prefix.source.push_str(text);
                previous.prefix.output.push(' '); previous.prefix.output.push_str(output.trim());
                if previous.prefix.source.chars().count() > 5000 || previous.prefix.output.chars().count() > 12000 { *cached = None; }
            } else {
                *cached = Some(LiveRewritePrefix { app: app.map(str::to_owned), contact: captured,
                    mode: mode.worker_name().into(), prefix: crate::providers::StableRewritePrefix {
                        source: text.into(), output: output.trim().into() } });
            }
            into_c_string(output)
        },
        Err(_) => ptr::null_mut(), // Preview failure must not overwrite final pipeline errors.
    }
}

/// Process supplied mono signed PCM16 through the normal streaming pipeline.
/// The host must serialize transcription calls for this handle. Audio is copied
/// before processing. This supports imported recordings and isolated simulations.
#[unsafe(no_mangle)]
pub extern "C" fn flow_transcribe_audio_stream(
    handle: *mut FlowHandle,
    pcm: *const u8,
    byte_count: usize,
    sample_rate: u32,
    app_name: *const c_char,
    contact_name: *const c_char,
    callback: extern "C" fn(delta: *const c_char, context: *mut c_void) -> bool,
    context: *mut c_void,
) -> *mut c_char {
    flow_transcribe_audio_realtime_stream(handle, pcm, byte_count, sample_rate, app_name, contact_name, ptr::null(), callback, context)
}

/// Imported audio plus finalized real-time ASR. Same limits, context and learning
/// as microphone dictation; NULL transcript retains recorded-audio fallback.
#[unsafe(no_mangle)]
pub extern "C" fn flow_transcribe_audio_realtime_stream(
    handle: *mut FlowHandle,
    pcm: *const u8,
    byte_count: usize,
    sample_rate: u32,
    app_name: *const c_char,
    contact_name: *const c_char,
    final_transcript: *const c_char,
    callback: extern "C" fn(delta: *const c_char, context: *mut c_void) -> bool,
    context: *mut c_void,
) -> *mut c_char {
    if handle.is_null() { return ptr::null_mut(); }
    let engine = unsafe { &*handle };
    if pcm.is_null() || byte_count == 0 || byte_count % 2 != 0 ||
       !(8000..=192000).contains(&sample_rate) || byte_count > sample_rate as usize * 2 * 300 {
        set_last_error(engine, "Expected up to five minutes of mono PCM16 audio at 8–192 kHz");
        return ptr::null_mut();
    }
    if engine.audio.lock().is_some() {
        set_last_error(engine, "Stop microphone recording before processing supplied audio");
        return ptr::null_mut();
    }
    *engine.pending_audio.lock() = Some(unsafe { std::slice::from_raw_parts(pcm, byte_count) }.to_vec());
    *engine.pending_sample_rate.lock() = Some(sample_rate);
    *engine.captured_contact.lock() = c_str(contact_name).map(str::to_owned);
    flow_transcribe_realtime_stream(handle, app_name, final_transcript, callback, context)
}

fn transcribe_pending(handle: *mut FlowHandle, app_name: *const c_char, on_delta: Option<crate::providers::DictationDelta>, final_transcript: Option<String>) -> *mut c_char {
    if handle.is_null() { return ptr::null_mut(); }
    let handle = unsafe { &*handle };

    // Get cached audio data (don't touch handle.audio at all)
    // This ensures the microphone device was already released by flow_stop_recording
    let (audio_data, sample_rate) = {
        let audio_data = handle.pending_audio.lock().take();
        let sample_rate = handle.pending_sample_rate.lock().take();

        match (audio_data, sample_rate) {
            (Some(data), Some(rate)) => (data, rate),
            _ => {
                set_last_error(
                    handle,
                    "No audio data pending - must call stop_recording first",
                );
                return ptr::null_mut();
            }
        }
    };

    if audio_data.is_empty() {
        set_last_error(handle, "No audio captured");
        return ptr::null_mut();
    }

    // get app name
    let app = if !app_name.is_null() {
        unsafe { CStr::from_ptr(app_name) }
            .to_str()
            .ok()
            .map(String::from)
    } else {
        None
    };

    let duration_ms = estimate_duration_ms(audio_data.len(), sample_rate);
    *handle.last_audio.lock() = Some(audio_data.clone());
    *handle.last_audio_sample_rate.lock() = Some(sample_rate);
    let result = transcribe_with_audio(handle, audio_data, sample_rate, app, on_delta, final_transcript);

    // Clear the captured contact after transcription (whether success or failure)
    *handle.captured_contact.lock() = None;

    match result {
        Ok(text) => {
            clear_last_error(handle);
            *handle.last_audio.lock() = None;
            *handle.last_audio_sample_rate.lock() = None;
            match CString::new(text) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        Err(e) => {
            let message = format!("Transcription failed: {e}");
            error!("{message}");
            set_last_error(handle, message.clone());
            let mut history = TranscriptionHistoryEntry::failure(message, duration_ms);
            history.app_context = handle.app_tracker.current_app();
            if let Err(e) = handle.storage.save_history_entry(&history) {
                error!("Failed to save transcription history: {}", e);
            }
            ptr::null_mut()
        }
    }
}

/// Retry the last transcription using cached audio
/// Returns processed text (caller must free with flow_free_string), or null on failure
#[unsafe(no_mangle)]
pub extern "C" fn flow_retry_last_transcription(
    handle: *mut FlowHandle,
    app_name: *const c_char,
) -> *mut c_char {
    let handle = unsafe { &*handle };
    let (audio_data, sample_rate) = {
        let last_audio = handle.last_audio.lock();
        let last_sample_rate = handle.last_audio_sample_rate.lock();
        match last_audio.as_ref() {
            Some(data) => (data.clone(), last_sample_rate.unwrap_or(16_000)),
            None => {
                set_last_error(handle, "No previous recording to retry");
                return ptr::null_mut();
            }
        }
    };

    let app = if !app_name.is_null() {
        unsafe { CStr::from_ptr(app_name) }
            .to_str()
            .ok()
            .map(String::from)
    } else {
        None
    };

    let duration_ms = estimate_duration_ms(audio_data.len(), sample_rate);
    let result = transcribe_with_audio(handle, audio_data, sample_rate, app, None, None);

    match result {
        Ok(text) => {
            clear_last_error(handle);
            *handle.last_audio.lock() = None;
            *handle.last_audio_sample_rate.lock() = None;
            match CString::new(text) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        Err(e) => {
            let message = format!("Transcription failed: {e}");
            error!("{message}");
            set_last_error(handle, message.clone());
            let mut history = TranscriptionHistoryEntry::failure(message, duration_ms);
            history.app_context = handle.app_tracker.current_app();
            if let Err(e) = handle.storage.save_history_entry(&history) {
                error!("Failed to save transcription history: {}", e);
            }
            ptr::null_mut()
        }
    }
}

// ============ Shortcuts ============

/// Add a voice shortcut
///
/// # Arguments
/// - `handle` - Engine handle
/// - `trigger` - Trigger phrase
/// - `replacement` - Replacement text
///
/// # Returns
/// true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_add_shortcut(
    handle: *mut FlowHandle,
    trigger: *const c_char,
    replacement: *const c_char,
) -> bool {
    if trigger.is_null() || replacement.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };

    let trigger_str = match unsafe { CStr::from_ptr(trigger) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return false,
    };

    let replacement_str = match unsafe { CStr::from_ptr(replacement) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return false,
    };

    let shortcut = Shortcut::new(trigger_str, replacement_str);

    if let Err(e) = handle.storage.save_shortcut(&shortcut) {
        error!("Failed to save shortcut: {}", e);
        return false;
    }

    handle.shortcuts.add_shortcut(shortcut);
    true
}

/// Remove a voice shortcut
/// Returns true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_remove_shortcut(handle: *mut FlowHandle, trigger: *const c_char) -> bool {
    if trigger.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };

    let trigger_str = match unsafe { CStr::from_ptr(trigger) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    handle.shortcuts.remove_shortcut(trigger_str);
    true
}

/// Get the number of shortcuts
#[unsafe(no_mangle)]
pub extern "C" fn flow_shortcut_count(handle: *mut FlowHandle) -> usize {
    let handle = unsafe { &*handle };
    handle.shortcuts.count()
}

// ============ Writing Modes ============

/// Set the writing mode for an app
///
/// # Arguments
/// - `handle` - Engine handle
/// - `app_name` - Name of the app
/// - `mode` - Writing mode (0=Formal, 1=Casual, 2=VeryCasual, 3=Excited)
///
/// # Returns
/// true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_app_mode(
    handle: *mut FlowHandle,
    app_name: *const c_char,
    mode: u8,
) -> bool {
    if app_name.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };

    let app = match unsafe { CStr::from_ptr(app_name) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let writing_mode = match mode {
        0 => WritingMode::Formal,
        1 => WritingMode::Casual,
        2 => WritingMode::VeryCasual,
        3 => WritingMode::Excited,
        _ => return false,
    };

    let mut modes = handle.modes.lock();
    if let Err(e) = modes.set_mode_with_storage(app, writing_mode, &handle.storage) {
        error!("Failed to save app mode: {}", e);
        return false;
    }

    true
}

/// Get the writing mode for an app
/// Returns: 0 = Formal, 1 = Casual, 2 = VeryCasual, 3 = Excited
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_app_mode(handle: *mut FlowHandle, app_name: *const c_char) -> u8 {
    if app_name.is_null() {
        return 1; // default to casual
    }

    let handle = unsafe { &*handle };

    let app = match unsafe { CStr::from_ptr(app_name) }.to_str() {
        Ok(s) => s,
        Err(_) => return 1,
    };

    let mut modes = handle.modes.lock();
    let mode = modes.get_mode_with_storage(app, &handle.storage);

    match mode {
        WritingMode::Formal => 0,
        WritingMode::Casual => 1,
        WritingMode::VeryCasual => 2,
        WritingMode::Excited => 3,
    }
}

// ============ Learning ============

/// Report a user edit to learn from
///
/// # Arguments
/// - `handle` - Engine handle
/// - `original` - Original transcribed text
/// - `edited` - Text after user edits
///
/// # Returns
/// true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_learn_from_edit(
    handle: *mut FlowHandle,
    original: *const c_char,
    edited: *const c_char,
) -> bool {
    if original.is_null() || edited.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };

    let original_str = match unsafe { CStr::from_ptr(original) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let edited_str = match unsafe { CStr::from_ptr(edited) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    match handle
        .learning
        .learn_from_edit(original_str, edited_str, &handle.storage)
    {
        Ok(learned) => {
            debug!("Learned {} corrections from edit", learned.len());
            true
        }
        Err(e) => {
            error!("Failed to learn from edit: {}", e);
            false
        }
    }
}

/// Get the number of learned corrections
#[unsafe(no_mangle)]
pub extern "C" fn flow_correction_count(handle: *mut FlowHandle) -> usize {
    let handle = unsafe { &*handle };
    handle.learning.cache_size()
}

/// Get all corrections as JSON
/// Returns JSON array: [{"id": "...", "original": "...", "corrected": "...", "occurrences": N, "confidence": N.N}, ...]
/// Caller must free the returned string with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_corrections_json(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };

    let corrections = match handle.storage.get_all_corrections() {
        Ok(c) => c,
        Err(e) => {
            error!("Failed to get corrections: {}", e);
            return ptr::null_mut();
        }
    };

    let json_array: Vec<serde_json::Value> = corrections
        .into_iter()
        .map(|c| {
            serde_json::json!({
                "id": c.id.to_string(),
                "original": c.original,
                "corrected": c.corrected,
                "occurrences": c.occurrences,
                "confidence": c.confidence,
                "source": format!("{:?}", c.source),
                "created_at": c.created_at.to_rfc3339(),
                "updated_at": c.updated_at.to_rfc3339(),
            })
        })
        .collect();

    match CString::new(serde_json::to_string(&json_array).unwrap_or_default()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Delete a correction by ID
/// Returns true if the correction was deleted, false if not found or on error
#[unsafe(no_mangle)]
pub extern "C" fn flow_delete_correction(handle: *mut FlowHandle, id: *const c_char) -> bool {
    if id.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };

    let id_str = match unsafe { CStr::from_ptr(id) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let uuid = match uuid::Uuid::parse_str(id_str) {
        Ok(u) => u,
        Err(_) => {
            error!("Invalid UUID: {}", id_str);
            return false;
        }
    };

    // First, get the correction to find the original word (for cache removal)
    if let Ok(corrections) = handle.storage.get_all_corrections() {
        if let Some(correction) = corrections.iter().find(|c| c.id == uuid) {
            let original = correction.original.clone();

            // Delete from storage
            match handle.storage.delete_correction(&uuid) {
                Ok(deleted) => {
                    if deleted {
                        // Remove from cache
                        handle.learning.remove_from_cache(&original);
                        debug!(
                            "Deleted correction: {} -> {}",
                            original, correction.corrected
                        );
                    }
                    deleted
                }
                Err(e) => {
                    error!("Failed to delete correction: {}", e);
                    false
                }
            }
        } else {
            false
        }
    } else {
        false
    }
}

/// Delete all corrections
/// Returns the number of corrections deleted
#[unsafe(no_mangle)]
pub extern "C" fn flow_delete_all_corrections(handle: *mut FlowHandle) -> usize {
    let handle = unsafe { &*handle };

    match handle.storage.delete_all_corrections() {
        Ok(count) => {
            // Clear the cache
            handle.learning.clear_cache();
            debug!("Deleted all {} corrections", count);
            count
        }
        Err(e) => {
            error!("Failed to delete all corrections: {}", e);
            0
        }
    }
}

/// Validate corrections using AI (async, returns JSON)
/// Input: JSON array of {"original": "...", "corrected": "..."} pairs
/// Output: JSON array of {"original": "...", "corrected": "...", "valid": bool, "reason": "..."}
/// Caller must free the returned string with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_validate_corrections(
    _handle: *mut FlowHandle,
    corrections_json: *const c_char,
) -> *mut c_char {
    if corrections_json.is_null() {
        return ptr::null_mut();
    }

    let json_str = match unsafe { CStr::from_ptr(corrections_json) }.to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    // Parse input JSON
    let pairs: Vec<crate::providers::CorrectionPair> = match serde_json::from_str(json_str) {
        Ok(p) => p,
        Err(e) => {
            error!("Failed to parse corrections JSON: {}", e);
            return ptr::null_mut();
        }
    };

    // Run async validation
    let runtime = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            error!("Failed to create tokio runtime: {}", e);
            return ptr::null_mut();
        }
    };

    let results = match runtime.block_on(crate::providers::validate_corrections(pairs)) {
        Ok(r) => r,
        Err(e) => {
            error!("Validation failed: {}", e);
            return ptr::null_mut();
        }
    };

    // Return as JSON
    match CString::new(serde_json::to_string(&results).unwrap_or_default()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

// ============ Stats ============

/// Get total transcription time in minutes
#[unsafe(no_mangle)]
pub extern "C" fn flow_total_transcription_minutes(handle: *mut FlowHandle) -> u64 {
    let handle = unsafe { &*handle };
    handle
        .storage
        .get_total_transcription_time_ms()
        .unwrap_or(0)
        / 60000
}

/// Get total transcription count
#[unsafe(no_mangle)]
pub extern "C" fn flow_transcription_count(handle: *mut FlowHandle) -> u64 {
    let handle = unsafe { &*handle };
    handle.storage.get_transcription_count().unwrap_or(0)
}

// ============ Utilities ============

/// Free a string returned by flow functions
#[unsafe(no_mangle)]
pub extern "C" fn flow_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// Check if the transcription provider is configured
#[unsafe(no_mangle)]
pub extern "C" fn flow_is_configured(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };

    // Auto provider handles both transcription and completion internally via the worker,
    // so we don't need a separate completion provider configured
    if handle.transcription.name() == "Auto (Cloud)" {
        return handle.transcription.is_configured();
    }

    handle.transcription.is_configured() && handle.completion.is_configured()
}

// ============ App Tracking ============

/// Set the currently active app (call from Swift when app switches)
/// Returns the suggested writing mode for the app
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_active_app(
    handle: *mut FlowHandle,
    app_name: *const c_char,
    bundle_id: *const c_char,
    window_title: *const c_char,
) -> u8 {
    if app_name.is_null() {
        return 1; // default to casual
    }

    let handle = unsafe { &*handle };

    let name = match unsafe { CStr::from_ptr(app_name) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return 1,
    };

    let bid = if bundle_id.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(bundle_id) }
            .to_str()
            .ok()
            .map(String::from)
    };

    let title = if window_title.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(window_title) }
            .to_str()
            .ok()
            .map(String::from)
    };

    let _context = handle.app_tracker.set_active_app(name, bid, title);

    // return suggested mode
    match handle.app_tracker.suggested_mode() {
        WritingMode::Formal => 0,
        WritingMode::Casual => 1,
        WritingMode::VeryCasual => 2,
        WritingMode::Excited => 3,
    }
}

/// Get the current app's category
/// Returns: 0=Email, 1=Slack, 2=Code, 3=Documents, 4=Social, 5=Browser, 6=Terminal, 7=Unknown
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_app_category(handle: *mut FlowHandle) -> u8 {
    let handle = unsafe { &*handle };

    use crate::types::AppCategory;
    match handle.app_tracker.current_category() {
        AppCategory::Email => 0,
        AppCategory::Slack => 1,
        AppCategory::Code => 2,
        AppCategory::Documents => 3,
        AppCategory::Social => 4,
        AppCategory::Browser => 5,
        AppCategory::Terminal => 6,
        AppCategory::Unknown => 7,
    }
}

/// Get current app name (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_current_app(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };

    match handle.app_tracker.current_app() {
        Some(ctx) => match CString::new(ctx.app_name) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => ptr::null_mut(),
        },
        None => ptr::null_mut(),
    }
}

// ============ Style Learning ============

/// Report edited text to learn user's style for current app
#[unsafe(no_mangle)]
pub extern "C" fn flow_learn_style(handle: *mut FlowHandle, edited_text: *const c_char) -> bool {
    if edited_text.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };

    let text = match unsafe { CStr::from_ptr(edited_text) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let app_name = match handle.app_tracker.current_app() {
        Some(ctx) => ctx.app_name,
        None => return false,
    };

    let mut learner = handle.style_learner.lock();
    learner.observe_with_storage(&app_name, text, &handle.storage);

    true
}

/// Get suggested mode based on learned style for current app
/// Returns: 0=Formal, 1=Casual, 2=VeryCasual, 3=Excited, 255=no suggestion
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_style_suggestion(handle: *mut FlowHandle) -> u8 {
    let handle = unsafe { &*handle };

    let app_name = match handle.app_tracker.current_app() {
        Some(ctx) => ctx.app_name,
        None => return 255,
    };

    let learner = handle.style_learner.lock();
    match learner.suggest_mode(&app_name) {
        Some(suggestion) => match suggestion.suggested_mode {
            WritingMode::Formal => 0,
            WritingMode::Casual => 1,
            WritingMode::VeryCasual => 2,
            WritingMode::Excited => 3,
        },
        None => 255,
    }
}

// ============ Extended Stats ============

/// Get user stats as JSON (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_stats_json(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };

    let stats = serde_json::json!({
        "total_transcriptions": handle.storage.get_transcription_count().unwrap_or(0),
        "total_duration_ms": handle.storage.get_total_transcription_time_ms().unwrap_or(0),
        "total_words_dictated": handle.storage.get_total_words_dictated().unwrap_or(0),
        "shortcut_count": handle.shortcuts.count(),
        "correction_count": handle.learning.cache_size(),
    });

    match CString::new(stats.to_string()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Get recent transcriptions as JSON (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_recent_transcriptions_json(
    handle: *mut FlowHandle,
    limit: usize,
) -> *mut c_char {
    let handle = unsafe { &*handle };
    let transcriptions = match handle.storage.get_recent_history(limit) {
        Ok(items) => items,
        Err(e) => {
            error!("Failed to load transcriptions: {}", e);
            return ptr::null_mut();
        }
    };

    let summaries: Vec<TranscriptionSummary> = transcriptions
        .into_iter()
        .map(|item| TranscriptionSummary {
            id: item.id.to_string(),
            status: item.status,
            text: item.text,
            raw_text: item.raw_text,
            error: item.error,
            duration_ms: item.duration_ms,
            created_at: item.created_at.to_rfc3339(),
            app_name: item.app_context.map(|ctx| ctx.app_name),
        })
        .collect();

    let json = match serde_json::to_string(&summaries) {
        Ok(value) => value,
        Err(e) => {
            error!("Failed to serialize transcriptions: {}", e);
            return ptr::null_mut();
        }
    };

    match CString::new(json) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Get the last error message (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_last_error(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };
    let message = handle.last_error.lock().clone();
    match message {
        Some(text) => match CString::new(text) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => ptr::null_mut(),
        },
        None => ptr::null_mut(),
    }
}

// ============ Provider Configuration ============

/// Switch completion provider (loads API key from database)
/// provider: 0 = OpenAI, 1 = Gemini, 2 = OpenRouter
/// Returns true if provider was switched successfully
#[unsafe(no_mangle)]
pub extern "C" fn flow_switch_completion_provider(handle: *mut FlowHandle, provider: u8) -> bool {
    let handle = unsafe { &mut *handle };

    let (setting_key, provider_name) = match provider {
        0 => (SETTING_OPENAI_API_KEY, "openai"),
        1 => (SETTING_GEMINI_API_KEY, "gemini"),
        2 => (SETTING_OPENROUTER_API_KEY, "openrouter"),
        _ => {
            set_last_error(handle, "Invalid provider");
            return false;
        }
    };

    // Load the API key from the database
    let api_key = match handle.storage.get_setting(setting_key) {
        Ok(Some(key)) if !key.is_empty() => key,
        Ok(Some(_)) | Ok(None) => {
            let message = format!("No API key configured for {}", provider_name);
            error!("{message}");
            set_last_error(handle, message);
            return false;
        }
        Err(e) => {
            let message = format!("Failed to load API key for {}: {}", provider_name, e);
            error!("{message}");
            set_last_error(handle, message);
            return false;
        }
    };

    // Save the provider preference
    if let Err(e) = handle
        .storage
        .set_setting(SETTING_COMPLETION_PROVIDER, provider_name)
    {
        let message = format!("Failed to save completion provider: {e}");
        error!("{message}");
        set_last_error(handle, message);
        return false;
    }

    // Initialize the provider
    match provider {
        0 => {
            let base_url = handle
                .storage
                .get_setting(SETTING_OPENAI_BASE_URL)
                .ok()
                .flatten()
                .filter(|s| !s.is_empty());
            handle.transcription = Arc::new(OpenAITranscriptionProvider::new(
                Some(api_key.clone()),
                base_url.clone(),
            ));
            handle.completion = Arc::new(OpenAICompletionProvider::new(Some(api_key), base_url));
            debug!("Switched completion provider to OpenAI");
        }
        1 => {
            handle.transcription =
                Arc::new(GeminiTranscriptionProvider::new(Some(api_key.clone())));
            handle.completion = Arc::new(GeminiCompletionProvider::new(Some(api_key)));
            debug!("Switched completion provider to Gemini");
        }
        2 => {
            // OpenRouter only handles completion, keep existing transcription provider
            handle.completion = Arc::new(OpenRouterCompletionProvider::new(Some(api_key)));
            debug!("Switched completion provider to OpenRouter");
        }
        _ => unreachable!(),
    }

    clear_last_error(handle);
    true
}

/// Set completion provider with API key (saves both)
/// provider: 0 = OpenAI, 1 = Gemini, 2 = OpenRouter
/// api_key: The API key for the provider
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_completion_provider(
    handle: *mut FlowHandle,
    provider: u8,
    api_key: *const c_char,
) -> bool {
    if api_key.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };

    let key = match unsafe { CStr::from_ptr(api_key) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return false,
    };

    match provider {
        0 => {
            if let Err(e) = handle.storage.set_setting(SETTING_OPENAI_API_KEY, &key) {
                let message = format!("Failed to save OpenAI API key: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
            if let Err(e) = handle
                .storage
                .set_setting(SETTING_COMPLETION_PROVIDER, "openai")
            {
                let message = format!("Failed to save completion provider: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
            let base_url = handle
                .storage
                .get_setting(SETTING_OPENAI_BASE_URL)
                .ok()
                .flatten()
                .filter(|s| !s.is_empty());
            handle.transcription = Arc::new(OpenAITranscriptionProvider::new(
                Some(key.clone()),
                base_url.clone(),
            ));
            handle.completion = Arc::new(OpenAICompletionProvider::new(Some(key), base_url));
            debug!("Set completion provider to OpenAI");
        }
        1 => {
            if let Err(e) = handle.storage.set_setting(SETTING_GEMINI_API_KEY, &key) {
                let message = format!("Failed to save Gemini API key: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
            if let Err(e) = handle
                .storage
                .set_setting(SETTING_COMPLETION_PROVIDER, "gemini")
            {
                let message = format!("Failed to save completion provider: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
            handle.transcription = Arc::new(GeminiTranscriptionProvider::new(Some(key.clone())));
            handle.completion = Arc::new(GeminiCompletionProvider::new(Some(key)));
            debug!("Set completion provider to Gemini");
        }
        2 => {
            if let Err(e) = handle.storage.set_setting(SETTING_OPENROUTER_API_KEY, &key) {
                let message = format!("Failed to save OpenRouter API key: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
            if let Err(e) = handle
                .storage
                .set_setting(SETTING_COMPLETION_PROVIDER, "openrouter")
            {
                let message = format!("Failed to save completion provider: {e}");
                error!("{message}");
                set_last_error(handle, message);
                return false;
            }
            // OpenRouter only handles completion, keep transcription provider as-is
            handle.completion = Arc::new(OpenRouterCompletionProvider::new(Some(key)));
            debug!("Set completion provider to OpenRouter");
        }
        _ => return false,
    }

    true
}

/// Get the current completion provider name
/// Returns: 0 = OpenAI, 1 = Gemini, 2 = OpenRouter, 255 = Unknown
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_completion_provider(handle: *mut FlowHandle) -> u8 {
    let handle = unsafe { &*handle };

    match handle.completion.name() {
        "OpenAI GPT" => 0,
        "Gemini" => 1,
        "OpenRouter" => 2,
        _ => 255,
    }
}

/// Helper function to mask an API key for display
/// Shows the prefix (e.g., "sk-" or "AI") and masks the rest with dots
fn mask_api_key(key: &str) -> String {
    if key.is_empty() {
        return String::new();
    }

    // For OpenAI keys (sk-...)
    if key.starts_with("sk-") {
        return "sk-••••••••".to_string();
    }
    // For Gemini keys (AI...)
    if key.starts_with("AI") {
        return "AI••••••••".to_string();
    }
    // For other keys, just show dots
    "••••••••".to_string()
}

/// Get API key for a specific provider in masked form
/// provider: 0 = OpenAI, 1 = Gemini, 2 = OpenRouter
/// Returns null if no key is set, or a masked version like "sk-••••••••"
/// Caller must free the returned string with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_api_key(handle: *mut FlowHandle, provider: u8) -> *mut c_char {
    let handle = unsafe { &*handle };

    let setting_key = match provider {
        0 => SETTING_OPENAI_API_KEY,
        1 => SETTING_GEMINI_API_KEY,
        2 => SETTING_OPENROUTER_API_KEY,
        _ => return ptr::null_mut(),
    };

    match handle.storage.get_setting(setting_key) {
        Ok(Some(key)) => {
            let masked = mask_api_key(&key);
            CString::new(masked).unwrap().into_raw()
        }
        _ => ptr::null_mut(),
    }
}

/// Set transcription mode (local or remote)
/// use_local: true for local Whisper, false for cloud provider
/// whisper_model: Model selection (only used when use_local = true)
///   0 = Turbo (~15MB) - quantized, ultra-fast, lowest memory
///   1 = Fast (~39MB) - fast, lower accuracy
///   2 = Balanced (~142MB) - good speed/accuracy balance
///   3 = Quality (~400MB) - great accuracy, still fast [recommended]
///   4 = Best (~750MB) - best quality available
/// Returns true on success, false on failure
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_transcription_mode(
    handle: *mut FlowHandle,
    use_local: bool,
    whisper_model: u8,
) -> bool {
    let handle = unsafe { &mut *handle };

    // Save setting to database
    if let Err(e) = handle.storage.set_setting(
        SETTING_USE_LOCAL_TRANSCRIPTION,
        if use_local { "true" } else { "false" },
    ) {
        let message = format!("Failed to save transcription mode: {}", e);
        error!("{}", message);
        set_last_error(handle, message);
        return false;
    }

    if use_local {
        // Local Whisper transcription
        let model = match whisper_model {
            0 => WhisperModel::Turbo,
            1 => WhisperModel::Fast,
            2 => WhisperModel::Balanced,
            3 => WhisperModel::Quality,
            4 => WhisperModel::Best,
            _ => {
                set_last_error(handle, "Invalid Whisper model selection (0-4)");
                return false;
            }
        };

        // Save model choice using canonical name
        let model_name = model.as_str();
        if let Err(e) = handle
            .storage
            .set_setting(SETTING_LOCAL_WHISPER_MODEL, model_name)
        {
            let message = format!("Failed to save Whisper model: {}", e);
            error!("{}", message);
            set_last_error(handle, message);
            return false;
        }

        // Get models directory
        let models_dir = match crate::whisper_models::get_models_dir() {
            Ok(dir) => dir,
            Err(e) => {
                let message = format!("Failed to get models directory: {}", e);
                error!("{}", message);
                set_last_error(handle, message);
                return false;
            }
        };

        // Check if model files already exist
        let files_exist = check_model_files_exist(model, &models_dir);

        // Set loading flag if this will require downloading
        if !files_exist {
            handle.is_model_loading.store(true, Ordering::SeqCst);
            debug!(
                "Model files not found, will download (~{}MB)",
                model.size_mb()
            );
        }

        // Create provider
        let provider = Arc::new(LocalWhisperTranscriptionProvider::new(model, models_dir));

        // Trigger model download/load asynchronously
        let provider_clone = Arc::clone(&provider);
        let loading_flag = Arc::clone(&handle.is_model_loading);
        let should_clear_flag = !files_exist;

        handle.runtime.spawn(async move {
            if let Err(e) = provider_clone.load_model().await {
                error!("Failed to load Whisper model: {}", e);
            }
            // Clear loading flag when done (only if we set it)
            if should_clear_flag {
                loading_flag.store(false, Ordering::SeqCst);
                debug!("Model loading completed");
            }
        });

        // Wrap with a cloud fallback so a still-downloading or failing model
        // never loses a dictation.
        handle.transcription = wrap_with_fallback(&handle.storage, provider);
        debug!("Enabled local Whisper transcription with {:?} model", model);
    } else {
        // Remote transcription - use the cloud transcription provider setting
        let cloud_provider = match handle
            .storage
            .get_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER)
        {
            Ok(Some(name)) => name,
            _ => "auto".to_string(), // default to Auto
        };

        match cloud_provider.as_str() {
            "openai" => {
                if let Ok(Some(key)) = handle.storage.get_setting(SETTING_OPENAI_API_KEY) {
                    let base_url = handle
                        .storage
                        .get_setting(SETTING_OPENAI_BASE_URL)
                        .ok()
                        .flatten()
                        .filter(|s| !s.is_empty());
                    handle.transcription =
                        Arc::new(OpenAITranscriptionProvider::new(Some(key), base_url));
                    debug!("Enabled OpenAI remote transcription");
                } else {
                    set_last_error(handle, "OpenAI API key not configured");
                    return false;
                }
            }
            _ => {
                // Default to Auto (worker handles transcription + completion)
                handle.transcription = Arc::new(AutoTranscriptionProvider::new(None));
                debug!("Enabled Auto transcription (worker handles everything)");
            }
        }
    }

    true
}

/// Get current transcription mode settings
/// Returns use_local flag and whisper_model (0-4) via out parameters
/// Returns false on database error, true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_transcription_mode(
    handle: *mut FlowHandle,
    out_use_local: *mut bool,
    out_whisper_model: *mut u8,
) -> bool {
    let handle = unsafe { &*handle };

    // Read use_local setting from database
    let use_local = match handle.storage.get_setting(SETTING_USE_LOCAL_TRANSCRIPTION) {
        Ok(Some(value)) => value == "true",
        Ok(None) => false, // Default to remote if not set
        Err(e) => {
            error!("Failed to read transcription mode: {}", e);
            return false;
        }
    };

    // Read whisper model setting from database
    let whisper_model = if use_local {
        match handle.storage.get_setting(SETTING_LOCAL_WHISPER_MODEL) {
            Ok(Some(model_str)) => {
                // Convert model name to enum
                let model = WhisperModel::all()
                    .iter()
                    .find(|m| m.as_str() == model_str)
                    .copied()
                    .unwrap_or(WhisperModel::Balanced); // Default to Balanced

                // Convert enum to u8
                match model {
                    WhisperModel::Turbo => 0,
                    WhisperModel::Fast => 1,
                    WhisperModel::Balanced => 2,
                    WhisperModel::Quality => 3,
                    WhisperModel::Best => 4,
                }
            }
            Ok(None) => 1, // Default to Balanced
            Err(e) => {
                error!("Failed to read Whisper model: {}", e);
                return false;
            }
        }
    } else {
        1 // Default value when using remote transcription
    };

    // Write to out parameters
    unsafe {
        *out_use_local = use_local;
        *out_whisper_model = whisper_model;
    }

    true
}

/// Check if a Whisper model is currently being downloaded/initialized
/// Returns true if model download/initialization is in progress
#[unsafe(no_mangle)]
pub extern "C" fn flow_is_model_loading(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };
    handle.is_model_loading.load(Ordering::SeqCst)
}

/// Legacy function - prefer flow_set_transcription_mode
/// Enable local Whisper transcription with Metal + Accelerate acceleration
/// model: 0=Turbo, 1=Fast, 2=Balanced, 3=Quality, 4=Best
/// Returns true on success, false on failure
#[unsafe(no_mangle)]
pub extern "C" fn flow_enable_local_whisper(handle: *mut FlowHandle, model: u8) -> bool {
    flow_set_transcription_mode(handle, true, model)
}

/// Get available Whisper models as JSON (caller must free with flow_free_string)
/// Returns JSON array with model info including id, name, description, size, and flags
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_whisper_models_json() -> *mut c_char {
    let models: Vec<serde_json::Value> = WhisperModel::all()
        .iter()
        .enumerate()
        .map(|(id, model)| {
            serde_json::json!({
                "id": id,
                "name": model.as_str(),
                "description": model.description(),
                "size_mb": model.size_mb(),
                "is_quantized": model.is_quantized(),
                "is_distilled": model.is_distilled(),
            })
        })
        .collect();

    let json = serde_json::to_string(&models).unwrap_or_else(|_| "[]".to_string());
    CString::new(json).unwrap().into_raw()
}

/// Get all shortcuts as JSON (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_shortcuts_json(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };

    let shortcuts: Vec<serde_json::Value> = handle
        .shortcuts
        .get_all()
        .iter()
        .map(|s| {
            serde_json::json!({
                "trigger": s.trigger,
                "replacement": s.replacement,
                "use_count": s.use_count,
                "enabled": s.enabled,
            })
        })
        .collect();

    match CString::new(serde_json::to_string(&shortcuts).unwrap_or_default()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

// ============ Contact Categorization ============

/// Get active contact name from Messages.app window
/// Returns C string with contact name, or null if not available
/// Caller must free with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_active_messages_contact(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    match MessagesDetector::get_active_contact() {
        Ok(Some(name)) => match CString::new(name) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => {
                set_last_error(handle, "Invalid UTF-8 in contact name");
                ptr::null_mut()
            }
        },
        Ok(None) => ptr::null_mut(),
        Err(e) => {
            set_last_error(handle, format!("Failed to get active contact: {}", e));
            ptr::null_mut()
        }
    }
}

/// Classify a contact given name and organization
/// Returns JSON string with category
/// Caller must free with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_classify_contact(
    handle: *mut FlowHandle,
    name: *const c_char,
    organization: *const c_char,
) -> *mut c_char {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let name_str = unsafe {
        if name.is_null() {
            set_last_error(handle, "Name cannot be null");
            return ptr::null_mut();
        }
        match CStr::from_ptr(name).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error(handle, "Invalid UTF-8 in name");
                return ptr::null_mut();
            }
        }
    };

    let org_str = unsafe {
        if organization.is_null() {
            String::new()
        } else {
            match CStr::from_ptr(organization).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => String::new(),
            }
        }
    };

    let input = ContactInput {
        name: name_str.to_string(),
        organization: org_str,
    };

    let category = handle.contact_classifier.classify(&input);

    let result = serde_json::json!({
        "name": name_str,
        "category": category,
    });

    match CString::new(result.to_string()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => {
            set_last_error(handle, "Failed to serialize result");
            ptr::null_mut()
        }
    }
}

/// Classify multiple contacts from JSON array
/// Input format: [{"name": "...", "organization": "..."}]
/// Output format: {"ContactName": "category", ...}
/// Caller must free with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_classify_contacts_batch(
    handle: *mut FlowHandle,
    contacts_json: *const c_char,
) -> *mut c_char {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let json_str = unsafe {
        if contacts_json.is_null() {
            set_last_error(handle, "JSON cannot be null");
            return ptr::null_mut();
        }
        match CStr::from_ptr(contacts_json).to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error(handle, "Invalid UTF-8 in JSON");
                return ptr::null_mut();
            }
        }
    };

    let inputs: Vec<ContactInput> = match serde_json::from_str(json_str) {
        Ok(i) => i,
        Err(e) => {
            set_last_error(handle, format!("Invalid JSON: {}", e));
            return ptr::null_mut();
        }
    };

    let result_json = handle.contact_classifier.classify_batch_json(&inputs);

    match CString::new(result_json) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => {
            set_last_error(handle, "Failed to create result string");
            ptr::null_mut()
        }
    }
}

/// Record interaction with a contact (updates frequency)
#[unsafe(no_mangle)]
pub extern "C" fn flow_record_contact_interaction(handle: *mut FlowHandle, name: *const c_char) {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let name_str = unsafe {
        if name.is_null() {
            return;
        }
        match CStr::from_ptr(name).to_str() {
            Ok(s) => s,
            Err(_) => return,
        }
    };

    handle.contact_classifier.record_interaction(name_str);
}

/// Get frequent contacts as JSON array
/// Returns: [{"name": "...", "category": "...", "frequency": N}, ...]
/// Caller must free with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_frequent_contacts(handle: *mut FlowHandle, limit: u32) -> *mut c_char {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let contacts = handle
        .contact_classifier
        .get_frequent_contacts(limit as usize);

    let result: Vec<serde_json::Value> = contacts
        .iter()
        .map(|c| {
            serde_json::json!({
                "name": c.name,
                "category": c.category,
                "frequency": c.frequency,
                "organization": c.organization,
            })
        })
        .collect();

    match CString::new(serde_json::to_string(&result).unwrap_or_default()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => {
            set_last_error(handle, "Failed to serialize contacts");
            ptr::null_mut()
        }
    }
}

/// Get suggested writing mode for a contact category
/// Returns: 0=Formal, 1=Casual, 2=VeryCasual, 3=Excited
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_writing_mode_for_category(
    handle: *mut FlowHandle,
    category: u32,
) -> u32 {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let contact_category = match category {
        0 => ContactCategory::Professional,
        1 => ContactCategory::CloseFamily,
        2 => ContactCategory::CasualPeer,
        3 => ContactCategory::Partner,
        4 => ContactCategory::FormalNeutral,
        _ => ContactCategory::FormalNeutral,
    };

    let writing_mode = contact_category.suggested_writing_mode();

    match writing_mode {
        WritingMode::Formal => 0,
        WritingMode::Casual => 1,
        WritingMode::VeryCasual => 2,
        WritingMode::Excited => 3,
    }
}

// ============ Cloud Transcription Provider ============

/// Set cloud transcription provider (saves preference)
/// provider: 0 = OpenAI, 1 = Auto (default)
/// Returns true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_cloud_transcription_provider(
    handle: *mut FlowHandle,
    provider: u8,
) -> bool {
    let handle = unsafe { &mut *handle };

    let provider_name = match provider {
        0 => "openai",
        1 => "auto",
        _ => {
            set_last_error(
                handle,
                "Invalid cloud transcription provider (0=OpenAI, 1=Auto)",
            );
            return false;
        }
    };

    // Save the provider preference
    if let Err(e) = handle
        .storage
        .set_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER, provider_name)
    {
        let message = format!("Failed to save cloud transcription provider: {e}");
        error!("{message}");
        set_last_error(handle, message);
        return false;
    }

    clear_last_error(handle);
    true
}

/// Get the current cloud transcription provider
/// Returns: 0 = OpenAI, 1 = Auto (default)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_cloud_transcription_provider(handle: *mut FlowHandle) -> u8 {
    let handle = unsafe { &*handle };

    match handle
        .storage
        .get_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER)
    {
        Ok(Some(name)) => match name.as_str() {
            "openai" => 0,
            "auto" => 1,
            _ => 1, // default to Auto
        },
        _ => 1, // default to Auto
    }
}

/// Enable or disable the cloud fallback for local transcription.
/// When enabled (default), a failing or empty local Whisper result is retried
/// against the cloud. Takes effect on the next transcription mode change.
/// Returns true on success.
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_transcription_fallback(handle: *mut FlowHandle, enabled: bool) -> bool {
    let handle = unsafe { &mut *handle };

    if let Err(e) = handle.storage.set_setting(
        SETTING_TRANSCRIPTION_FALLBACK,
        if enabled { "true" } else { "false" },
    ) {
        let message = format!("Failed to save transcription fallback setting: {e}");
        error!("{message}");
        set_last_error(handle, message);
        return false;
    }

    // Re-apply to the active provider if local transcription is in use.
    let use_local = handle
        .storage
        .get_setting(SETTING_USE_LOCAL_TRANSCRIPTION)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(false);

    if use_local {
        let model_str = handle
            .storage
            .get_setting(SETTING_LOCAL_WHISPER_MODEL)
            .ok()
            .flatten();
        let model = WhisperModel::all()
            .iter()
            .find(|m| m.as_str() == model_str.as_deref().unwrap_or(""))
            .copied()
            .unwrap_or(WhisperModel::Quality);

        if let Ok(models_dir) = crate::whisper_models::get_models_dir() {
            let local: Arc<dyn TranscriptionProvider> =
                Arc::new(LocalWhisperTranscriptionProvider::new(model, models_dir));
            handle.transcription = wrap_with_fallback(&handle.storage, local);
        }
    }

    clear_last_error(handle);
    true
}

/// Get whether the cloud fallback for local transcription is enabled.
/// Returns true when enabled (the default).
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_transcription_fallback(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };
    transcription_fallback_enabled(&handle.storage)
}

// ============ Style learning ============

fn c_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn into_c_string(value: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(value).map_or(ptr::null_mut(), CString::into_raw)
}

fn uses_worker(storage: &Storage) -> bool {
    !matches!(
        storage
            .get_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER)
            .ok()
            .flatten()
            .as_deref(),
        Some("openai")
    )
}

/// Format typed text as if it had been dictated (caller must free with flow_free_string).
/// contact_name may be null; when set it is classified like a Messages contact.
#[unsafe(no_mangle)]
pub extern "C" fn flow_format_text(
    handle: *mut FlowHandle,
    text: *const c_char,
    app_name: *const c_char,
    contact_name: *const c_char,
) -> *mut c_char {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let Some(text) = c_str(text).map(str::trim).filter(|t| !t.is_empty()) else {
        set_last_error(handle, "No text to format");
        return ptr::null_mut();
    };
    let app_name = c_str(app_name);

    let contact_name = c_str(contact_name);
    let (mode, recipient) = resolve_recipient(handle, app_name, contact_name);
    let category = style::category_key(recipient, Some(handle.app_tracker.current_category()));
    let contact = recipient_contact_key(recipient, contact_name);
    let context = format_context(app_name, recipient);
    let personalization = personalization_for(handle, text, &category, &contact);

    let (shortcut_text, triggered) = handle.shortcuts.process(text);
    let (corrected, _) = handle.learning.apply_corrections(&shortcut_text);

    let result = if uses_worker(&handle.storage) {
        let params = TranscriptionCompletionParams {
            stable_prefix: None,
            mode: mode.worker_name().to_string(),
            app_context: context,
            shortcuts_triggered: triggered.into_iter().map(|s| s.replacement).collect(),
            shortcut_definitions: Vec::new(),
            attachment_commands_enabled: false,
            voice_instruction: None,
            personalization,
            auto_rewriting_enabled: true,
        };
        handle
            .runtime
            .block_on(crate::providers::format_text(&corrected, params))
    } else {
        let mut request = CompletionRequest::new(corrected.clone(), mode);
        if let Some(context) = context {
            request = request.with_app_context(context);
        }
        if let Some(personalization) = personalization {
            request = request.with_personalization(personalization);
        }
        let completion = Arc::clone(&handle.completion);
        handle
            .runtime
            .block_on(async { completion.complete(request).await })
            .map(|response| response.text)
    };

    match result {
        Ok(output) => {
            *handle.pending_dictation.lock() = Some(PendingDictation {
                category,
                contact_key: contact,
                said: text.to_string(),
                flow_output: output.clone(),
            });
            into_c_string(output)
        }
        Err(e) => {
            set_last_error(handle, e.to_string());
            ptr::null_mut()
        }
    }
}

/// Record what the user finally sent for the last dictation.
/// Returns 1 when the style profile is due for a rebuild, 0 when recorded, -1 when nothing was pending.
#[unsafe(no_mangle)]
pub extern "C" fn flow_record_final_text(
    handle: *mut FlowHandle,
    final_text: *const c_char,
) -> i32 {
    let handle = unsafe { &*handle };

    let Some(pending) = handle.pending_dictation.lock().take() else {
        return -1;
    };
    let sent = c_str(final_text)
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .unwrap_or(&pending.flow_output);

    let example =
        StyleExample::dictation(&pending.category, &pending.said, &pending.flow_output, sent)
            .with_contact(&pending.contact_key);
    log_with_time!(
        "🎨 [RUST] Recorded {} dictation for {}",
        if example.edited { "edited" } else { "unedited" },
        example.category
    );
    if let Err(e) = handle.storage.save_style_example(&example) {
        error!("Failed to save style example: {}", e);
        return -1;
    }

    i32::from(profile_rebuild_due(&handle.storage))
}

/// Record a send only when its current contact matches the captured recipient.
/// A missing/mismatched contact discards the pending baseline instead of teaching
/// one conversation's correction to another. Returns -1, 0 or 1 like record_final_text.
#[unsafe(no_mangle)]
pub extern "C" fn flow_record_final_text_for_contact(
    handle: *mut FlowHandle,
    final_text: *const c_char,
    contact_name: *const c_char,
) -> i32 {
    if handle.is_null() { return -1; }
    let engine = unsafe { &*handle };
    let contact = style::contact_key(c_str(contact_name).unwrap_or(""));
    let matches = !contact.is_empty() && engine.pending_dictation.lock().as_ref()
        .is_some_and(|pending| pending.contact_key == contact);
    if !matches { *engine.pending_dictation.lock() = None; return -1; }
    flow_record_final_text(handle, final_text)
}

/// Drop the last dictation without learning from it (e.g. the sent text could not be read)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_attachment_plan(handle: *mut FlowHandle) -> *mut c_char {
    if handle.is_null() { return ptr::null_mut(); }
    let handle = unsafe { &*handle };
    handle.pending_attachment.lock().as_ref()
        .and_then(|p| serde_json::to_string(p).ok())
        .map_or(ptr::null_mut(), into_c_string)
}

/// Discard pending message learning and its attachment request.
#[unsafe(no_mangle)]
pub extern "C" fn flow_discard_pending_dictation(handle: *mut FlowHandle) {
    if !handle.is_null() { unsafe { &*handle }.pending_attachment.lock().take(); }
    let handle = unsafe { &*handle };
    *handle.pending_dictation.lock() = None;
}

fn profile_rebuild_due(storage: &Storage) -> bool {
    let total = storage.count_style_examples().unwrap_or(0);
    let at_last_build = storage
        .get_setting(SETTING_STYLE_PROFILE_EXAMPLE_COUNT)
        .ok()
        .flatten()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    total >= at_last_build + style::PROFILE_REBUILD_INTERVAL
}

/// Rebuild the style profile from stored examples. Blocks on a network call, so run off the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn flow_rebuild_style_profile(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let examples = handle
        .storage
        .get_style_examples(STYLE_EXAMPLE_POOL)
        .unwrap_or_default();
    let sample = style::sample_for_profile(&examples, style::PROFILE_EXAMPLES_PER_CATEGORY);
    if sample.is_empty() {
        // Recipient-only edits already apply to the next request without a
        // global profile. Avoid a network rebuild with no global evidence.
        return handle.storage.set_setting(SETTING_STYLE_PROFILE_EXAMPLE_COUNT, &examples.len().to_string()).is_ok();
    }
    let current = handle
        .storage
        .get_setting(SETTING_STYLE_PROFILE)
        .ok()
        .flatten();

    match handle
        .runtime
        .block_on(crate::providers::build_style_profile(
            &sample,
            current.as_deref(),
        )) {
        Ok(profile) => {
            let saved = handle
                .storage
                .set_setting(SETTING_STYLE_PROFILE, &profile)
                .is_ok()
                && handle
                    .storage
                    .set_setting(
                        SETTING_STYLE_PROFILE_EXAMPLE_COUNT,
                        &examples.len().to_string(),
                    )
                    .is_ok();
            log_with_time!(
                "🎨 [RUST] Rebuilt style profile from {} examples",
                sample.len()
            );
            saved
        }
        Err(e) => {
            set_last_error(handle, e.to_string());
            false
        }
    }
}

/// Style profile Markdown, empty when none exists (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_style_profile(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };
    let profile = handle
        .storage
        .get_setting(SETTING_STYLE_PROFILE)
        .ok()
        .flatten()
        .unwrap_or_default();
    into_c_string(profile)
}

/// Replace the style profile with the user's edited version
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_style_profile(handle: *mut FlowHandle, profile: *const c_char) -> bool {
    let handle = unsafe { &*handle };
    let Some(profile) = c_str(profile) else {
        return false;
    };
    handle
        .storage
        .set_setting(SETTING_STYLE_PROFILE, profile.trim())
        .is_ok()
}

/// strength: 0 = light, 1 = balanced, 2 = full
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_rewrite_strength(handle: *mut FlowHandle, strength: u8) -> bool {
    let handle = unsafe { &*handle };
    handle
        .storage
        .set_setting(
            SETTING_REWRITE_STRENGTH,
            RewriteStrength::from_u8(strength).as_str(),
        )
        .is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn flow_get_rewrite_strength(handle: *mut FlowHandle) -> u8 {
    let handle = unsafe { &*handle };
    rewrite_strength(&handle.storage).to_u8()
}

/// Edit rate and example counts as JSON (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_style_stats_json(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };
    let stats = handle
        .storage
        .get_edit_stats(style::RECENT_DICTATIONS)
        .unwrap_or_default();

    let json = serde_json::json!({
        "edited": stats.edited,
        "total": stats.total,
        "rate": stats.rate(),
        "recent_edited": stats.recent_edited,
        "recent_total": stats.recent_total,
        "recent_rate": stats.recent_rate(),
        "examples": handle.storage.count_style_examples().unwrap_or(0),
    });
    into_c_string(json.to_string())
}

/// Import messages the user wrote themselves: JSON array of {"category", "text"}.
/// Returns the number imported, or -1 on invalid input.
#[unsafe(no_mangle)]
pub extern "C" fn flow_import_style_examples_json(
    handle: *mut FlowHandle,
    json: *const c_char,
) -> i64 {
    #[derive(serde::Deserialize)]
    struct Entry {
        category: String,
        text: String,
    }

    let handle = unsafe { &*handle };
    let Some(entries) = c_str(json).and_then(|j| serde_json::from_str::<Vec<Entry>>(j).ok()) else {
        set_last_error(handle, "Expected a JSON array of {category, text}");
        return -1;
    };

    let mut imported = 0;
    for entry in entries.iter().filter(|e| !e.text.trim().is_empty()) {
        let example = StyleExample::imported(&entry.category, entry.text.trim());
        if handle.storage.save_style_example(&example).is_ok() {
            imported += 1;
        }
    }
    imported
}

/// Import messages the user sent from Messages (needs Full Disk Access).
/// Only messages newer than the last import are read. Returns the number imported, or -1 on error.
#[unsafe(no_mangle)]
pub extern "C" fn flow_import_imessages(handle: *mut FlowHandle, limit: u32) -> i64 {
    let handle = unsafe { &*handle };
    clear_last_error(handle);

    let since = handle
        .storage
        .get_setting(SETTING_IMESSAGE_IMPORTED_THROUGH)
        .ok()
        .flatten()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);

    let messages = match crate::imessage::read_sent_messages(since, limit as usize) {
        Ok(messages) => messages,
        Err(e) => {
            set_last_error(handle, e.to_string());
            return -1;
        }
    };

    let mut imported = 0;
    for message in &messages {
        let example = StyleExample::imported(&message.category, &message.text)
            .with_contact(&message.contact_key);
        if handle.storage.save_style_example(&example).is_ok() {
            imported += 1;
        }
    }
    if let Some(newest) = messages.iter().map(|m| m.date).max() {
        let _ = handle
            .storage
            .set_setting(SETTING_IMESSAGE_IMPORTED_THROUGH, &newest.to_string());
    }

    log_with_time!("🎨 [RUST] Imported {} sent iMessages", imported);
    imported
}

/// Delete all style examples and the profile
#[unsafe(no_mangle)]
pub extern "C" fn flow_reset_style_learning(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };
    *handle.pending_dictation.lock() = None;
    handle.storage.delete_all_style_examples().is_ok()
        && handle
            .storage
            .set_setting(SETTING_STYLE_PROFILE, "")
            .is_ok()
        && handle
            .storage
            .set_setting(SETTING_IMESSAGE_IMPORTED_THROUGH, "0")
            .is_ok()
        && handle
            .storage
            .set_setting(SETTING_STYLE_PROFILE_EXAMPLE_COUNT, "0")
            .is_ok()
}

// ============ Auto-Rewriting Setting ============

/// Set whether auto-rewriting is enabled
/// When disabled, transcriptions are returned as-is (with shortcuts only, no corrections or AI)
///
/// # Arguments
/// - `handle` - Engine handle
/// - `enabled` - Whether auto-rewriting should be enabled
///
/// # Returns
/// true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_auto_rewriting_enabled(handle: *mut FlowHandle, enabled: bool) -> bool {
    let handle = unsafe { &mut *handle };

    let value = if enabled { "true" } else { "false" };

    if let Err(e) = handle
        .storage
        .set_setting(SETTING_AUTO_REWRITING_ENABLED, value)
    {
        set_last_error(
            handle,
            format!("Failed to save auto-rewriting setting: {}", e),
        );
        return false;
    }

    debug!("Auto-rewriting set to: {}", enabled);
    true
}

/// Get whether auto-rewriting is enabled
///
/// # Arguments
/// - `handle` - Engine handle
///
/// # Returns
/// true if auto-rewriting is enabled, false otherwise (default: true)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_auto_rewriting_enabled(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };

    handle
        .storage
        .get_setting(SETTING_AUTO_REWRITING_ENABLED)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(true) // default to enabled
}

// ============ Alignment and Edit Detection ============

/// Align original and edited text, extract correction candidates
/// Returns JSON with alignment result (caller must free with flow_free_string)
/// JSON format:
/// {
///   "steps": [...],
///   "word_edit_vector": "MMSMM",
///   "punct_edit_vector": "ZZZZ",
///   "corrections": [["original", "corrected"], ...]
/// }
#[unsafe(no_mangle)]
pub extern "C" fn flow_align_and_extract_corrections(
    original: *const c_char,
    edited: *const c_char,
) -> *mut c_char {
    if original.is_null() || edited.is_null() {
        return ptr::null_mut();
    }

    let original_str = match unsafe { CStr::from_ptr(original) }.to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    let edited_str = match unsafe { CStr::from_ptr(edited) }.to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    let json = crate::alignment::align_and_extract_corrections_json(original_str, edited_str);

    match CString::new(json) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Get dictionary context for ASR prompting
/// Returns JSON array of high-confidence learned words (caller must free with flow_free_string)
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_dictionary_context(handle: *mut FlowHandle, limit: u32) -> *mut c_char {
    let handle = unsafe { &*handle };

    let words = handle
        .storage
        .get_dictionary_context(limit as usize)
        .unwrap_or_default();

    let json = serde_json::to_string(&words).unwrap_or_else(|_| "[]".to_string());

    match CString::new(json) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Save edit analytics for tracking alignment patterns
/// Returns true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_save_edit_analytics(
    handle: *mut FlowHandle,
    word_edit_vector: *const c_char,
    punct_edit_vector: *const c_char,
    original_text: *const c_char,
    edited_text: *const c_char,
) -> bool {
    let handle = unsafe { &*handle };

    if word_edit_vector.is_null() {
        return false;
    }

    let word_vec = match unsafe { CStr::from_ptr(word_edit_vector) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let punct_vec = if punct_edit_vector.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(punct_edit_vector) }.to_str().ok()
    };

    let original = if original_text.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(original_text) }.to_str().ok()
    };

    let edited = if edited_text.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(edited_text) }.to_str().ok()
    };

    handle
        .storage
        .save_edit_analytics(None, word_vec, punct_vec, original, edited)
        .is_ok()
}

/// Save a learned words session for undo functionality
/// words_json: JSON array of strings ["word1", "word2", ...]
/// Returns session ID (or -1 on error)
#[unsafe(no_mangle)]
pub extern "C" fn flow_save_learned_words_session(
    handle: *mut FlowHandle,
    words_json: *const c_char,
) -> i64 {
    let handle = unsafe { &*handle };

    let json_str = match unsafe { CStr::from_ptr(words_json) }.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let words: Vec<String> = match serde_json::from_str(json_str) {
        Ok(w) => w,
        Err(_) => return -1,
    };

    handle
        .storage
        .save_learned_words_session(&words)
        .unwrap_or(-1)
}

/// Undo the most recent learned words session
/// Removes the corrections and marks session as used
/// Returns true if undo was performed
#[unsafe(no_mangle)]
pub extern "C" fn flow_undo_learned_words(handle: *mut FlowHandle) -> bool {
    let handle = unsafe { &*handle };

    let Some((session_id, words)) = handle.storage.get_undoable_learned_words().ok().flatten()
    else {
        return false;
    };

    // Delete each learned word
    for word in &words {
        let _ = handle.storage.delete_correction_by_word(word);
        // Also remove from learning engine cache
        handle.learning.remove_from_cache(word);
    }

    // Mark session as used
    let _ = handle.storage.mark_learned_words_used(session_id);

    debug!("Undid learned words session {}: {:?}", session_id, words);
    true
}

/// Get the most recent undoable learned words as JSON
/// Returns JSON array of strings (caller must free with flow_free_string)
/// Returns null if no undoable session exists
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_undoable_learned_words(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };

    let Some((_, words)) = handle.storage.get_undoable_learned_words().ok().flatten() else {
        return ptr::null_mut();
    };

    let json = serde_json::to_string(&words).unwrap_or_else(|_| "[]".to_string());

    match CString::new(json) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

// ============ OpenAI Base URL ============

/// Set a custom OpenAI-compatible base URL for transcription and completion
/// Pass an empty string to reset to the default (https://api.openai.com/v1)
/// Returns true on success
#[unsafe(no_mangle)]
pub extern "C" fn flow_set_openai_base_url(handle: *mut FlowHandle, url: *const c_char) -> bool {
    let handle = unsafe { &mut *handle };

    let url_str = if url.is_null() {
        String::new()
    } else {
        match unsafe { CStr::from_ptr(url) }.to_str() {
            Ok(s) => s.trim().to_string(),
            Err(_) => return false,
        }
    };

    if let Err(e) = handle
        .storage
        .set_setting(SETTING_OPENAI_BASE_URL, &url_str)
    {
        set_last_error(handle, format!("Failed to save OpenAI base URL: {e}"));
        return false;
    }

    // Update the live transcription provider only when currently using cloud OpenAI
    let use_local = handle
        .storage
        .get_setting(SETTING_USE_LOCAL_TRANSCRIPTION)
        .ok()
        .flatten()
        .map(|s| s == "true")
        .unwrap_or(false);

    let cloud_provider = handle
        .storage
        .get_setting(SETTING_CLOUD_TRANSCRIPTION_PROVIDER)
        .ok()
        .flatten()
        .unwrap_or_else(|| "auto".to_string());

    if !use_local && cloud_provider == "openai" {
        let api_key = handle
            .storage
            .get_setting(SETTING_OPENAI_API_KEY)
            .ok()
            .flatten();
        let base_url = if url_str.is_empty() {
            None
        } else {
            Some(url_str)
        };
        handle.transcription = Arc::new(OpenAITranscriptionProvider::new(api_key, base_url));
    }

    clear_last_error(handle);
    true
}

/// Get the currently configured custom OpenAI base URL
/// Returns null if using the default (https://api.openai.com/v1)
/// Caller must free the returned string with flow_free_string
#[unsafe(no_mangle)]
pub extern "C" fn flow_get_openai_base_url(handle: *mut FlowHandle) -> *mut c_char {
    let handle = unsafe { &*handle };

    match handle.storage.get_setting(SETTING_OPENAI_BASE_URL) {
        Ok(Some(url)) if !url.is_empty() => match CString::new(url) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => ptr::null_mut(),
        },
        _ => ptr::null_mut(),
    }
}

#[cfg(test)]
mod recording_sample_tests {
    use super::*;

    #[test]
    fn stopped_audio_can_finish_captions_without_consuming_transcription() {
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        assert!(!handle.is_null());
        let engine = unsafe { &*handle };
        let bytes: Vec<u8> = [0i16, 16384, -16384, 32767].into_iter().flat_map(i16::to_le_bytes).collect();
        *engine.pending_audio.lock() = Some(bytes.clone());
        *engine.pending_sample_rate.lock() = Some(16000);
        let mut output = [0.0; 2];
        let mut rate = 0;
        assert_eq!(flow_read_recording_samples(handle, 1, output.as_mut_ptr(), 2, &mut rate), 2);
        assert_eq!(rate, 16000);
        assert!((output[0] - 0.5).abs() < 0.001);
        assert!((output[1] + 0.5).abs() < 0.001);
        assert_eq!(flow_read_recording_samples(handle, 4, output.as_mut_ptr(), 2, &mut rate), 0);
        assert_eq!(flow_read_recording_samples(handle, u64::MAX, output.as_mut_ptr(), 2, &mut rate), 0);
        assert_eq!(*engine.pending_audio.lock(), Some(bytes));
        flow_destroy(handle);
    }
}

#[cfg(test)]
mod dictation_stream_tests {
    use super::*;
    use crate::providers::{DictationDelta, TranscriptionResponse};

    struct StreamFixture;

    #[test]
    fn realtime_asr_preserves_the_audio_pipeline_and_contact_learning() {
        struct RealtimeFixture;
        #[async_trait::async_trait]
        impl TranscriptionProvider for RealtimeFixture {
            fn name(&self) -> &'static str { "finalized realtime fixture" }
            fn is_configured(&self) -> bool { true }
            async fn transcribe(&self, _: TranscriptionRequest) -> crate::error::Result<TranscriptionResponse> { unreachable!() }
            async fn transcribe_stream(&self, request: TranscriptionRequest, callback: DictationDelta) -> crate::error::Result<TranscriptionResponse> {
                assert_eq!(request.audio.len(), 32000, "keep the original recording retryable");
                let text = request.final_transcript.expect("real-time ASR was lost");
                assert_eq!(text, "Can you review the slides?");
                assert!(request.completion.unwrap().attachment_commands_enabled);
                assert!(callback("got a sec to review the deck?"));
                Ok(TranscriptionResponse { text, completed_text: Some("got a sec to review the deck?".into()),
                    attachment: None, confidence: None, language: None, duration_ms: 1000, segments: None })
            }
        }
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &mut *handle };
        engine.transcription = Arc::new(RealtimeFixture);
        let pcm = vec![0; 32000];
        let app = CString::new("Messages").unwrap();
        let contact = CString::new("Alex").unwrap();
        let transcript = CString::new("Can you review the slides?").unwrap();
        let mut state = CallbackState { chunks: vec![], cancel: false };
        let result = flow_transcribe_audio_realtime_stream(handle, pcm.as_ptr(), pcm.len(), 16000,
            app.as_ptr(), contact.as_ptr(), transcript.as_ptr(), receive, &mut state as *mut _ as *mut c_void);
        assert!(!result.is_null());
        assert_eq!(state.chunks, ["got a sec to review the deck?"]);
        assert!(engine.storage.get_style_examples(10).unwrap().is_empty(), "dictation alone must not train");
        let pending = engine.pending_dictation.lock();
        assert_eq!(pending.as_ref().unwrap().said, "Can you review the slides?");
        assert_eq!(pending.as_ref().unwrap().contact_key, style::contact_key("Alex"));
        drop(pending);
        let edit = CString::new("yo can u check the deck?").unwrap();
        flow_record_final_text_for_contact(handle, edit.as_ptr(), contact.as_ptr());
        assert_eq!(engine.storage.get_style_examples(10).unwrap()[0].sent, "yo can u check the deck?");
        flow_free_string(result); flow_destroy(handle);
    }
    #[async_trait::async_trait]
    impl TranscriptionProvider for StreamFixture {
        fn name(&self) -> &'static str { "controlled stream fixture" }
        fn is_configured(&self) -> bool { true }
        async fn transcribe(&self, _: TranscriptionRequest) -> crate::error::Result<TranscriptionResponse> {
            panic!("The streaming FFI used the buffered provider");
        }
        async fn transcribe_stream(&self, _: TranscriptionRequest, callback: DictationDelta) -> crate::error::Result<TranscriptionResponse> {
            for token in ["got a sec", " to review the slides?"] {
                if !callback(token) { return Err(crate::error::Error::Transcription("cancelled".into())); }
            }
            Ok(TranscriptionResponse { attachment: None, text: "can you review the slides".into(), completed_text: Some("got a sec to review the slides?".into()),
                confidence: None, language: None, duration_ms: 1000, segments: None })
        }
    }

    struct CallbackState { chunks: Vec<String>, cancel: bool }
    extern "C" fn receive(delta: *const c_char, context: *mut c_void) -> bool {
        let state = unsafe { &mut *(context as *mut CallbackState) };
        let text = unsafe { CStr::from_ptr(delta) }.to_str().unwrap();
        if !text.is_empty() { state.chunks.push(text.into()); }
        !state.cancel
    }

    #[test]
    fn final_stream_carries_scoped_completed_sentences_into_history() {
        struct PreservedFixture;
        #[async_trait::async_trait]
        impl TranscriptionProvider for PreservedFixture {
            fn name(&self) -> &'static str { "preserved sentence fixture" }
            fn is_configured(&self) -> bool { true }
            async fn transcribe(&self, _: TranscriptionRequest) -> crate::error::Result<TranscriptionResponse> { panic!("buffered fixture"); }
            async fn transcribe_stream(&self, request: TranscriptionRequest, callback: DictationDelta) -> crate::error::Result<TranscriptionResponse> {
                let source = request.final_transcript.unwrap();
                let params = request.completion.unwrap();
                if request.audio.is_empty() {
                    assert!(params.stable_prefix.is_none());
                    assert!(callback("Here is the report."));
                    Ok(TranscriptionResponse { text: source, completed_text: Some("Here is the report.".into()),
                        attachment: None, confidence: None, language: None, duration_ms: 0, segments: None })
                } else {
                    let prefix = params.stable_prefix.expect("completed sentence was lost");
                    assert_eq!(prefix.source, "Yo here is the report.");
                    assert_eq!(prefix.output, "Here is the report.");
                    assert!(callback(&prefix.output));
                    Ok(TranscriptionResponse { text: source, completed_text: Some(prefix.output), attachment: None,
                        confidence: None, language: None, duration_ms: 1000, segments: None })
                }
            }
        }
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &mut *handle };
        engine.transcription = Arc::new(PreservedFixture);
        *engine.captured_contact.lock() = Some("Fixture Person".into());
        let source = CString::new("Yo here is the report.").unwrap();
        let app = CString::new("Messages").unwrap();
        let mut state = CallbackState { chunks: vec![], cancel: false };
        let preview = flow_preview_rewrite_stream(handle, source.as_ptr(), app.as_ptr(), receive, &mut state as *mut _ as *mut c_void);
        assert!(!preview.is_null()); flow_free_string(preview);
        assert!(engine.live_rewrite.lock().is_some());
        assert!(engine.storage.get_recent_history(10).unwrap().is_empty());
        let result = transcribe_with_audio(engine, vec![0; 32000], 16000, Some("Messages".into()),
            Some(Arc::new(|_| true)), Some("Yo here is the report.".into())).unwrap();
        assert_eq!(result, "Here is the report.");
        assert!(engine.live_rewrite.lock().is_none(), "cache crossed dictation boundaries");
        assert_eq!(engine.pending_dictation.lock().as_ref().unwrap().flow_output, result);
        assert_eq!(engine.storage.get_recent_history(10).unwrap()[0].text, result);
        assert!(engine.storage.get_style_examples(10).unwrap().is_empty(), "dictation alone trained a rule");
        flow_destroy(handle);
    }

    #[test]
    fn live_preview_preserves_audio_history_and_send_learning() {
        struct PreviewFixture;
        #[async_trait::async_trait]
        impl TranscriptionProvider for PreviewFixture {
            fn name(&self) -> &'static str { "live preview fixture" }
            fn is_configured(&self) -> bool { true }
            async fn transcribe(&self, _: TranscriptionRequest) -> crate::error::Result<TranscriptionResponse> { panic!("buffered preview"); }
            async fn transcribe_stream(&self, request: TranscriptionRequest, callback: DictationDelta) -> crate::error::Result<TranscriptionResponse> {
                assert!(request.audio.is_empty(), "preview uploaded audio");
                assert_eq!(request.final_transcript.as_deref(), Some("can you review the deck"));
                let params = request.completion.unwrap();
                assert!(params.attachment_commands_enabled);
                assert!(params.app_context.unwrap().contains("writing to"));
                if !callback("got a sec") { return Err(crate::error::Error::Transcription("cancelled".into())); }
                Ok(TranscriptionResponse { text: "can you review the deck".into(), completed_text: Some("got a sec".into()),
                    attachment: None, confidence: None, language: None, duration_ms: 0, segments: None })
            }
        }
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &mut *handle };
        engine.transcription = Arc::new(PreviewFixture);
        *engine.captured_contact.lock() = Some("Alex".into());
        *engine.pending_audio.lock() = Some(vec![7; 100]);
        *engine.pending_dictation.lock() = Some(PendingDictation { said: "previous".into(), flow_output: "previous".into(), category: "acquaintance".into(), contact_key: style::contact_key("Alex") });
        let text = CString::new("can you review the deck").unwrap();
        let app = CString::new("Messages").unwrap();
        let mut state = CallbackState { chunks: vec![], cancel: false };
        let result = flow_preview_rewrite_stream(handle, text.as_ptr(), app.as_ptr(), receive, &mut state as *mut _ as *mut c_void);
        assert!(!result.is_null());
        assert_eq!(state.chunks, ["got a sec"]);
        assert_eq!(*engine.pending_audio.lock(), Some(vec![7; 100]));
        assert_eq!(engine.pending_dictation.lock().as_ref().unwrap().said, "previous");
        assert!(engine.pending_attachment.lock().is_none());
        assert!(engine.storage.get_recent_history(10).unwrap().is_empty());
        assert!(engine.storage.get_style_examples(10).unwrap().is_empty());
        state.cancel = true;
        assert!(flow_preview_rewrite_stream(handle, text.as_ptr(), app.as_ptr(), receive, &mut state as *mut _ as *mut c_void).is_null());
        assert_eq!(engine.pending_dictation.lock().as_ref().unwrap().said, "previous");
        assert!(flow_preview_rewrite_stream(handle, ptr::null(), app.as_ptr(), receive, &mut state as *mut _ as *mut c_void).is_null());
        flow_free_string(result); flow_destroy(handle);
    }

    fn run(cancel: bool) {
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &mut *handle };
        engine.transcription = Arc::new(StreamFixture);
        *engine.pending_audio.lock() = Some(vec![0; 32000]);
        *engine.pending_sample_rate.lock() = Some(16000);
        let mut state = CallbackState { chunks: vec![], cancel };
        let app = CString::new("Messages").unwrap();
        let result = flow_transcribe_stream(handle, app.as_ptr(), receive, &mut state as *mut _ as *mut c_void);
        if cancel {
            assert!(result.is_null());
            assert_eq!(state.chunks, ["got a sec"]);
            assert!(engine.pending_dictation.lock().is_none(), "cancelled tokens became learnable");
            assert!(engine.last_audio.lock().is_some(), "failed audio should remain retryable");
        } else {
            assert!(!result.is_null());
            assert_eq!(state.chunks, ["got a sec", " to review the slides?"]);
            let pending = engine.pending_dictation.lock();
            let pending = pending.as_ref().unwrap();
            assert_eq!(pending.said, "can you review the slides");
            assert_eq!(pending.flow_output, "got a sec to review the slides?");
            assert!(engine.last_audio.lock().is_none());
            flow_free_string(result);
        }
        flow_destroy(handle);
    }

    #[test]
    fn ffi_delivers_tokens_and_preserves_raw_speech_for_send_learning() { run(false); }
    #[test]
    fn ffi_cancellation_cannot_create_a_learnable_partial_draft() { run(true); }
    #[test]
    fn supplied_audio_uses_real_streaming_and_contact_scoped_send_learning() {
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &mut *handle };
        engine.transcription = Arc::new(StreamFixture);
        let pcm = vec![0; 32000];
        let app = CString::new("Messages").unwrap();
        let contact = CString::new("Alex").unwrap();
        let mut state = CallbackState { chunks: vec![], cancel: false };
        let result = flow_transcribe_audio_stream(handle, pcm.as_ptr(), pcm.len(), 16000, app.as_ptr(), contact.as_ptr(), receive, &mut state as *mut _ as *mut c_void);
        assert!(!result.is_null());
        assert_eq!(state.chunks.len(), 2);
        assert_eq!(engine.pending_dictation.lock().as_ref().unwrap().contact_key, style::contact_key("Alex"));
        let edited = CString::new("yo can u check the deck").unwrap();
        assert_eq!(flow_record_final_text(handle, edited.as_ptr()), 0);
        assert!(engine.pending_dictation.lock().is_none());
        let examples = engine.storage.get_style_examples(10).unwrap();
        assert_eq!(examples.len(), 1);
        assert!(examples[0].edited);
        assert_eq!(examples[0].contact_key, style::contact_key("Alex"));
        let alex = style::contact_key("Alex");
        let prompt = personalization_for(engine, "check slides on Friday", "acquaintance", &alex).unwrap();
        assert!(prompt.contains("yo can u check the deck"));
        assert!(personalization_for(engine, "check slides on Friday", "acquaintance", &style::contact_key("Sam")).is_none());
        assert!(personalization_for(engine, "check slides on Friday", "acquaintance", "").is_none());
        let other_user = flow_init(db.as_ptr());
        assert!(personalization_for(unsafe { &*other_user }, "check slides on Friday", "acquaintance", &alex).is_none());
        flow_destroy(other_user);
        assert!(flow_rebuild_style_profile(handle), "recipient-only memory needs no global network rebuild");
        flow_free_string(result);
        flow_destroy(handle);
    }

    #[test]
    fn attachment_instructions_are_not_learned_as_contact_wording() {
        struct AttachmentFixture;
        #[async_trait::async_trait]
        impl TranscriptionProvider for AttachmentFixture {
            fn name(&self) -> &'static str { "attachment fixture" }
            fn is_configured(&self) -> bool { true }
            async fn transcribe(&self, _: TranscriptionRequest) -> crate::error::Result<TranscriptionResponse> { unreachable!() }
            async fn transcribe_stream(&self, _: TranscriptionRequest, callback: DictationDelta) -> crate::error::Result<TranscriptionResponse> {
                assert!(callback("here's the slides"));
                Ok(TranscriptionResponse {
                    text: "Here's the slides. Flow attach the PDF I just downloaded".into(),
                    completed_text: Some("here's the slides".into()),
                    attachment: Some(serde_json::from_value(serde_json::json!({
                        "message": "Here's the slides.", "command": "Flow attach the PDF I just downloaded",
                        "request": { "source": "recent_download", "kind": "pdf" }
                    })).unwrap()), confidence: None, language: None, duration_ms: 1000, segments: None,
                })
            }
        }
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &mut *handle };
        engine.transcription = Arc::new(AttachmentFixture);
        let pcm = vec![0; 32000];
        let app = CString::new("Messages").unwrap();
        let contact = CString::new("Alex").unwrap();
        let mut state = CallbackState { chunks: vec![], cancel: false };
        let result = flow_transcribe_audio_stream(handle, pcm.as_ptr(), pcm.len(), 16000, app.as_ptr(), contact.as_ptr(), receive, &mut state as *mut _ as *mut c_void);
        assert!(!result.is_null());
        assert_eq!(state.chunks, ["here's the slides"]);
        assert_eq!(engine.pending_dictation.lock().as_ref().unwrap().said, "Here's the slides.");
        assert!(engine.pending_attachment.lock().is_some());
        let sent = CString::new("here's the deck").unwrap();
        assert_eq!(flow_record_final_text_for_contact(handle, sent.as_ptr(), contact.as_ptr()), 0);
        let examples = engine.storage.get_style_examples(10).unwrap();
        assert_eq!(examples[0].said, "Here's the slides.");
        assert_eq!(examples[0].sent, "here's the deck");
        assert_eq!(examples[0].contact_key, style::contact_key("Alex"));
        flow_free_string(result);
        flow_destroy(handle);
    }

    #[test]
    fn changed_contact_at_send_discards_the_pending_learning_baseline() {
        let db = CString::new(":memory:").unwrap();
        let handle = flow_init(db.as_ptr());
        let engine = unsafe { &*handle };
        *engine.pending_dictation.lock() = Some(PendingDictation {
            category: "acquaintance".into(), contact_key: style::contact_key("Alex"),
            said: "review slides".into(), flow_output: "review the slides".into(),
        });
        let text = CString::new("review the deck").unwrap();
        let other = CString::new("Sam").unwrap();
        assert_eq!(flow_record_final_text_for_contact(handle, text.as_ptr(), other.as_ptr()), -1);
        assert_eq!(engine.storage.count_style_examples().unwrap(), 0);
        assert!(engine.pending_dictation.lock().is_none());
        *engine.pending_dictation.lock() = Some(PendingDictation {
            category: "acquaintance".into(), contact_key: style::contact_key("Alex"),
            said: "review slides".into(), flow_output: "review the slides".into(),
        });
        let same = CString::new("  alex  ").unwrap();
        assert_eq!(flow_record_final_text_for_contact(handle, text.as_ptr(), same.as_ptr()), 0);
        assert_eq!(engine.storage.count_style_examples().unwrap(), 1);
        flow_destroy(handle);
    }

}

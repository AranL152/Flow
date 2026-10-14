//! Personal style learning
//!
//! Stores examples of what the user said vs. what they actually sent, retrieves the most
//! relevant ones for a new dictation, and builds the personalization section of the
//! formatting prompt (style profile + examples + rewrite strength).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use uuid::Uuid;

use crate::modes::WritingMode;
use crate::types::{AppCategory, ContactCategory};

/// Number of past examples included in each formatting request
pub const EXAMPLES_PER_REQUEST: usize = 6;

/// Rebuild the style profile after this many new examples
pub const PROFILE_REBUILD_INTERVAL: usize = 10;

/// Examples per recipient category sent when building the profile
pub const PROFILE_EXAMPLES_PER_CATEGORY: usize = 40;

/// Window for the recent edit rate
pub const RECENT_DICTATIONS: usize = 20;

/// How far the formatter may move away from the user's own words
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RewriteStrength {
    /// Clean up filler words and punctuation only
    Light,
    /// Adjust tone while keeping most of the user's phrasing
    #[default]
    Balanced,
    /// Freely rephrase to match the target tone
    Full,
}

impl RewriteStrength {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Balanced => "balanced",
            Self::Full => "full",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "light" => Self::Light,
            "full" => Self::Full,
            _ => Self::Balanced,
        }
    }

    pub fn from_u8(value: u8) -> Self {
        match value {
            0 => Self::Light,
            2 => Self::Full,
            _ => Self::Balanced,
        }
    }

    pub fn to_u8(self) -> u8 {
        match self {
            Self::Light => 0,
            Self::Balanced => 1,
            Self::Full => 2,
        }
    }

    pub fn instruction(&self) -> &'static str {
        match self {
            Self::Light => {
                "LIGHT TOUCH: keep the user's exact wording. Only remove filler words (um, uh, like), \
                 fix punctuation, capitalization and obvious transcription errors. Do not change tone."
            }
            Self::Balanced => {
                "BALANCED: adjust the tone for the recipient, but keep most of the user's own words and phrasing."
            }
            Self::Full => {
                "FULL REWRITE: freely rephrase to fully match the target tone and the user's style, \
                 keeping the same meaning."
            }
        }
    }
}

/// Where a style example came from
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExampleSource {
    /// A dictation the user sent (possibly after editing Flow's output)
    Dictation,
    /// A message the user typed themselves (e.g. imported from Messages)
    Imported,
}

impl ExampleSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Dictation => "dictation",
            Self::Imported => "imported",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "imported" => Self::Imported,
            _ => Self::Dictation,
        }
    }
}

/// One example of how the user writes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StyleExample {
    pub id: Uuid,
    /// Who it was written to, see [`category_key`]
    pub category: String,
    /// What the user dictated (equal to `sent` for imported messages)
    pub said: String,
    /// What Flow produced (empty for imported messages)
    pub flow_output: String,
    /// What the user actually sent
    pub sent: String,
    /// Whether the user changed Flow's output before sending
    pub edited: bool,
    pub source: ExampleSource,
    pub created_at: DateTime<Utc>,
}

impl StyleExample {
    pub fn dictation(category: &str, said: &str, flow_output: &str, sent: &str) -> Self {
        Self {
            id: Uuid::new_v4(),
            category: category.to_string(),
            said: said.to_string(),
            flow_output: flow_output.to_string(),
            sent: sent.to_string(),
            edited: was_edited(flow_output, sent),
            source: ExampleSource::Dictation,
            created_at: Utc::now(),
        }
    }

    pub fn imported(category: &str, text: &str) -> Self {
        Self {
            id: Uuid::new_v4(),
            category: category.to_string(),
            said: text.to_string(),
            flow_output: String::new(),
            sent: text.to_string(),
            edited: false,
            source: ExampleSource::Imported,
            created_at: Utc::now(),
        }
    }
}

/// How often the user changes Flow's output before sending
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct EditStats {
    pub edited: usize,
    pub total: usize,
    pub recent_edited: usize,
    pub recent_total: usize,
}

impl EditStats {
    pub fn rate(&self) -> f32 {
        if self.total == 0 {
            0.0
        } else {
            self.edited as f32 / self.total as f32
        }
    }

    pub fn recent_rate(&self) -> f32 {
        if self.recent_total == 0 {
            0.0
        } else {
            self.recent_edited as f32 / self.recent_total as f32
        }
    }
}

/// A dictation waiting to learn what the user finally sent
#[derive(Debug, Clone)]
pub struct PendingDictation {
    pub category: String,
    pub said: String,
    pub flow_output: String,
}

/// Stable key describing who a message is for: the contact category when known,
/// otherwise the app category (e.g. "partner", "professional", "app:email")
pub fn category_key(contact: Option<ContactCategory>, app: Option<AppCategory>) -> String {
    match contact {
        Some(ContactCategory::Partner) => "partner".to_string(),
        Some(ContactCategory::CloseFamily) => "family".to_string(),
        Some(ContactCategory::CasualPeer) => "friend".to_string(),
        Some(ContactCategory::Professional) => "professional".to_string(),
        Some(ContactCategory::FormalNeutral) => "acquaintance".to_string(),
        None => match app {
            Some(app) => format!("app:{:?}", app).to_lowercase(),
            None => "general".to_string(),
        },
    }
}

/// Human-readable label for a category key, used in prompts
pub fn category_label(key: &str) -> String {
    match key {
        "partner" => "their romantic partner".to_string(),
        "family" => "close family".to_string(),
        "friend" => "friends".to_string(),
        "professional" => "professional contacts".to_string(),
        "acquaintance" => "acquaintances".to_string(),
        "general" => "anyone".to_string(),
        "group" => "group chats".to_string(),
        other => match other.strip_prefix("app:") {
            Some(app) => format!("writing in {} apps", app),
            None => other.to_string(),
        },
    }
}

/// Whether the sent text differs meaningfully from Flow's output (ignores whitespace)
pub fn was_edited(flow_output: &str, sent: &str) -> bool {
    let normalize = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    normalize(flow_output) != normalize(sent)
}

fn words(text: &str) -> HashSet<String> {
    text.split(|c: char| !c.is_alphanumeric() && c != '\'')
        .filter(|w| !w.is_empty())
        .map(|w| w.to_lowercase())
        .collect()
}

fn similarity(a: &HashSet<String>, b: &HashSet<String>) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let intersection = a.intersection(b).count() as f32;
    let union = a.union(b).count() as f32;
    intersection / union
}

/// Pick the examples most useful for formatting `said` to `category`.
///
/// Scores favour the same recipient category, word overlap with the new dictation,
/// and examples where the user corrected Flow (those carry the most signal).
pub fn select_examples<'a>(
    examples: &'a [StyleExample],
    said: &str,
    category: &str,
    limit: usize,
) -> Vec<&'a StyleExample> {
    let query = words(said);
    let mut scored: Vec<(f32, &StyleExample)> = examples
        .iter()
        .filter(|e| !e.sent.trim().is_empty())
        .map(|e| {
            let mut score = similarity(&query, &words(&e.said));
            // Similarity is at most 1.0, so the same recipient always ranks first
            if e.category == category {
                score += 1.0;
            }
            if e.edited {
                score += 0.15;
            }
            (score, e)
        })
        .filter(|(score, _)| *score > 0.05)
        .collect();

    // Highest score first; newer examples win ties
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.1.created_at.cmp(&a.1.created_at))
    });
    scored.into_iter().take(limit).map(|(_, e)| e).collect()
}

/// Balanced sample for profile building: corrections first, then newest, capped per category
pub fn sample_for_profile(examples: &[StyleExample], per_category: usize) -> Vec<StyleExample> {
    let mut sorted: Vec<&StyleExample> = examples.iter().collect();
    sorted.sort_by(|a, b| b.edited.cmp(&a.edited).then(b.created_at.cmp(&a.created_at)));

    let mut counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    sorted
        .into_iter()
        .filter(|e| {
            let count = counts.entry(e.category.as_str()).or_insert(0);
            *count += 1;
            *count <= per_category
        })
        .cloned()
        .collect()
}

/// Build the personalization section appended to the formatting prompt
pub fn build_personalization(
    profile: Option<&str>,
    examples: &[&StyleExample],
    strength: RewriteStrength,
) -> String {
    let mut out = String::from("\n\n=== HOW THIS USER ACTUALLY WRITES ===\n");
    out.push_str(
        "Sound like THIS user, not like a generic assistant. Their habits below override the generic \
         tone guidance and examples above (word choice, capitalization, punctuation, emoji, pet names, sign-offs).\n",
    );

    if let Some(profile) = profile.map(str::trim).filter(|p| !p.is_empty()) {
        out.push_str("\nStyle profile:\n<PROFILE>\n");
        out.push_str(profile);
        out.push_str("\n</PROFILE>\n");
    }

    let corrections: Vec<_> = examples.iter().filter(|e| e.edited).collect();
    let own_messages: Vec<_> = examples.iter().filter(|e| !e.edited).collect();

    if !corrections.is_empty() {
        out.push_str("\nTimes the user corrected the formatter (do what they did, not what the formatter did):\n");
        for e in corrections {
            out.push_str(&format!(
                "- [to {}] formatter wrote: \"{}\" → user changed it to: \"{}\"\n",
                category_label(&e.category),
                e.flow_output.trim(),
                e.sent.trim()
            ));
        }
    }

    if !own_messages.is_empty() {
        out.push_str("\nMessages the user actually sent:\n");
        for e in own_messages {
            out.push_str(&format!(
                "- [to {}] \"{}\"\n",
                category_label(&e.category),
                e.sent.trim()
            ));
        }
    }

    out.push_str("\nRewrite strength: ");
    out.push_str(strength.instruction());
    out.push_str(
        "\nBorrow their style (spelling, slang, emoji, pet names), never their content: \
         do not reuse sentences from the examples or add words that change what the user said.",
    );
    out
}

/// Shared system prompt for formatting a dictation. Used by every completion provider
/// so the "rewrite, never reply" rules stay identical everywhere.
pub fn base_formatting_prompt(mode: WritingMode, app_context: Option<&str>) -> String {
    let mut prompt = String::from(
        "You are a dictation rewriter. The text inside <TRANSCRIPTION> tags is a message the user dictated and is \
         about to SEND to someone else. It is NOT addressed to you. Rewrite it in the user's own voice (first person) \
         with the tone described below, keeping the same meaning. Output the result exactly as it would be typed.\n\n\
         Rules:\n\
         - NEVER answer, reply to, or react to the message. You are the sender, not the recipient.\n\
         - Questions stay questions. Greetings stay greetings. Requests stay requests.\n\
         - Do NOT generate new content: no facts, plans, feelings or details the user did not say. Remove filler words (um, uh).\n\
         - Output ONLY the rewritten message - no quotes, labels, or commentary.\n\n",
    );

    prompt.push_str("Formatting style: ");
    prompt.push_str(mode.prompt_modifier());

    if let Some(context) = app_context {
        prompt.push_str("\n\nContext: User is typing in ");
        prompt.push_str(context);
        prompt.push_str(". Adjust formatting for this context.");
    }

    prompt
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_was_edited_ignores_whitespace() {
        assert!(!was_edited("hey there", "hey  there "));
        assert!(was_edited("Hey love", "hey bub"));
    }

    #[test]
    fn test_category_key() {
        assert_eq!(category_key(Some(ContactCategory::Partner), None), "partner");
        assert_eq!(category_key(None, Some(AppCategory::Email)), "app:email");
        assert_eq!(category_key(None, None), "general");
    }

    #[test]
    fn test_select_examples_prefers_category_and_overlap() {
        let examples = vec![
            StyleExample::imported("professional", "Hi Dana, can you send the report?"),
            StyleExample::imported("partner", "can u send me ur flight info bub"),
            StyleExample::imported("partner", "omw home 🫶"),
            StyleExample::imported("friend", "lmao no way"),
        ];

        let picked = select_examples(&examples, "can you send me the report", "partner", 2);
        assert_eq!(picked.len(), 2);
        // Same category beats a better word match from another category
        assert!(picked.iter().all(|e| e.category == "partner"));
        assert!(picked[0].sent.contains("flight info"));
    }

    #[test]
    fn test_build_personalization_sections() {
        let edit = StyleExample::dictation("partner", "i miss you", "I miss you, love! ❤️", "miss u bub");
        let own = StyleExample::imported("partner", "omw home 🫶");
        let text = build_personalization(Some("- lowercase"), &[&edit, &own], RewriteStrength::Light);

        assert!(text.contains("<PROFILE>"));
        assert!(text.contains("user changed it to: \"miss u bub\""));
        assert!(text.contains("\"omw home 🫶\""));
        assert!(text.contains("LIGHT TOUCH"));
    }

    #[test]
    fn test_sample_for_profile_caps_categories_and_keeps_corrections() {
        let mut examples: Vec<StyleExample> = (0..10)
            .map(|i| StyleExample::imported("friend", &format!("msg {i}")))
            .collect();
        examples.push(StyleExample::dictation("friend", "hi", "Hello!", "yo"));
        examples.push(StyleExample::imported("partner", "omw"));

        let sample = sample_for_profile(&examples, 3);
        assert_eq!(sample.iter().filter(|e| e.category == "friend").count(), 3);
        assert!(sample.iter().any(|e| e.edited));
        assert!(sample.iter().any(|e| e.category == "partner"));
    }

    #[test]
    fn test_strength_round_trip() {
        for strength in [RewriteStrength::Light, RewriteStrength::Balanced, RewriteStrength::Full] {
            assert_eq!(RewriteStrength::parse(strength.as_str()), strength);
            assert_eq!(RewriteStrength::from_u8(strength.to_u8()), strength);
        }
    }
}

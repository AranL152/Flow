//! Self-learning typo correction engine
//!
//! Learns from user corrections when they edit transcribed text.
//!
//! Two algorithms do the work, each where it is strongest:
//! - **Jaro-Winkler** detects which word pairs in an edit are typo fixes. It
//!   favours strings agreeing at the start, which is the usual shape of a
//!   dictation typo ("recieve"/"receive"), and is cheap on short words.
//! - **Aho-Corasick** applies the learned vocabulary. Every cached correction is
//!   compiled into one automaton, so applying them is a single O(n) pass over
//!   the text no matter how many corrections exist, instead of a per-word hash
//!   lookup. Matches are validated against word boundaries and the text between
//!   matches is copied verbatim, so original spacing and newlines survive.

use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};
use parking_lot::RwLock;
use std::collections::HashMap;
use strsim::jaro_winkler;
use tracing::{debug, info};

use crate::error::Result;
use crate::storage::Storage;
use crate::types::{Correction, CorrectionSource};

/// Minimum similarity threshold for considering a word pair as a typo correction
const MIN_SIMILARITY: f64 = 0.7;

/// Minimum similarity for word alignment (lower threshold for pairing)
const MIN_ALIGNMENT_SIMILARITY: f64 = 0.5;

/// Minimum confidence to auto-apply a correction (lowered to 0.55 to trigger at ~3 occurrences instead of ~5)
const MIN_AUTO_APPLY_CONFIDENCE: f32 = 0.55;

/// Maximum word length difference to consider a correction (set to 1 for exact wrong words like "there"/"their")
const MAX_LENGTH_DIFF: usize = 1;

/// Engine for learning and applying typo corrections
pub struct LearningEngine {
    /// In-memory cache of high-confidence corrections (original -> corrected).
    /// Keys are always lowercase so lookups and automaton matching agree.
    corrections: RwLock<HashMap<String, CachedCorrection>>,
    /// Compiled Aho-Corasick automaton over the eligible correction keys.
    /// Rebuilt whenever the cache changes, so applying is build-free.
    matcher: RwLock<Option<CorrectionMatcher>>,
    /// Minimum confidence for auto-applying corrections
    min_confidence: f32,
}

#[derive(Debug, Clone)]
struct CachedCorrection {
    corrected: String,
    confidence: f32,
}

/// An Aho-Corasick automaton plus the replacement for each pattern index.
struct CorrectionMatcher {
    automaton: AhoCorasick,
    /// Indexed by pattern id from the automaton
    replacements: Vec<CachedCorrection>,
}

impl LearningEngine {
    /// Create a new learning engine
    pub fn new() -> Self {
        Self {
            corrections: RwLock::new(HashMap::new()),
            matcher: RwLock::new(None),
            min_confidence: MIN_AUTO_APPLY_CONFIDENCE,
        }
    }

    /// Create engine and load corrections from storage
    pub fn from_storage(storage: &Storage) -> Result<Self> {
        let engine = Self::new();
        let corrections = storage.get_corrections(MIN_AUTO_APPLY_CONFIDENCE)?;

        let mut cache = engine.corrections.write();
        for correction in corrections {
            cache.insert(
                correction.original.to_lowercase(),
                CachedCorrection {
                    corrected: correction.corrected,
                    confidence: correction.confidence,
                },
            );
        }
        drop(cache);

        engine.rebuild_matcher();

        info!(
            "Loaded {} corrections into learning engine",
            engine.corrections.read().len()
        );

        Ok(engine)
    }

    /// Set the minimum confidence threshold for auto-applying corrections
    pub fn set_min_confidence(&mut self, confidence: f32) {
        self.min_confidence = confidence.clamp(0.0, 1.0);
        self.rebuild_matcher();
    }

    /// Compile the eligible cache entries into a single automaton.
    /// Returns None when nothing is eligible, which makes applying a no-op.
    fn build_matcher(
        cache: &HashMap<String, CachedCorrection>,
        min_confidence: f32,
    ) -> Option<CorrectionMatcher> {
        let mut patterns: Vec<&str> = Vec::with_capacity(cache.len());
        let mut replacements: Vec<CachedCorrection> = Vec::with_capacity(cache.len());

        for (original, correction) in cache {
            if original.is_empty() || correction.confidence < min_confidence {
                continue;
            }
            patterns.push(original.as_str());
            replacements.push(correction.clone());
        }

        if patterns.is_empty() {
            return None;
        }

        // LeftmostLongest so the longest correction wins when keys overlap.
        let automaton = AhoCorasickBuilder::new()
            .match_kind(MatchKind::LeftmostLongest)
            .build(&patterns)
            .ok()?;

        Some(CorrectionMatcher {
            automaton,
            replacements,
        })
    }

    /// Rebuild the automaton from the current cache. Call after any cache change.
    fn rebuild_matcher(&self) {
        let matcher = {
            let cache = self.corrections.read();
            Self::build_matcher(&cache, self.min_confidence)
        };
        *self.matcher.write() = matcher;
    }

    /// Build the automaton on demand if it was never built but the cache has entries.
    fn ensure_matcher(&self) {
        if self.matcher.read().is_some() {
            return;
        }
        if self.corrections.read().is_empty() {
            return;
        }
        self.rebuild_matcher();
    }

    /// Learn from a before/after text comparison
    /// Detects word-level changes and records them as potential corrections
    pub fn learn_from_edit(
        &self,
        original: &str,
        edited: &str,
        storage: &Storage,
    ) -> Result<Vec<LearnedCorrection>> {
        let original_words: Vec<&str> = original.split_whitespace().collect();
        let edited_words: Vec<&str> = edited.split_whitespace().collect();

        let mut learned = Vec::new();
        let mut cache_changed = false;

        // use edit distance alignment to find corresponding words
        let pairs = align_words(&original_words, &edited_words);

        for (orig, edit) in pairs {
            // skip if same
            if orig.eq_ignore_ascii_case(edit) {
                continue;
            }

            // check if this looks like a typo correction (high similarity)
            let similarity = jaro_winkler(orig, edit);

            if similarity >= MIN_SIMILARITY {
                // check length difference
                let len_diff = (orig.len() as isize - edit.len() as isize).unsigned_abs();
                if len_diff > MAX_LENGTH_DIFF {
                    continue;
                }

                // this looks like a typo correction
                let mut correction = Correction::new(
                    orig.to_lowercase(),
                    edit.to_string(),
                    CorrectionSource::UserEdit,
                );

                // save or update in storage (will increment occurrences if exists)
                storage.save_correction(&correction)?;

                // update cache if confidence is high enough
                correction.update_confidence();
                if correction.confidence >= self.min_confidence {
                    let mut cache = self.corrections.write();
                    cache.insert(
                        correction.original.clone(),
                        CachedCorrection {
                            corrected: correction.corrected.clone(),
                            confidence: correction.confidence,
                        },
                    );
                    cache_changed = true;
                }

                debug!(
                    "Learned correction: '{}' -> '{}' (similarity: {:.2})",
                    orig, edit, similarity
                );

                learned.push(LearnedCorrection {
                    original: orig.to_string(),
                    corrected: edit.to_string(),
                    similarity,
                });
            }
        }

        if cache_changed {
            self.rebuild_matcher();
        }

        Ok(learned)
    }

    /// Apply learned corrections to text
    ///
    /// Runs the compiled automaton once over the text. Only whole-word matches
    /// above the confidence threshold are replaced, the case pattern of the
    /// original word is preserved, and every byte between matches (including
    /// newlines and repeated spaces) is copied through untouched.
    pub fn apply_corrections(&self, text: &str) -> (String, Vec<AppliedCorrection>) {
        self.ensure_matcher();

        let matcher_guard = self.matcher.read();
        let Some(matcher) = matcher_guard.as_ref() else {
            return (text.to_string(), Vec::new());
        };

        // Match on lowercased text; byte offsets map back onto the original.
        let text_lower = text.to_lowercase();
        let mut matches = matcher.automaton.find_iter(&text_lower).peekable();

        if matches.peek().is_none() {
            return (text.to_string(), Vec::new());
        }

        let mut applied = Vec::with_capacity(4);
        let mut result = String::with_capacity(text.len() + text.len() / 8);
        let mut last_end = 0;

        for m in matches {
            let (start, end) = (m.start(), m.end());

            // Only correct standalone words, never a fragment inside one.
            if !is_whole_word(&text_lower, start, end) {
                continue;
            }

            let replacement = &matcher.replacements[m.pattern().as_usize()];
            if replacement.confidence < self.min_confidence {
                continue;
            }

            // Offsets come from the lowercased copy; guard against any
            // multi-byte casing that shifted them before slicing.
            let Some(original_slice) = text.get(start..end) else {
                continue;
            };

            let corrected = match_case(&replacement.corrected, original_slice);

            result.push_str(&text[last_end..start]);
            result.push_str(&corrected);

            applied.push(AppliedCorrection {
                original: original_slice.to_string(),
                corrected,
                confidence: replacement.confidence,
                position: start,
            });

            last_end = end;
        }

        result.push_str(&text[last_end..]);

        if !applied.is_empty() {
            debug!("Applied {} corrections to text", applied.len());
        }

        (result, applied)
    }

    /// Check if we have a correction for a word
    pub fn has_correction(&self, word: &str) -> bool {
        let cache = self.corrections.read();
        cache.contains_key(&word.to_lowercase())
    }

    /// Get the correction for a word if available
    pub fn get_correction(&self, word: &str) -> Option<String> {
        let cache = self.corrections.read();
        cache
            .get(&word.to_lowercase())
            .filter(|c| c.confidence >= self.min_confidence)
            .map(|c| c.corrected.clone())
    }

    /// Get all cached corrections
    pub fn get_all_corrections(&self) -> Vec<(String, String, f32)> {
        self.corrections
            .read()
            .iter()
            .map(|(orig, c)| (orig.clone(), c.corrected.clone(), c.confidence))
            .collect()
    }

    /// Clear all cached corrections
    pub fn clear_cache(&self) {
        self.corrections.write().clear();
        self.rebuild_matcher();
    }

    /// Get the number of cached corrections
    pub fn cache_size(&self) -> usize {
        self.corrections.read().len()
    }

    /// Remove a correction from the cache by original word
    pub fn remove_from_cache(&self, original: &str) {
        self.corrections.write().remove(&original.to_lowercase());
        self.rebuild_matcher();
    }

    /// Reload corrections from storage (useful after deleting)
    pub fn reload_from_storage(
        &self,
        storage: &crate::storage::Storage,
    ) -> crate::error::Result<()> {
        let corrections = storage.get_corrections(self.min_confidence)?;

        let mut cache = self.corrections.write();
        cache.clear();
        for correction in corrections {
            cache.insert(
                correction.original.to_lowercase(),
                CachedCorrection {
                    corrected: correction.corrected,
                    confidence: correction.confidence,
                },
            );
        }

        info!("Reloaded {} corrections into learning engine", cache.len());
        drop(cache);

        self.rebuild_matcher();

        Ok(())
    }
}

impl Default for LearningEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// A correction that was learned from user edits
#[derive(Debug, Clone)]
pub struct LearnedCorrection {
    pub original: String,
    pub corrected: String,
    pub similarity: f64,
}

/// A correction that was applied to text
#[derive(Debug, Clone)]
pub struct AppliedCorrection {
    pub original: String,
    pub corrected: String,
    pub confidence: f32,
    pub position: usize,
}

/// Align words from two texts using a simple diff algorithm
/// Optimized with early exits and reduced redundant similarity calculations
fn align_words<'a>(original: &[&'a str], edited: &[&'a str]) -> Vec<(&'a str, &'a str)> {
    // Early exit for empty inputs
    if original.is_empty() || edited.is_empty() {
        return Vec::new();
    }

    // Pre-allocate with expected capacity (most words will pair)
    let mut pairs = Vec::with_capacity(original.len().min(edited.len()));

    let mut orig_idx = 0;
    let mut edit_idx = 0;
    let orig_len = original.len();
    let edit_len = edited.len();

    while orig_idx < orig_len && edit_idx < edit_len {
        let orig = original[orig_idx];
        let edit = edited[edit_idx];

        // Quick check: if strings are equal, no need to compute similarity
        if orig.eq_ignore_ascii_case(edit) {
            pairs.push((orig, edit));
            orig_idx += 1;
            edit_idx += 1;
            continue;
        }

        // Compute similarity for current pair
        let sim = jaro_winkler(orig, edit);

        if sim >= MIN_ALIGNMENT_SIMILARITY {
            pairs.push((orig, edit));
            orig_idx += 1;
            edit_idx += 1;
        } else {
            // Only compute lookahead similarities if needed
            let has_next_orig = orig_idx + 1 < orig_len;
            let has_next_edit = edit_idx + 1 < edit_len;

            let skip_orig = has_next_orig && jaro_winkler(original[orig_idx + 1], edit) > sim;
            let skip_edit = has_next_edit && jaro_winkler(orig, edited[edit_idx + 1]) > sim;

            match (skip_orig, skip_edit) {
                (true, false) => orig_idx += 1,
                (false, true) => edit_idx += 1,
                _ => {
                    orig_idx += 1;
                    edit_idx += 1;
                }
            }
        }
    }

    pairs
}

/// Whether the span is a standalone word rather than part of a longer one.
///
/// Aho-Corasick reports every substring hit, so without this a correction like
/// "cant" -> "can't" would also fire inside "cantaloupe". Punctuation and
/// whitespace both count as boundaries, which is what lets "teh," be corrected.
#[inline]
fn is_whole_word(text: &str, start: usize, end: usize) -> bool {
    let before_ok = text[..start]
        .chars()
        .next_back()
        .is_none_or(|c| !c.is_alphanumeric());
    let after_ok = text[end..]
        .chars()
        .next()
        .is_none_or(|c| !c.is_alphanumeric());

    before_ok && after_ok
}

/// Try to match the case pattern of the original word
/// Optimized to minimize allocations and iterations
#[inline]
fn match_case(corrected: &str, original: &str) -> String {
    // Early exit for empty strings
    if original.is_empty() || corrected.is_empty() {
        return corrected.to_string();
    }

    let mut chars = original.chars();
    let first_char = chars.next().unwrap();

    // Check case pattern with single pass
    if first_char.is_uppercase() {
        let rest_lowercase = chars.all(|c| !c.is_alphabetic() || c.is_lowercase());

        if rest_lowercase {
            // Title case: capitalize first letter only
            let mut result = String::with_capacity(corrected.len());
            let mut corrected_chars = corrected.chars();

            if let Some(first) = corrected_chars.next() {
                for c in first.to_uppercase() {
                    result.push(c);
                }
                for c in corrected_chars {
                    for lc in c.to_lowercase() {
                        result.push(lc);
                    }
                }
            }
            result
        } else {
            // Check if ALL CAPS
            let all_upper = original.chars().all(|c| !c.is_alphabetic() || c.is_uppercase());
            if all_upper {
                corrected.to_uppercase()
            } else {
                corrected.to_string()
            }
        }
    } else {
        // Original starts with lowercase, preserve corrected case
        corrected.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_apply_corrections() {
        let engine = LearningEngine::new();

        // manually add a correction to cache
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );

            cache.insert(
                "recieve".to_string(),
                CachedCorrection {
                    corrected: "receive".to_string(),
                    confidence: 0.9,
                },
            );
        }

        let (result, applied) = engine.apply_corrections("I will recieve teh package");

        assert_eq!(result, "I will receive the package");
        assert_eq!(applied.len(), 2);
    }

    #[test]
    fn test_case_matching() {
        assert_eq!(match_case("the", "TEH"), "THE");
        assert_eq!(match_case("the", "Teh"), "The");
        assert_eq!(match_case("the", "teh"), "the");
    }

    #[test]
    fn test_word_alignment() {
        let original = vec!["I", "recieve", "teh", "mail"];
        let edited = vec!["I", "receive", "the", "mail"];

        let pairs = align_words(&original, &edited);

        assert_eq!(pairs.len(), 4);
        assert_eq!(pairs[1], ("recieve", "receive"));
        assert_eq!(pairs[2], ("teh", "the"));
    }

    #[test]
    fn test_similarity_threshold() {
        // "hello" and "world" are very different
        let sim = jaro_winkler("hello", "world");
        assert!(sim < MIN_SIMILARITY);

        // "recieve" and "receive" are similar
        let sim = jaro_winkler("recieve", "receive");
        assert!(sim >= MIN_SIMILARITY);
    }

    #[test]
    fn test_confidence_below_threshold() {
        let mut engine = LearningEngine::new();
        engine.set_min_confidence(0.9);

        // add a low-confidence correction
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "foo".to_string(),
                CachedCorrection {
                    corrected: "bar".to_string(),
                    confidence: 0.5, // below threshold
                },
            );
        }

        let (result, applied) = engine.apply_corrections("test foo here");

        // should not be applied
        assert_eq!(result, "test foo here");
        assert!(applied.is_empty());
    }

    /// Helper: engine with a single high-confidence correction.
    fn engine_with(original: &str, corrected: &str) -> LearningEngine {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                original.to_string(),
                CachedCorrection {
                    corrected: corrected.to_string(),
                    confidence: 0.95,
                },
            );
        }
        engine.rebuild_matcher();
        engine
    }

    #[test]
    fn test_preserves_original_formatting() {
        let engine = engine_with("teh", "the");

        // newlines and repeated spaces must survive the correction pass
        let (result, applied) = engine.apply_corrections("teh first\n\nteh  second");

        assert_eq!(result, "the first\n\nthe  second");
        assert_eq!(applied.len(), 2);
    }

    #[test]
    fn test_corrects_punctuation_adjacent_words() {
        let engine = engine_with("teh", "the");

        let (result, applied) = engine.apply_corrections("send teh, and (teh) too.");

        assert_eq!(result, "send the, and (the) too.");
        assert_eq!(applied.len(), 2);
    }

    #[test]
    fn test_does_not_correct_inside_longer_word() {
        let engine = engine_with("cant", "can't");

        // "cant" appears inside "cantaloupe" but must not be touched
        let (result, applied) = engine.apply_corrections("a cantaloupe i cant eat");

        assert_eq!(result, "a cantaloupe i can't eat");
        assert_eq!(applied.len(), 1);
    }

    #[test]
    fn test_preserves_case_on_match() {
        let engine = engine_with("teh", "the");

        let (result, _) = engine.apply_corrections("Teh start and TEH end");

        assert_eq!(result, "The start and THE end");
    }

    #[test]
    fn test_matcher_resyncs_after_removal() {
        let engine = engine_with("teh", "the");
        assert_eq!(engine.apply_corrections("teh cat").0, "the cat");

        engine.remove_from_cache("teh");

        // automaton must no longer contain the removed correction
        assert_eq!(engine.apply_corrections("teh cat").0, "teh cat");
        assert_eq!(engine.cache_size(), 0);
    }

    #[test]
    fn test_longest_correction_wins_on_overlap() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            for (orig, corrected) in [("ab", "X"), ("abc", "Y")] {
                cache.insert(
                    orig.to_string(),
                    CachedCorrection {
                        corrected: corrected.to_string(),
                        confidence: 0.95,
                    },
                );
            }
        }
        engine.rebuild_matcher();

        // "abc" is a whole word, so the longer key must win
        assert_eq!(engine.apply_corrections("abc").0, "Y");
    }
}

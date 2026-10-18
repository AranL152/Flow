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

        for (orig, edit, similarity) in pairs {
            // skip if same
            if orig.eq_ignore_ascii_case(edit) {
                continue;
            }

            // similarity was already measured during alignment
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

/// Align words from two texts using a simple diff algorithm.
///
/// Returns each pair together with its Jaro-Winkler similarity, so callers can
/// reuse the score instead of measuring the same pair a second time.
/// Identical words are reported as 1.0 without running the comparison.
fn align_words<'a>(original: &[&'a str], edited: &[&'a str]) -> Vec<(&'a str, &'a str, f64)> {
    // Early exit for empty inputs
    if original.is_empty() || edited.is_empty() {
        return Vec::new();
    }

    let mut pairs = Vec::new();

    // simple approach: match by position with some tolerance for insertions/deletions
    let mut orig_idx = 0;
    let mut edit_idx = 0;

    while orig_idx < original.len() && edit_idx < edited.len() {
        let orig = original[orig_idx];
        let edit = edited[edit_idx];

        // skip the Jaro-Winkler call if the strings already match
        if orig.eq_ignore_ascii_case(edit) {
            pairs.push((orig, edit, 1.0));
            orig_idx += 1;
            edit_idx += 1;
            continue;
        }

        // if they're similar enough, consider them a pair
        let sim = jaro_winkler(orig, edit);

        if sim >= MIN_ALIGNMENT_SIMILARITY {
            pairs.push((orig, edit, sim));
            orig_idx += 1;
            edit_idx += 1;
        } else {
            // check if the original word was deleted (next edit word matches next orig word better)
            let skip_orig = if orig_idx + 1 < original.len() {
                jaro_winkler(original[orig_idx + 1], edit) > sim
            } else {
                false
            };

            // check if a word was inserted (current orig matches next edit word better)
            let skip_edit = if edit_idx + 1 < edited.len() {
                jaro_winkler(orig, edited[edit_idx + 1]) > sim
            } else {
                false
            };

            if skip_orig && !skip_edit {
                orig_idx += 1;
            } else if skip_edit && !skip_orig {
                edit_idx += 1;
            } else {
                // no good match, skip both
                orig_idx += 1;
                edit_idx += 1;
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
fn match_case(corrected: &str, original: &str) -> String {
    if original.is_empty() || corrected.is_empty() {
        return corrected.to_string();
    }

    if original.chars().all(|c| c.is_uppercase()) {
        // all caps
        corrected.to_uppercase()
    } else if original.chars().next().is_some_and(|c| c.is_uppercase())
        && original.chars().skip(1).all(|c| c.is_lowercase())
    {
        // title case
        let mut chars = corrected.chars();
        match chars.next() {
            None => String::new(),
            Some(first) => first
                .to_uppercase()
                .chain(chars.flat_map(|c| c.to_lowercase()))
                .collect(),
        }
    } else {
        // preserve corrected case
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
        assert_eq!((pairs[1].0, pairs[1].1), ("recieve", "receive"));
        assert_eq!((pairs[2].0, pairs[2].1), ("teh", "the"));
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

    // ========== Additional comprehensive tests ==========

    #[test]
    fn test_match_case_empty_strings() {
        // When corrected is empty, returns empty regardless of original's case
        assert_eq!(match_case("", "TEH"), "");
        assert_eq!(match_case("", ""), "");

        assert_eq!(match_case("test", ""), "test");
    }

    #[test]
    fn test_match_case_mixed_case_original() {
        // when original has mixed case that isn't title case, preserve corrected's case
        assert_eq!(match_case("receive", "rEcIeVe"), "receive");
        assert_eq!(match_case("HELLO", "hElLo"), "HELLO"); // original is all caps in this context
    }

    #[test]
    fn test_match_case_unicode() {
        // unicode characters should not break case matching
        assert_eq!(match_case("café", "CAFÉ"), "CAFÉ");
        assert_eq!(match_case("naïve", "Naïve"), "Naïve");
    }

    #[test]
    fn test_align_words_with_insertion() {
        // when a word is inserted in the edited version
        let original = vec!["I", "the", "mail"];
        let edited = vec!["I", "received", "the", "mail"];

        let pairs = align_words(&original, &edited);

        // alignment should handle insertion gracefully
        // the algorithm should skip "received" and align remaining words
        assert!(!pairs.is_empty());
    }

    #[test]
    fn test_align_words_with_deletion() {
        // when a word is deleted in the edited version
        let original = vec!["I", "really", "love", "mail"];
        let edited = vec!["I", "love", "mail"];

        let pairs = align_words(&original, &edited);

        // should handle deletion and still align remaining words
        assert!(!pairs.is_empty());
    }

    #[test]
    fn test_align_words_completely_different() {
        // completely different texts
        let original = vec!["hello", "world"];
        let edited = vec!["foo", "bar", "baz"];

        let pairs = align_words(&original, &edited);

        // should handle gracefully even if no good matches
        // the algorithm may still produce pairs based on position
        // just verify it doesn't panic
        let _ = pairs;
    }

    #[test]
    fn test_align_words_empty_inputs() {
        let empty: Vec<&str> = vec![];

        // empty original
        let pairs = align_words(&empty, &["hello"]);
        assert!(pairs.is_empty());

        // empty edited
        let pairs = align_words(&["hello"], &empty);
        assert!(pairs.is_empty());

        // both empty
        let pairs = align_words(&empty, &empty);
        assert!(pairs.is_empty());
    }

    #[test]
    fn test_apply_corrections_empty_text() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        let (result, applied) = engine.apply_corrections("");
        assert_eq!(result, "");
        assert!(applied.is_empty());
    }

    #[test]
    fn test_apply_corrections_whitespace_only() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        let (result, applied) = engine.apply_corrections("   \t\n  ");
        // split_whitespace produces no words, original text preserved
        assert_eq!(result, "   \t\n  ");
        assert!(applied.is_empty());
    }

    #[test]
    fn test_apply_corrections_no_cache() {
        let engine = LearningEngine::new();
        // cache is empty

        let (result, applied) = engine.apply_corrections("this is some text");
        assert_eq!(result, "this is some text");
        assert!(applied.is_empty());
    }

    #[test]
    fn test_apply_corrections_preserves_word_order() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "aaa".to_string(),
                CachedCorrection {
                    corrected: "AAA".to_string(),
                    confidence: 0.95,
                },
            );
            cache.insert(
                "bbb".to_string(),
                CachedCorrection {
                    corrected: "BBB".to_string(),
                    confidence: 0.95,
                },
            );
        }

        let (result, applied) = engine.apply_corrections("bbb comes before aaa here");
        assert_eq!(result, "BBB comes before AAA here");
        assert_eq!(applied.len(), 2);
        assert_eq!(applied[0].position, 0); // bbb is at position 0
        assert_eq!(applied[1].position, 17); // byte offset of aaa in the original text
    }

    #[test]
    fn test_has_correction() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        assert!(engine.has_correction("teh"));
        assert!(engine.has_correction("TEH")); // case-insensitive lookup
        assert!(engine.has_correction("Teh"));
        assert!(!engine.has_correction("the"));
        assert!(!engine.has_correction("xyz"));
    }

    #[test]
    fn test_get_correction() {
        let mut engine = LearningEngine::new();
        engine.set_min_confidence(0.5);

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
                "low".to_string(),
                CachedCorrection {
                    corrected: "HIGH".to_string(),
                    confidence: 0.3, // below threshold
                },
            );
        }

        assert_eq!(engine.get_correction("teh"), Some("the".to_string()));
        assert_eq!(engine.get_correction("TEH"), Some("the".to_string())); // case-insensitive
        assert_eq!(engine.get_correction("low"), None); // below confidence threshold
        assert_eq!(engine.get_correction("xyz"), None);
    }

    #[test]
    fn test_get_all_corrections() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "aaa".to_string(),
                CachedCorrection {
                    corrected: "AAA".to_string(),
                    confidence: 0.9,
                },
            );
            cache.insert(
                "bbb".to_string(),
                CachedCorrection {
                    corrected: "BBB".to_string(),
                    confidence: 0.8,
                },
            );
        }

        let all = engine.get_all_corrections();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_clear_cache() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        assert_eq!(engine.cache_size(), 1);
        engine.clear_cache();
        assert_eq!(engine.cache_size(), 0);
    }

    #[test]
    fn test_remove_from_cache() {
        let engine = LearningEngine::new();
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

        assert_eq!(engine.cache_size(), 2);
        engine.remove_from_cache("teh");
        assert_eq!(engine.cache_size(), 1);
        assert!(!engine.has_correction("teh"));
        assert!(engine.has_correction("recieve"));

        // removing non-existent key is fine
        engine.remove_from_cache("nonexistent");
        assert_eq!(engine.cache_size(), 1);
    }

    #[test]
    fn test_set_min_confidence_clamp() {
        let mut engine = LearningEngine::new();

        engine.set_min_confidence(-0.5);
        assert_eq!(engine.min_confidence, 0.0);

        engine.set_min_confidence(1.5);
        assert_eq!(engine.min_confidence, 1.0);

        engine.set_min_confidence(0.7);
        assert_eq!(engine.min_confidence, 0.7);
    }

    #[test]
    fn test_default_impl() {
        let engine = LearningEngine::default();
        assert_eq!(engine.cache_size(), 0);
        assert_eq!(engine.min_confidence, MIN_AUTO_APPLY_CONFIDENCE);
    }

    #[test]
    fn test_similarity_boundary_cases() {
        // exact same word
        let sim = jaro_winkler("hello", "hello");
        assert!(sim >= 0.99); // should be ~1.0

        // one character difference
        let sim = jaro_winkler("there", "their");
        // these are similar but not identical
        assert!(sim >= MIN_SIMILARITY);

        // length difference boundary
        // MAX_LENGTH_DIFF is 1, so "cat" -> "cats" should be ok
        let len_diff = ("cat".len() as isize - "cats".len() as isize).unsigned_abs();
        assert_eq!(len_diff, 1);
        assert!(len_diff <= MAX_LENGTH_DIFF);

        // but "cat" -> "catch" has diff of 2
        let len_diff = ("cat".len() as isize - "catch".len() as isize).unsigned_abs();
        assert_eq!(len_diff, 2);
        assert!(len_diff > MAX_LENGTH_DIFF);
    }

    #[test]
    fn test_applied_correction_struct() {
        let correction = AppliedCorrection {
            original: "teh".to_string(),
            corrected: "the".to_string(),
            confidence: 0.95,
            position: 5,
        };

        assert_eq!(correction.original, "teh");
        assert_eq!(correction.corrected, "the");
        assert!((correction.confidence - 0.95).abs() < 0.001);
        assert_eq!(correction.position, 5);
    }

    #[test]
    fn test_learned_correction_struct() {
        let learned = LearnedCorrection {
            original: "recieve".to_string(),
            corrected: "receive".to_string(),
            similarity: 0.95,
        };

        assert_eq!(learned.original, "recieve");
        assert_eq!(learned.corrected, "receive");
        assert!((learned.similarity - 0.95).abs() < 0.001);
    }

    #[test]
    fn test_apply_corrections_case_preservation_all_caps() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        let (result, _) = engine.apply_corrections("TEH QUICK BROWN FOX");
        assert_eq!(result, "THE QUICK BROWN FOX");
    }

    #[test]
    fn test_apply_corrections_case_preservation_title_case() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        let (result, _) = engine.apply_corrections("Teh quick brown fox");
        assert_eq!(result, "The quick brown fox");
    }

    #[test]
    fn test_align_words_single_word_change() {
        let original = vec!["hello"];
        let edited = vec!["hallo"];

        let pairs = align_words(&original, &edited);
        assert_eq!(pairs.len(), 1);
        assert_eq!((pairs[0].0, pairs[0].1), ("hello", "hallo"));
    }

    #[test]
    fn test_align_words_same_text() {
        let words = vec!["I", "love", "rust"];

        let pairs = align_words(&words, &words);
        assert_eq!(pairs.len(), 3);
        assert_eq!((pairs[0].0, pairs[0].1), ("I", "I"));
        assert_eq!((pairs[1].0, pairs[1].1), ("love", "love"));
        assert_eq!((pairs[2].0, pairs[2].1), ("rust", "rust"));
    }

    #[test]
    fn test_multiple_corrections_same_word() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        // same typo appears multiple times
        let (result, applied) = engine.apply_corrections("teh cat and teh dog");
        assert_eq!(result, "the cat and the dog");
        assert_eq!(applied.len(), 2);
    }

    #[test]
    fn test_correction_with_punctuation_adjacent() {
        let engine = LearningEngine::new();
        {
            let mut cache = engine.corrections.write();
            cache.insert(
                "teh".to_string(),
                CachedCorrection {
                    corrected: "the".to_string(),
                    confidence: 0.95,
                },
            );
        }

        let (result, applied) = engine.apply_corrections("I saw teh, cat");
        assert_eq!(result, "I saw the, cat");
        assert_eq!(applied.len(), 1);
    }
}

#[cfg(test)]
mod fork_tests {
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
        assert_eq!((pairs[1].0, pairs[1].1), ("recieve", "receive"));
        assert_eq!((pairs[2].0, pairs[2].1), ("teh", "the"));

        // identical words report 1.0 without running the comparison
        assert_eq!(pairs[0].2, 1.0);
        // the reported score must be the real Jaro-Winkler value, since
        // learn_from_edit now thresholds on it instead of recomputing
        assert_eq!(pairs[1].2, jaro_winkler("recieve", "receive"));
        assert!(pairs[2].2 >= MIN_ALIGNMENT_SIMILARITY);
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

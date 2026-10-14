//! Import the user's own sent messages from the macOS Messages database
//!
//! Reads `~/Library/Messages/chat.db` and the local Contacts database read-only
//! (both need Full Disk Access). Only messages the user sent are read, and only the
//! recipient's category is kept, never their name or number.

use rusqlite::{Connection, OpenFlags, params};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::contacts::{ContactClassifier, ContactInput};
use crate::error::{Error, Result};
use crate::style;

/// chat.style for group conversations
const GROUP_CHAT_STYLE: i64 = 43;
const MAX_MESSAGE_CHARS: usize = 1000;

#[derive(Debug, Clone)]
pub struct SentMessage {
    pub category: String,
    pub text: String,
    /// Messages timestamp (nanoseconds since 2001-01-01)
    pub date: i64,
}

#[derive(Debug, Clone)]
struct ContactRecord {
    name: String,
    organization: String,
}

pub fn messages_db_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join("Library/Messages/chat.db"))
}

fn open_read_only(path: &Path) -> Result<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| {
        let message = e.to_string();
        if message.contains("authorization denied") || message.contains("unable to open") {
            Error::Permission(
                "Flow needs Full Disk Access to read Messages: System Settings → Privacy & Security → \
                 Full Disk Access, then enable the app running Flow"
                    .to_string(),
            )
        } else {
            Error::Storage(e)
        }
    })
}

/// Digits only, keeping the last 10 so "+1 (555) 010-2000" and "5550102000" match
pub fn normalize_phone(raw: &str) -> String {
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    let start = digits.len().saturating_sub(10);
    digits[start..].to_string()
}

fn handle_key(identifier: &str) -> String {
    if identifier.contains('@') {
        identifier.trim().to_lowercase()
    } else {
        normalize_phone(identifier)
    }
}

/// Map of phone/email to contact, from every local AddressBook database
fn load_contacts() -> HashMap<String, ContactRecord> {
    let mut map = HashMap::new();
    let Some(home) = dirs::home_dir() else {
        return map;
    };
    let root = home.join("Library/Application Support/AddressBook");

    let mut databases = vec![root.join("AddressBook-v22.abcddb")];
    if let Ok(sources) = std::fs::read_dir(root.join("Sources")) {
        databases.extend(
            sources
                .flatten()
                .map(|entry| entry.path().join("AddressBook-v22.abcddb")),
        );
    }

    for db in databases.iter().filter(|p| p.exists()) {
        if let Ok(conn) = open_read_only(db) {
            let _ = read_contacts(&conn, &mut map);
        }
    }
    map
}

fn read_contacts(conn: &Connection, map: &mut HashMap<String, ContactRecord>) -> Result<()> {
    let mut records: HashMap<i64, ContactRecord> = HashMap::new();
    let mut stmt =
        conn.prepare("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD")?;
    let rows = stmt.query_map([], |row| {
        let first: Option<String> = row.get(1)?;
        let last: Option<String> = row.get(2)?;
        let org: Option<String> = row.get(3)?;
        Ok((row.get::<_, i64>(0)?, first, last, org))
    })?;
    for (pk, first, last, org) in rows.flatten() {
        let name = [first.unwrap_or_default(), last.unwrap_or_default()]
            .join(" ")
            .trim()
            .to_string();
        let organization = org.unwrap_or_default();
        if !name.is_empty() || !organization.is_empty() {
            records.insert(pk, ContactRecord { name, organization });
        }
    }

    for (table, column) in [
        ("ZABCDPHONENUMBER", "ZFULLNUMBER"),
        ("ZABCDEMAILADDRESS", "ZADDRESS"),
    ] {
        let mut stmt = conn.prepare(&format!("SELECT ZOWNER, {column} FROM {table}"))?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        for (owner, value) in rows.flatten() {
            if let (Some(record), Some(value)) = (owner.and_then(|o| records.get(&o)), value) {
                let key = handle_key(&value);
                if !key.is_empty() {
                    map.insert(key, record.clone());
                }
            }
        }
    }
    Ok(())
}

/// Extract the plain text from a Messages `attributedBody` (NSAttributedString typedstream)
pub fn decode_attributed_body(blob: &[u8]) -> Option<String> {
    let marker = b"NSString";
    let start = blob.windows(marker.len()).position(|w| w == marker)? + marker.len();

    // The string follows a '+' type tag a few bytes after the class name
    let tag = blob[start..].iter().take(16).position(|&b| b == b'+')? + start + 1;
    let (len, offset) = match *blob.get(tag)? {
        0x81 => (u16::from_le_bytes([*blob.get(tag + 1)?, *blob.get(tag + 2)?]) as usize, 3),
        0x82 => (
            u32::from_le_bytes([
                *blob.get(tag + 1)?,
                *blob.get(tag + 2)?,
                *blob.get(tag + 3)?,
                *blob.get(tag + 4)?,
            ]) as usize,
            5,
        ),
        b => (b as usize, 1),
    };

    let bytes = blob.get(tag + offset..tag + offset + len)?;
    String::from_utf8(bytes.to_vec()).ok()
}

fn clean_text(raw: &str) -> Option<String> {
    // U+FFFC marks an inline attachment
    let text = raw.replace('\u{FFFC}', "").trim().to_string();
    let only_link = !text.contains(' ') && (text.starts_with("http://") || text.starts_with("https://"));
    if text.is_empty() || only_link || text.chars().count() > MAX_MESSAGE_CHARS {
        return None;
    }
    Some(text)
}

/// Read messages the user sent after `since`, newest first, categorised by recipient
pub fn read_sent_messages(since: i64, limit: usize) -> Result<Vec<SentMessage>> {
    let path = messages_db_path().ok_or_else(|| Error::Config("No home directory".into()))?;
    let conn = open_read_only(&path)?;
    let contacts = load_contacts();
    let classifier = ContactClassifier::new();

    let mut stmt = conn.prepare(
        r#"
        SELECT m.text, m.attributedBody, m.date, c.chat_identifier, c.style
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.is_from_me = 1
          AND m.associated_message_type = 0
          AND m.item_type = 0
          AND m.date > ?1
        ORDER BY m.date DESC
        LIMIT ?2
        "#,
    )?;

    let rows = stmt.query_map(params![since, limit as i64], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<Vec<u8>>>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<i64>>(4)?,
        ))
    })?;

    let mut seen = HashSet::new();
    let mut messages = Vec::new();
    for (text, body, date, identifier, chat_style) in rows.flatten() {
        let raw = text
            .filter(|t| !t.trim().is_empty())
            .or_else(|| body.as_deref().and_then(decode_attributed_body));
        let Some(text) = raw.as_deref().and_then(clean_text) else {
            continue;
        };

        let category = if chat_style == Some(GROUP_CHAT_STYLE) {
            "group".to_string()
        } else {
            match identifier.as_deref().and_then(|id| contacts.get(&handle_key(id))) {
                Some(contact) => {
                    let input = ContactInput {
                        name: contact.name.clone(),
                        organization: contact.organization.clone(),
                    };
                    style::category_key(Some(classifier.classify(&input)), None)
                }
                // Not in Contacts: an unsaved number or email
                None => "acquaintance".to_string(),
            }
        };

        if seen.insert((category.clone(), text.clone())) {
            messages.push(SentMessage { category, text, date });
        }
    }
    Ok(messages)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_phone() {
        assert_eq!(normalize_phone("+1 (555) 010-2000"), "5550102000");
        assert_eq!(normalize_phone("5550102000"), "5550102000");
        assert_eq!(handle_key("Someone@Example.com"), "someone@example.com");
    }

    #[test]
    fn test_decode_attributed_body() {
        let text = "omw home 🫶";
        let mut blob = b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+".to_vec();
        blob.push(text.len() as u8);
        blob.extend_from_slice(text.as_bytes());
        blob.extend_from_slice(b"\x86\x84\x02iI");
        assert_eq!(decode_attributed_body(&blob).as_deref(), Some(text));
    }

    #[test]
    fn test_decode_long_attributed_body() {
        let text = "a".repeat(300);
        let mut blob = b"NSString\x01\x94\x84\x01+\x81".to_vec();
        blob.extend_from_slice(&(text.len() as u16).to_le_bytes());
        blob.extend_from_slice(text.as_bytes());
        assert_eq!(decode_attributed_body(&blob), Some(text));
    }

    #[test]
    fn test_clean_text() {
        assert_eq!(clean_text("\u{FFFC}"), None);
        assert_eq!(clean_text("https://example.com/x"), None);
        assert_eq!(clean_text(" look \u{FFFC}").as_deref(), Some("look"));
    }
}

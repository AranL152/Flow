use futures::StreamExt;
use crate::error::{Error, Result};
use super::{DictationDelta, TranscriptionResponse};

#[derive(Default)]
struct Decoder {
    event: String,
    data: Vec<String>,
    raw: Option<String>,
    text: String,
    done: bool,
    attachment: Option<crate::attachments::AttachmentPlan>,
    require_attachment_protocol: bool,
}

fn failure(message: impl Into<String>) -> Error { Error::Transcription(message.into()) }

impl Decoder {
    fn line(&mut self, line: &str, on_delta: &DictationDelta) -> Result<()> {
        let line = line.trim_end_matches('\r');
        if self.done { return Ok(()); }
        if let Some(event) = line.strip_prefix("event:") { self.event = event.trim().into(); }
        else if let Some(data) = line.strip_prefix("data:") {
            self.data.push(data.trim_start().into());
            if self.data.iter().map(String::len).sum::<usize>() > 65536 { return Err(failure("Stream frame is too large")); }
        } else if line.is_empty() && !self.data.is_empty() {
            let value: serde_json::Value = serde_json::from_str(&self.data.join("\n"))
                .map_err(|_| failure("Invalid stream frame"))?;
            self.data.clear();
            if self.event == "error" { return Err(failure(value["error"].as_str().unwrap_or("Streaming failed"))); }
            let text = value["text"].as_str().ok_or_else(|| failure("Missing stream text"))?;
            match self.event.as_str() {
                "transcription" if self.raw.is_none() && self.text.is_empty() && !text.trim().is_empty() => {
                    if self.require_attachment_protocol && value["attachment_protocol"].as_u64() != Some(1) {
                        return Err(failure("Update the Flow worker to support attachment commands"));
                    }
                    if !value["attachment"].is_null() {
                        let plan: crate::attachments::AttachmentPlan = serde_json::from_value(value["attachment"].clone())
                            .map_err(|_| failure("Invalid attachment plan"))?;
                        if !plan.validate() { return Err(failure("Invalid attachment plan")); }
                        self.attachment = Some(plan);
                    }
                    self.raw = Some(text.into());
                }
                "delta" if self.raw.is_some() => {
                    self.text.push_str(text);
                    if self.text.len() > 48000 { return Err(failure("Streaming output is too long")); }
                    if !on_delta(text) { return Err(failure("Dictation cancelled")); }
                }
                "done" if self.raw.is_some() && (!text.trim().is_empty() || self.attachment.is_some()) && text == self.text.trim() => {
                    self.text = text.into(); self.done = true;
                }
                _ => return Err(failure("Incomplete or invalid dictation stream")),
            }
            self.event.clear();
        }
        Ok(())
    }

    fn finish(self, duration_ms: u64) -> Result<TranscriptionResponse> {
        if !self.done { return Err(failure("Dictation stream ended before completion")); }
        Ok(TranscriptionResponse { text: self.raw.ok_or_else(|| failure("Missing transcription"))?,
            completed_text: Some(self.text), attachment: self.attachment, confidence: None, language: None, duration_ms, segments: None })
    }
}

pub async fn consume(response: reqwest::Response, duration_ms: u64, on_delta: DictationDelta) -> Result<TranscriptionResponse> {
    consume_with_attachments(response, duration_ms, on_delta, false).await
}

pub async fn consume_with_attachments(response: reqwest::Response, duration_ms: u64, on_delta: DictationDelta, require_attachment_protocol: bool) -> Result<TranscriptionResponse> {
    if !response.status().is_success() {
        let status = response.status().as_u16();
        let detail = tokio::time::timeout(std::time::Duration::from_secs(2), response.json::<serde_json::Value>()).await.ok().and_then(|result| result.ok())
            .and_then(|value| value["error"].as_str().map(|text| text.chars().take(500).collect::<String>()));
        return Err(failure(format!("Streaming worker returned HTTP {status}{}", detail.map(|text| format!(": {text}")).unwrap_or_default())));
    }
    if !response.headers().get("content-type").and_then(|s| s.to_str().ok()).is_some_and(|s| s.contains("text/event-stream")) {
        return Err(failure("The worker did not return an event stream"));
    }
    let mut stream = response.bytes_stream();
    let mut pending = Vec::new();
    let mut decoder = Decoder { require_attachment_protocol, ..Decoder::default() };
    loop {
        let chunk = tokio::select! {
            chunk = stream.next() => match chunk { Some(chunk) => chunk, None => break },
            _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                if !on_delta("") { return Err(failure("Dictation cancelled")); }
                continue;
            }
        };
        if !on_delta("") { return Err(failure("Dictation cancelled")); }
        pending.extend_from_slice(&chunk?);
        if pending.len() > 131072 { return Err(failure("Invalid stream buffer")); }
        while let Some(end) = pending.iter().position(|b| *b == b'\n') {
            let line = std::str::from_utf8(&pending[..end]).map_err(|_| failure("Invalid UTF-8 in stream"))?;
            decoder.line(line, &on_delta)?;
            pending.drain(..=end);
            if decoder.done { return decoder.finish(duration_ms); }
        }
    }
    decoder.finish(duration_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    fn decode(input: &str) -> Result<(TranscriptionResponse, Vec<String>)> {
        let received = Arc::new(Mutex::new(Vec::new()));
        let copy = received.clone();
        let callback: DictationDelta = Arc::new(move |text| { copy.lock().unwrap().push(text.into()); true });
        let mut decoder = Decoder::default();
        for line in input.split('\n') { decoder.line(line, &callback)?; }
        let response = decoder.finish(1000)?;
        let chunks = received.lock().unwrap().clone();
        Ok((response, chunks))
    }

    #[test]
    fn attachment_metadata_never_becomes_a_delta_and_allows_an_empty_message() {
        let input = "event: transcription\ndata: {\"text\":\"Flow attach my clipboard\",\"attachment_protocol\":1,\"attachment\":{\"message\":\"\",\"command\":\"Flow attach my clipboard\",\"request\":{\"source\":\"clipboard\",\"kind\":\"image\"}}}\n\nevent: done\ndata: {\"text\":\"\"}\n\n";
        let (response, chunks) = decode(input).unwrap();
        assert!(response.attachment.unwrap().validate());
        assert_eq!(response.completed_text.as_deref(), Some(""));
        assert!(chunks.is_empty());
        assert!(decode(&input.replace("\"source\":\"clipboard\"", "\"source\":\"/Users/private\"")).is_err());
        let mut decoder = Decoder { require_attachment_protocol: true, ..Decoder::default() };
        let callback: DictationDelta = Arc::new(|_| panic!("No delta may precede protocol validation"));
        decoder.line("event: transcription", &callback).unwrap();
        decoder.line("data: {\"text\":\"Flow attach my clipboard\"}", &callback).unwrap();
        assert!(decoder.line("", &callback).is_err());
    }

    #[test]
    fn deltas_are_delivered_and_terminal_text_must_match() {
        let input = "event: transcription\ndata: {\"text\":\"hi mum\"}\n\nevent: delta\ndata: {\"text\":\"Hi ❤️\"}\n\nevent: delta\ndata: {\"text\":\" mum\"}\n\nevent: done\ndata: {\"text\":\"Hi ❤️ mum\"}\n\n";
        let (response, chunks) = decode(input).unwrap();
        assert_eq!(response.text, "hi mum");
        assert_eq!(chunks, ["Hi ❤️", " mum"]);
        assert_eq!(response.completed_text.as_deref(), Some("Hi ❤️ mum"));
        assert!(decode(&input.replace("\"Hi ❤️ mum\"", "\"invented\"")).is_err());
        assert!(decode(input.split("event: done").next().unwrap()).is_err());
    }

    #[test]
    fn failures_and_cancellation_never_complete_a_partial() {
        assert!(decode("event: error\ndata: {\"error\":\"provider failed\"}\n\n").is_err());
        let mut decoder = Decoder::default();
        let callback: DictationDelta = Arc::new(|_| false);
        for line in ["event: transcription", "data: {\"text\":\"hello\"}", "", "event: delta", "data: {\"text\":\"Hi\"}"] {
            decoder.line(line, &callback).unwrap();
        }
        assert!(decoder.line("", &callback).is_err());
        assert!(!decoder.done);
    }
    #[tokio::test]
    async fn rejected_worker_reports_actionable_quota_error_before_any_delta() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096]; socket.read(&mut request).await.unwrap();
            let body = r#"{"error":"Cloudflare's daily AI allowance is exhausted. Enable Workers Paid."}"#;
            let response = format!("HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        let response = reqwest::get(format!("http://{address}")).await.unwrap();
        let callback: DictationDelta = Arc::new(|_| panic!("A rejected request cannot insert draft text"));
        let error = consume(response, 1000, callback).await.unwrap_err().to_string();
        assert!(error.contains("HTTP 429"));
        assert!(error.contains("Enable Workers Paid"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn stalled_network_cancels_without_waiting_for_another_token() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use std::sync::atomic::{AtomicBool, Ordering};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096]; socket.read(&mut request).await.unwrap();
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n").await.unwrap();
            std::future::pending::<()>().await;
        });
        let response = reqwest::get(format!("http://{address}")).await.unwrap();
        let cancelled = Arc::new(AtomicBool::new(false));
        let copy = cancelled.clone();
        let callback: DictationDelta = Arc::new(move |_| !copy.load(Ordering::SeqCst));
        let consumer = tokio::spawn(consume(response, 1000, callback));
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        cancelled.store(true, Ordering::SeqCst);
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), consumer).await.unwrap().unwrap();
        assert!(result.unwrap_err().to_string().contains("cancelled"));
        server.abort();
    }

}

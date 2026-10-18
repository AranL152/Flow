# Base10 proxy worker (superseded)

> Replaced by `flow-worker-langgraph/`, which serves the same endpoints and is
> now deployed under this worker's `base10-proxy` name. This directory is kept
> only until it is removed; do not deploy it, as doing so would overwrite the
> replacement at the same name.

This Cloudflare Worker proxies POST requests to Base10 Whisper so the API key is never exposed to clients.

## Deploy

1. Install Wrangler if you do not have it already.
2. Set the Base10 API key as a secret:

   ```sh
   wrangler secret put BASETEN_API_KEY
   ```

3. Deploy from this directory:

   ```sh
   wrangler deploy
   ```

## Usage

Send the same JSON payload you would send to Base10:

```sh
curl -X POST https://<your-worker-url>/ \
  -H "Content-Type: application/json" \
  -d '{"whisper_input": {"audio": {"url": "https://test-audios-public.s3.us-west-2.amazonaws.com/10-sec-01-podcast.m4a"}, "whisper_params": {"audio_language": "auto"}}}'
```

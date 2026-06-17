"""Azure OpenAI text-embeddings client (managed identity). Phase 0 drop-in for text chunks."""
from __future__ import annotations
import logging, threading, time
import httpx
from azure.identity import DefaultAzureCredential

logger = logging.getLogger(__name__)
_SCOPE = "https://cognitiveservices.azure.com/.default"


class TextEmbeddingsClient:
    def __init__(self, endpoint, deployment, api_version="2024-02-01",
                 credential=None, max_concurrency=8):
        if not endpoint:
            raise ValueError("TextEmbeddingsClient requires an endpoint")
        self._url = (f"{endpoint.rstrip('/')}/openai/deployments/"
                     f"{deployment}/embeddings?api-version={api_version}")
        self._credential = credential or DefaultAzureCredential()
        self._http = httpx.Client(timeout=30.0)
        self._sem = threading.BoundedSemaphore(max_concurrency)
        self._token = None
        self._token_expires_on = 0.0

    def _bearer(self):
        now = time.time()
        if self._token and now < self._token_expires_on - 60:
            return self._token
        tok = self._credential.get_token(_SCOPE)
        self._token, self._token_expires_on = tok.token, float(tok.expires_on)
        return self._token

    def embed(self, text, max_retries=5):
        if not text:
            return None
        with self._sem:
            for attempt in range(max_retries):
                try:
                    resp = self._http.post(
                        self._url,
                        headers={"Authorization": f"Bearer {self._bearer()}",
                                 "Content-Type": "application/json"},
                        json={"input": text},
                    )
                except httpx.HTTPError:
                    time.sleep(min(2 ** attempt, 30)); continue
                if resp.status_code == 429:
                    time.sleep(float(resp.headers.get("Retry-After", "5"))); continue
                if resp.status_code >= 500:
                    time.sleep(min(2 ** attempt, 30)); continue
                if resp.status_code >= 400:
                    logger.error(f"OpenAI embed error {resp.status_code}: {resp.text[:500]}")
                    return None
                return resp.json()["data"][0]["embedding"]
        logger.error("OpenAI embed exhausted retries")
        return None

    def close(self):
        self._http.close()

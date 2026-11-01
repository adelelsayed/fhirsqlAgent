"""Sidecar for the FHIR SQL agent: LLM invocation and text embedding.

Two reasons this exists rather than doing the work inside IRIS:

1. AUTH. Bedrock rejects `Authorization: Bearer` and demands AWS SigV4 --
   canonical request, four-step HMAC key derivation, signed headers. boto3 does
   all of that, and also accepts a Bedrock bearer API key via
   AWS_BEARER_TOKEN_BEDROCK. Reimplementing SigV4 in ObjectScript would be a
   large, fragile piece of code for no benefit.

2. PACKAGES. IRIS Embedded Python cannot see a venv -- its sys.path is
   /durable/irissys/mgr/python plus the system dist-packages. Putting torch
   (2.5 GB) and a 110M-parameter model inside the IRIS process is also poor
   isolation: a model crash should not touch the database.

IRIS reaches this over plain HTTP on localhost, the same mechanism already proven
against tx.fhir.org and RxNav.

Run:
    /tmp/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8088
"""
from __future__ import annotations

import json
import os
import threading
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="fhirsqlllm-sidecar", version="1.0")

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# The Bedrock token is written here by IRIS (see Production.ExportCredential), so
# the secret moves IRIS -> file inside the container and never passes through a
# shell, an env var on the command line, or the process list.
TOKEN_FILE = os.environ.get("BEDROCK_TOKEN_FILE", "/tmp/.bedrock_token")


def _load_token() -> None:
    if os.environ.get("AWS_BEARER_TOKEN_BEDROCK"):
        return
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as fh:
            tok = fh.read().strip()
        if tok:
            os.environ["AWS_BEARER_TOKEN_BEDROCK"] = tok
    except OSError:
        pass                                      # /health will report it missing
EMBED_MODEL = os.environ.get("EMBED_MODEL", "cambridgeltl/SapBERT-from-PubMedBERT-fulltext")

# ---------------------------------------------------------------- LLM (Bedrock)


class LLMRequest(BaseModel):
    model: str
    system: str | None = None
    user: str
    max_tokens: int = 2048
    # Omitted from the body when None. Claude 5-family models on Bedrock reject
    # `temperature` outright ("deprecated for this model"), so it cannot simply
    # be sent with a default.
    temperature: float | None = None


_bedrock_lock = threading.Lock()
_bedrock: Any = None


def bedrock():
    """Lazily create the client. boto3 picks up AWS_BEARER_TOKEN_BEDROCK, or a
    standard access-key/secret/role chain -- whichever the environment has."""
    global _bedrock
    with _bedrock_lock:
        if _bedrock is None:
            _load_token()
            import boto3

            _bedrock = boto3.client("bedrock-runtime", region_name=AWS_REGION)
        return _bedrock


@app.post("/llm")
def llm(req: LLMRequest):
    body: dict[str, Any] = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": req.max_tokens,
        "messages": [{"role": "user", "content": req.user}],
    }
    if req.temperature is not None:
        body["temperature"] = req.temperature
    if req.system:
        body["system"] = req.system

    try:
        resp = bedrock().invoke_model(modelId=req.model, body=json.dumps(body))
        payload = json.loads(resp["body"].read())
    except Exception as exc:                      # surfaced to IRIS verbatim
        raise HTTPException(status_code=502, detail=f"{type(exc).__name__}: {exc}")

    text = "".join(
        b.get("text", "") for b in payload.get("content", []) if b.get("type") == "text"
    )
    usage = payload.get("usage") or {}
    return {
        "text": text,
        "model": payload.get("model", req.model),
        "stop_reason": payload.get("stop_reason"),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
    }


@app.get("/models")
def models():
    """List the Anthropic models this credential can actually see. Needs
    control-plane permission, which a runtime-only API key will not have."""
    try:
        import boto3

        _load_token()
        client = boto3.client("bedrock", region_name=AWS_REGION)
        out = client.list_foundation_models(byProvider="anthropic")
        return {"modelIds": [m["modelId"] for m in out.get("modelSummaries", [])]}
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"{type(exc).__name__}: {exc}")


# ------------------------------------------------------------------- embeddings


class EmbedRequest(BaseModel):
    texts: list[str]


_embed_lock = threading.Lock()
_tok: Any = None
_mdl: Any = None


def embedder():
    """SapBERT. The model card specifies [CLS] before the pooler as the
    representation -- not mean pooling -- so that is what we use."""
    global _tok, _mdl
    with _embed_lock:
        if _mdl is None:
            import torch
            from transformers import AutoModel, AutoTokenizer

            _tok = AutoTokenizer.from_pretrained(EMBED_MODEL)
            _mdl = AutoModel.from_pretrained(EMBED_MODEL).eval()
            torch.set_num_threads(max(1, (os.cpu_count() or 2) // 2))
        return _tok, _mdl


@app.post("/embed")
def embed(req: EmbedRequest):
    if not req.texts:
        return {"vectors": [], "dim": 0}
    try:
        import torch
        import torch.nn.functional as F

        tok, mdl = embedder()
        batch = tok(
            req.texts, padding=True, truncation=True, max_length=64, return_tensors="pt"
        )
        with torch.no_grad():
            cls = mdl(**batch).last_hidden_state[:, 0, :]
        cls = F.normalize(cls, dim=-1)
        return {"vectors": cls.tolist(), "dim": int(cls.shape[1])}
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"{type(exc).__name__}: {exc}")


@app.get("/health")
def health():
    return {
        "ok": True,
        "region": AWS_REGION,
        "embed_model": EMBED_MODEL,
        "embedder_loaded": _mdl is not None,
        "bedrock_client": _bedrock is not None,
        "token_file_present": os.path.exists(TOKEN_FILE),
        "token_loaded": bool(os.environ.get("AWS_BEARER_TOKEN_BEDROCK")),
    }

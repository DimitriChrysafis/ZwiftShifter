import os
import sys
from pathlib import Path

import requests
from sentence_transformers import SentenceTransformer

from db import es

INDEX = "ride-chunks"
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
CHAT_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")
KEYS_FILE = (Path.home() / "Desktop" / "keys" / "workingkeys"
             / "openai_keys.txt")


def api_keys():
    if os.environ.get("OPENAI_API_KEY"):
        return [os.environ["OPENAI_API_KEY"]]
    if KEYS_FILE.exists():
        keys = [l.strip() for l in KEYS_FILE.read_text().splitlines()
                if l.strip().startswith("sk-")]
        if keys:
            return keys
    raise SystemExit("no OPENAI_API_KEY and no key in ~/Desktop/keys/")


def retrieve(question, k=6):
    vec = (SentenceTransformer(EMBED_MODEL)
           .encode(question, normalize_embeddings=True).tolist())
    resp = es().search(
        index=INDEX,
        knn={
            "field": "embedding",
            "query_vector": vec,
            "k": k,
            "num_candidates": 100,
        },
        size=k,
    )
    return resp["hits"]["hits"]


def answer(question, hits):
    ctx = "\n".join(
        f"- [{h['_source']['kind']}] {h['_source']['text']}" for h in hits
    )
    prompt = (
        "You answer questions about the user's Zwift riding history using "
        "the retrieved ride summaries below. Be concise and cite specific "
        "ride dates or filenames.\n\n"
        f"Retrieved context:\n{ctx}\n\nQuestion: {question}"
    )
    for key in api_keys():
        r = requests.post(
            "https://api.openai.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {key}"},
            json={
                "model": CHAT_MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 300,
            },
            timeout=60,
        )
        if r.status_code != 401:
            r.raise_for_status()
            return r.json()["choices"][0]["message"]["content"].strip()
    raise SystemExit("all OpenAI keys returned 401")


def main():
    question = " ".join(sys.argv[1:]) or input("ask: ")
    hits = retrieve(question)
    print(f"\n{answer(question, hits)}\n")
    print("sources:")
    for h in hits:
        print(f"  {h['_score']:.3f}  {h['_source']['ride']}  "
              f"({h['_source']['kind']})")


if __name__ == "__main__":
    main()

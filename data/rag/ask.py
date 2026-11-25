import os
import subprocess
import sys

from db import es
from sentence_transformers import SentenceTransformer

INDEX = "ride-chunks"
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
DEVIN_BIN = os.environ.get("ZWIFTSHIFT_DEVIN_BIN", "devin")
DEVIN_MODEL = os.environ.get("ZWIFTSHIFT_DEVIN_MODEL", "swe-2-medium")


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
        "the retrieved ride summaries below. Use only the retrieved context. "
        "Do not inspect files, run commands, or modify anything. Be concise "
        "and cite specific ride dates or filenames. Return only the answer.\n\n"
        f"Retrieved context:\n{ctx}\n\nQuestion: {question}"
    )
    try:
        proc = subprocess.run(
            [
                DEVIN_BIN,
                "--model", DEVIN_MODEL,
                "--respect-workspace-trust", "false",
                "-p", prompt,
            ],
            capture_output=True,
            check=False,
            text=True,
            timeout=120,
        )
    except FileNotFoundError:
        raise RuntimeError("devin CLI not found on PATH") from None
    except subprocess.TimeoutExpired:
        raise RuntimeError("devin CLI timed out") from None
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "unknown error"
        raise RuntimeError(f"devin CLI failed: {detail}")
    return proc.stdout.strip()


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

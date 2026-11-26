import os
import re
import subprocess
import sys

from sentence_transformers import SentenceTransformer

from db import es, mysql_conn

INDEX = "ride-chunks"
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
DEVIN_BIN = os.environ.get("ZWIFTSHIFT_DEVIN_BIN", "devin")
DEVIN_MODEL = os.environ.get("ZWIFTSHIFT_DEVIN_MODEL", "swe-2-medium")

MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5,
    "june": 6, "july": 7, "august": 8, "september": 9, "october": 10,
    "november": 11, "december": 12,
}


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


def sql_candidates(question):
    """Complete warehouse session rows for any month named in the question.

    Vector retrieval is a similarity search: it returns the closest k
    chunks, not every candidate. Comparative questions need exhaustive
    evidence, so month filters use logical sessions from the warehouse.
    """
    q = question.lower()
    months = [num for name, num in MONTHS.items()
              if re.search(rf"\b{name}\b", q)]
    if not months:
        return []
    year_match = re.search(r"\b(20\d{2})\b", q)
    conn = mysql_conn()
    cur = conn.cursor()
    if year_match:
        year = int(year_match.group(1))
    else:
        cur.execute("select max(year(start_time)) from sessions")
        year = cur.fetchone()[0]
    minutes_match = re.search(r"(?:at least|over|minimum of)\s+(\d+)\s+minutes", q)
    min_moving_s = int(minutes_match.group(1)) * 60 if minutes_match else 0
    lines = []
    for month in months:
        duration_filter = "and moving_s >= %s " if min_moving_s else ""
        params = [
            f"{year}-{month:02d}-01",
            f"{year + (month == 12):04d}-{(month % 12) + 1:02d}-01",
        ]
        if min_moving_s:
            params.append(min_moving_s)
        cur.execute(
            "select id, start_time, distance_m, moving_s, avg_power, "
            "max_power, n_records, n_files, quality_flags from sessions "
            "where start_time >= %s and start_time < %s "
            + duration_filter +
            "order by start_time",
            params,
        )
        rows = cur.fetchall()
        for sid, st, dist, moving, avg_p, max_p, nrec, nfiles, flags in rows:
            km = (dist or 0) / 1000
            mins = (moving or 0) / 60
            stitched = f", stitched from {nfiles} files" if nfiles > 1 else ""
            quality = f", flags: {flags}" if flags else ""
            lines.append(
                f"- [warehouse session {sid[:8]}] {st:%Y-%m-%d %H:%M} | "
                f"{km:.1f} km, {mins:.1f} min, avg power {avg_p} W, "
                f"max {max_p} W, {nrec} records{stitched}{quality}"
            )
    conn.close()
    return lines


def answer(question, hits, table=None):
    ctx = "\n".join(
        f"- [{h['_source']['kind']}] {h['_source']['text']}" for h in hits
    )
    sections = []
    if table:
        sections.append(
            "Complete warehouse rows for the month(s) in the question "
            "(exhaustive for any duration filter stated in the question):\n" + "\n".join(table)
        )
    sections.append("Vector-retrieved ride and lap summaries "
                    "(closest matches, may be incomplete):\n" + ctx)
    prompt = (
        "You answer questions about the user's Zwift riding history using "
        "the evidence below. Use only this evidence. Do not inspect files, "
        "run commands, or modify anything. Be concise and cite specific "
        "ride dates or filenames. For comparative questions (hardest, "
        "longest, most, best), reason over the complete warehouse rows "
        "when they are provided, and never claim a ride is the only one "
        "or the next closest unless the evidence shows every candidate. "
        "Return only the answer.\n\n"
        + "\n\n".join(sections)
        + f"\n\nQuestion: {question}"
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
    table = sql_candidates(question)
    print(f"\n{answer(question, hits, table)}\n")
    print("sources:")
    if table:
        print(f"  warehouse: filtered month session table "
              f"({len(table)} candidate sessions)")
    for h in hits:
        print(f"  {h['_score']:.3f}  {h['_source']['ride']}  "
              f"({h['_source']['kind']})")


if __name__ == "__main__":
    main()

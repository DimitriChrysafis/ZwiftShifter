"""Curated selection of activities for the warehouse and search index.

MongoDB is the lake: it keeps every decodable file, including aborted
stubs and the live in-progress snapshot. The warehouse and the search
index are curated: they only keep rides that carry usable measurements,
and never both copies of a ride that exists as an in-progress snapshot
and a finalized file.
"""

IN_PROGRESS = "inProgressActivity.fit"


def activity_key(doc):
    recs = doc.get("records") or []
    ts = [r["timestamp"] for r in recs if r.get("timestamp")]
    start = (doc.get("session") or {}).get("start_time")
    if start is None and ts:
        start = min(ts)
    return start


def included_activities(db):
    """Return curated activity docs: usable records only, deduplicated.

    Rules:
    - skip documents with no timestamped records (aborted stubs)
    - skip the live in-progress snapshot; the finalized file supersedes it
    - if two files share the same ride start time, keep the one with
      more records (the more complete copy)
    """
    docs = []
    for doc in db.activities.find():
        if doc.get("filename") == IN_PROGRESS:
            continue
        recs = [r for r in (doc.get("records") or []) if r.get("timestamp")]
        if not recs:
            continue
        docs.append((doc, len(recs)))

    best = {}
    order = []
    for doc, n in docs:
        key = activity_key(doc) or doc["filename"]
        if key not in best:
            best[key] = (doc, n)
            order.append(key)
        elif n > best[key][1]:
            best[key] = (doc, n)
    return [best[k][0] for k in order]

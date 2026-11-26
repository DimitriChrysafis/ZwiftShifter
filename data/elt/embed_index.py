from elasticsearch.helpers import bulk
from sentence_transformers import SentenceTransformer

from db import es, mongo_db
from elt.select import included_activities

INDEX = "ride-chunks"
MODEL = "BAAI/bge-small-en-v1.5"

MAPPING = {
    "mappings": {
        "properties": {
            "kind": {"type": "keyword"},
            "ride": {"type": "keyword"},
            "start_time": {"type": "date"},
            "text": {"type": "text"},
            "embedding": {
                "type": "dense_vector",
                "dims": 384,
                "index": True,
                "similarity": "cosine",
                "index_options": {
                    "type": "int8_hnsw",
                    "m": 16,
                    "ef_construction": 100,
                },
            },
        }
    }
}


def naive(ts):
    return ts.replace(tzinfo=None) if ts and ts.tzinfo else ts


def hr_phrase(value):
    return f"avg hr {value} bpm, " if value else ""


def chunks(db):
    out = []
    for d in included_activities(db):
        s = d.get("session") or {}
        recs = d.get("records") or []
        ts = [r["timestamp"] for r in recs if r.get("timestamp")]
        start = s.get("start_time") or (min(ts) if ts else None)
        sport = s.get("sport") or "ride"
        dist = s.get("total_distance")
        if dist is None:
            dists = [r["distance"] for r in recs
                     if r.get("distance") is not None]
            dist = dists[-1] if dists else 0
        elapsed = s.get("total_elapsed_time")
        if elapsed is None and len(ts) > 1:
            elapsed = (max(ts) - min(ts)).total_seconds()
        powers = [r["power"] for r in recs if r.get("power") is not None]
        avg_p = s.get("avg_power")
        if avg_p is None and powers:
            avg_p = round(sum(powers) / len(powers))
        max_p = s.get("max_power")
        if max_p is None and powers:
            max_p = max(powers)
        st = f"{naive(start):%Y-%m-%d %H:%M:%S}" if start else "unknown"
        km = f"{dist/1000:.1f}" if dist else "0.0"
        hrs = f"{elapsed/3600:.1f}" if elapsed else "0.0"
        out.append({
            "_id": str(d["_id"]),
            "kind": "ride",
            "ride": d["filename"],
            "start_time": naive(start).isoformat() if start else None,
            "text": (f"{sport} on {st}: {km} km, {hrs} h, "
                     f"avg power {avg_p} W, max {max_p} W, "
                     f"{hr_phrase(s.get('avg_heart_rate'))}"
                     f"cadence {s.get('avg_cadence')} rpm, "
                     f"ascent {s.get('total_ascent')} m"),
        })
        for i, lap in enumerate(d.get("laps") or []):
            ldist = lap.get("total_distance") or 0
            lel = lap.get("total_elapsed_time") or 0
            lstart = lap.get("start_time") or start
            out.append({
                "_id": f"{d['_id']}-lap{i}",
                "kind": "lap",
                "ride": d["filename"],
                "start_time": naive(lstart).isoformat() if lstart else None,
                "text": (f"lap {i+1} of {d['filename']}: {ldist/1000:.1f} km, "
                         f"{round(lel/60)} min, "
                         f"avg power {lap.get('avg_power')} W"
                         + (f", avg hr {lap.get('avg_heart_rate')} bpm"
                            if lap.get('avg_heart_rate') else "")),
            })
    return out


def run():
    db = mongo_db()
    client = es()
    if client.indices.exists(index=INDEX):
        client.indices.delete(index=INDEX)
    client.indices.create(index=INDEX, body=MAPPING)
    docs = chunks(db)
    print(f"embedding {len(docs)} chunks with {MODEL}")
    model = SentenceTransformer(MODEL)
    vecs = model.encode([d["text"] for d in docs], normalize_embeddings=True)
    actions = [{**d, "_index": INDEX, "embedding": v.tolist()}
               for d, v in zip(docs, vecs)]
    ok, errs = bulk(client, actions)
    print(f"{INDEX}: {ok} indexed")
    if errs:
        print("errors:", errs[:3])


if __name__ == "__main__":
    run()

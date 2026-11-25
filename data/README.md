# data

Data layer on top of ZwiftShift: everything a ride produces lands raw in
MongoDB, then gets cleaned into a MySQL warehouse and Elasticsearch, with a
vector index for natural-language queries.

```
.fit files (~/Documents/Zwift/Activities) ─┐
app /api/status (live telemetry)         ─┼─▶ MongoDB ─▶ MySQL ─▶ Elasticsearch
Zwift Log.txt tail                       ─┘   lake       warehouse  zwift-logs
                                                                    workouts
                                                                    ride-chunks (kNN)
```

## setup

```
docker compose -f compose.yml up -d      # mongo :27018, mysql :3307, es :9299
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

## pipeline

```
.venv/bin/python -m ingest.fit_load      # .fit -> mongo activities (raw)
.venv/bin/python -m ingest.log_tail      # Log.txt -> mongo zwift_log (offset-tracked)
.venv/bin/python -m ingest.stream        # live app telemetry -> mongo telemetry
.venv/bin/python -m elt.warehouse        # mongo -> mysql activities + records
.venv/bin/python -m elt.es_index         # mongo -> es zwift-logs + workouts
.venv/bin/python -m elt.embed_index      # ride/lap text -> es ride-chunks (bge-small)
.venv/bin/python -m rag.ask "hardest ride in november"
.venv/bin/streamlit run dashboard.py
```

All steps are idempotent; re-running reloads in place. Warehouse rows for
truncated files (`session` never written because Zwift was killed mid-ride)
fall back to stats derived from the raw record stream. Files under ~1 KB are
aborted-activity stubs and are skipped on ingest.

## notes

- `analysis.ipynb` in `notebooks/` holds the executed time-series analysis:
  power-duration curve, FTP estimate, CTL/ATL/TSB, weekly-distance forecast.
- `norm_power` exists in the warehouse schema but is computed downstream in
  the notebook, not during ELT.
- embeddings: `BAAI/bge-small-en-v1.5` (384-d, cosine). RAG answer step uses
  the Devin CLI with `swe-2-medium`.

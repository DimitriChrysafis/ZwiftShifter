# data — Zwift Ride Analytics

Personal project, built outside coursework, applying ideas from CS 574
(data management for data science): binary ingestion, a document lake, a
relational warehouse, search indexing and time-series analysis.

Decoded ride fields land in the MongoDB document lake, then get curated into
MySQL. Elasticsearch holds text and vector indexes for search and
natural-language queries.

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
.venv/bin/python -m ingest.fit_load      # .fit -> mongo activities (decoded lake)
.venv/bin/python -m ingest.log_tail      # Log.txt -> mongo zwift_log (offset-tracked)
.venv/bin/python -m ingest.stream        # live app telemetry -> mongo telemetry
.venv/bin/python -m elt.warehouse        # mongo -> mysql sessions + activities + records
.venv/bin/python -m elt.es_index         # mongo -> es zwift-logs + workouts
.venv/bin/python -m elt.embed_index      # ride/lap text -> es ride-chunks (bge-small)
.venv/bin/python -m rag.ask "which november 2026 ride had the highest whole-ride average power, counting rides over 20 minutes"
.venv/bin/streamlit run dashboard.py
```

All steps are idempotent; re-running reloads in place.

## schema

**MongoDB `activities`** — one document per `.fit` file: `session` summary,
`laps`, timestamped `records`, `decode_errors`, plus ingest metadata. This
is the lake: decoded activity structure and decode errors stay together
before any relational schema is imposed. Aborted stubs and the live
in-progress snapshot are kept here but never promoted downstream.

**MySQL** — three tables. `activities` has one row per curated FIT file
(start time, elapsed, distance, avg/max power, record count) plus a
`session_id` for provenance. `sessions` has one row per logical ride,
aggregating continuation fragments with file count, summed file elapsed
time, distance, record count and quality flags. `records` has one row per timestamped
measurement (power, cadence, speed, altitude, distance, position), keyed
by `(activity_id, ts)`.

**Elasticsearch `ride-chunks`** — short text documents for every ride and
lap, embedded with `BAAI/bge-small-en-v1.5` (384 dimensions, cosine) for
kNN retrieval.

## incomplete-file recovery

When Zwift is killed mid-ride it never finalizes the FIT header: the
declared data size stays **zero** even though usable record bytes are
sitting in the file. The decoder believes the header and leaves those
measurements behind. `ingest/fit_load.py` compares the declared size with
the real size, patches the header in memory and decodes a corrected copy.
Decode errors are stored inside the ride document so recovered data stays
labeled instead of silently looking perfect. In the current archive 9
recovered files contribute 23,432 records, 116.8 km and 9.5 hours of
riding that would otherwise be lost.

## curated warehouse selection

`elt/select.py` decides what belongs downstream:

- skip documents with no timestamped records (aborted ~1 KB stubs)
- skip `inProgressActivity.fit`; the finalized file supersedes it
- if two files share a ride start time, keep the one with more records

Current curated numbers: **49 activity files, 31 logical sessions, 693.8 km,
50.4 h, 143,400 records** (down from an inflated 70 rows before
deduplication). Eight sessions are stitched from multiple files and five
sessions are tiny fragments. File rows remain visible as provenance; they
are not treated as standalone training rides.

## sessionization

Interrupted rides can produce several FIT files. `elt/sessions.py` treats
adjacent files as continuation fragments when the next file starts within
five minutes of the previous file ending. Raw file rows are never deleted;
logical sessions are derived for training analytics. This keeps two truths
visible at once: what Zwift wrote, and what the rider actually did.

## retrieval design

Vector retrieval is a similarity search: it returns the closest k chunks,
not every candidate. Comparative questions ("hardest ride in november")
need exhaustive evidence, so `rag/ask.py` pulls the complete month of
logical sessions straight from the warehouse and applies any duration
filter stated in the question. The closest vector matches are added as
context, not as the complete candidate set. The answer cites specific
sessions or files and the sources print underneath.

## limitations

- **No heart-rate data.** No HR strap was paired for these rides; the
  `heart_rate` field exists in the FIT schema but is zero everywhere in
  this archive. The dashboard charts power only and says why.
- Live telemetry (`/api/status`) is implemented as a supported input but
  no ride has been captured with it yet.
- `norm_power` exists in the warehouse schema but is computed downstream
  in the notebook, not during ELT.
- `analysis.ipynb` in `notebooks/` holds the executed time-series
  analysis over logical sessions: power-duration curve, FTP estimate
  (226 W), CTL/ATL/TSB, weekly-distance forecast.
- The RAG answer step uses the Devin CLI with `swe-2-medium`; see
  `AI_USE.md` for disclosure.

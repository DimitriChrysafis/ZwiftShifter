import pandas as pd
import streamlit as st

from db import mongo_db, mysql_conn

st.set_page_config(page_title="zwiftshift data", layout="wide")


@st.cache_data(ttl=300)
def load_activities():
    conn = mysql_conn()
    df = pd.read_sql("select * from activities order by start_time", conn)
    conn.close()
    return df


@st.cache_data(ttl=300)
def load_records(activity_id):
    conn = mysql_conn()
    df = pd.read_sql(
        "select * from records where activity_id = %s order by ts",
        conn, params=(activity_id,),
    )
    conn.close()
    return df


@st.cache_data(ttl=300)
def record_count():
    conn = mysql_conn()
    cur = conn.cursor()
    cur.execute("select count(*) from records")
    n = cur.fetchone()[0]
    conn.close()
    return n


def normalized_power(p):
    if len(p) < 30:
        return None
    roll = p.rolling(30).mean().dropna()
    return float((roll**4).mean() ** 0.25)


def fitness_frame(act):
    rows = []
    for _, a in act.dropna(subset=["start_time"]).iterrows():
        recs = load_records(a["id"])
        if recs.empty or a["elapsed_s"] is None:
            continue
        np_ = normalized_power(recs["power"].fillna(0))
        ftp = FTP or 1
        tss = (a["elapsed_s"] * (np_ or a["avg_power"] or 0) ** 2
               / (ftp**2 * 3600)) * 100
        rows.append({"date": a["start_time"].date(), "tss": tss,
                     "distance_km": (a["distance_m"] or 0) / 1000})
    d = pd.DataFrame(rows)
    if d.empty:
        return d
    daily = d.groupby("date").sum()
    daily.index = pd.to_datetime(daily.index)
    daily = daily.reindex(
        pd.date_range(daily.index.min(), daily.index.max()), fill_value=0
    )
    daily["CTL"] = daily["tss"].ewm(span=42, min_periods=1).mean()
    daily["ATL"] = daily["tss"].ewm(span=7, min_periods=1).mean()
    daily["TSB"] = daily["CTL"] - daily["ATL"]
    return daily


FTP = 226

act = load_activities()
n_records = record_count()
total_km = (act["distance_m"].fillna(0).sum()) / 1000
total_h = act["elapsed_s"].fillna(0).sum() / 3600

st.title("zwiftshift data layer")
c1, c2, c3, c4 = st.columns(4)
c1.metric("rides", len(act))
c2.metric("distance", f"{total_km:,.0f} km")
c3.metric("time", f"{total_h:.1f} h")
c4.metric("records", f"{n_records:,}")

overview, rides, fitness, ask = st.tabs(
    ["overview", "rides", "fitness", "ask"]
)

with overview:
    st.subheader("weekly distance")
    if not act.empty:
        wk = act.dropna(subset=["start_time"]).set_index("start_time")[
            "distance_m"
        ].resample("W").sum() / 1000
        st.bar_chart(wk)
        st.subheader("recent rides")
        cols = ["filename", "sport", "start_time", "distance_m",
                "elapsed_s", "avg_power", "max_power", "n_records"]
        st.dataframe(
            act[cols].sort_values("start_time", ascending=False).head(20)
        )

with rides:
    names = act["filename"].tolist()
    pick = st.selectbox("ride", names,
                        index=len(names) - 1 if names else 0)
    if pick:
        row = act[act["filename"] == pick].iloc[0]
        recs = load_records(row["id"])
        st.write(
            f"{row['start_time']} — {(row['distance_m'] or 0)/1000:.1f} km, "
            f"avg {row['avg_power']} W, max {row['max_power']} W, "
            f"{row['n_records']} records"
        )
        if not recs.empty:
            chart = recs.set_index("t_offset_s")[["power", "heart_rate"]]
            st.line_chart(chart)

with fitness:
    st.subheader("CTL / ATL / TSB")
    daily = fitness_frame(act)
    if daily.empty:
        st.write("no ride data")
    else:
        st.line_chart(daily[["CTL", "ATL", "TSB"]])
        st.caption(
            f"latest: CTL {daily['CTL'].iloc[-1]:.0f}, "
            f"ATL {daily['ATL'].iloc[-1]:.0f}, "
            f"TSB {daily['TSB'].iloc[-1]:.0f} (FTP {FTP} W)"
        )

with ask:
    st.subheader("ask the ride archive")
    q = st.text_input("question", "hardest ride in november")
    if st.button("ask") and q:
        try:
            from rag.ask import retrieve, answer
            hits = retrieve(q)
            st.write(answer(q, hits))
            st.caption("sources: " + ", ".join(
                h["_source"]["ride"] for h in hits))
        except Exception as e:
            st.error(f"rag unavailable: {e}")

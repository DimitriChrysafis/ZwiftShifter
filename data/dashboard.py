import sys

import altair as alt
import pandas as pd
import streamlit as st

sys.path.insert(0, '.')
from db import mysql_conn

st.set_page_config(page_title='Zwift Ride Analytics', layout='wide')
st.title('Zwift Ride Analytics')
st.caption('Personal data layer: raw FIT files, logical ride sessions, time-series analysis, and grounded retrieval')


def q(sql, params=None):
    conn = mysql_conn()
    cur = conn.cursor()
    cur.execute(sql, params or ())
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    conn.close()
    return pd.DataFrame(rows, columns=cols)


@st.cache_data(ttl=120)
def load_sessions():
    df = q('select * from sessions order by start_time desc')
    df['start_time'] = pd.to_datetime(df['start_time'])
    df['end_time'] = pd.to_datetime(df['end_time'])
    return df


@st.cache_data(ttl=120)
def load_files():
    df = q('select * from activities order by start_time desc')
    df['start_time'] = pd.to_datetime(df['start_time'])
    return df


@st.cache_data(ttl=120)
def records_for_session(session_id):
    return q(
        'select r.ts, r.power, r.cadence, r.speed_mps, r.distance_m, a.filename '
        'from records r join activities a on a.id = r.activity_id '
        'where a.session_id = %s order by r.ts',
        (session_id,),
    )


def fmt_hm(seconds):
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m = rem // 60
    return f'{h}:{m:02d} h' if h else f'{m} min'


def session_label(row):
    files = f', {row.n_files} files' if row.n_files > 1 else ''
    return (f'{row.start_time:%Y-%m-%d %H:%M}  ·  '
            f'{row.distance_m / 1000:.1f} km  ·  '
            f'{fmt_hm(row.moving_s)}{files}')


sessions = load_sessions()
files = load_files()

tabs = st.tabs(['Overview', 'Rides', 'Fitness', 'Ask'])

with tabs[0]:
    st.subheader('Archive')
    c1, c2, c3, c4 = st.columns(4)
    c1.metric('Logical sessions', len(sessions))
    c2.metric('Activity files', len(files))
    c3.metric('Distance', f'{sessions.distance_m.sum() / 1000:,.1f} km')
    c4.metric('Sessionized elapsed', f'{sessions.moving_s.sum() / 3600:.1f} h')
    c1, c2, c3, c4 = st.columns(4)
    c1.metric('Records', f'{int(sessions.n_records.sum()):,}')
    c2.metric('Recovered records', f'{int(sessions.recovered_records.sum()):,}')
    c3.metric('Stitched sessions', int((sessions.n_files > 1).sum()))
    c4.metric('Tiny fragments', int(sessions.quality_flags.fillna('').str.contains('tiny_fragment').sum()))

    st.subheader('Weekly distance')
    weekly = (sessions.set_index('start_time')['distance_m']
              .resample('W').sum().reset_index())
    weekly['km'] = weekly['distance_m'] / 1000
    chart = alt.Chart(weekly).mark_line(point=True, color='#42d97c').encode(
        x=alt.X('start_time:T', title='Week'),
        y=alt.Y('km:Q', title='Distance (km)'),
    ).properties(height=280)
    st.altair_chart(chart, use_container_width=True)

    st.subheader('Recent logical sessions')
    show = sessions.head(20).copy()
    show['Distance (km)'] = show.distance_m / 1000
    show['Elapsed'] = show.moving_s.map(fmt_hm)
    show['Avg power (W)'] = show.avg_power
    show['Max power (W)'] = show.max_power
    show['Files'] = show.n_files
    show['Records'] = show.n_records
    show['Quality'] = show.quality_flags.fillna('')
    st.dataframe(
        show[['start_time', 'Distance (km)', 'Elapsed', 'Avg power (W)',
              'Max power (W)', 'Files', 'Records', 'Quality']]
        .rename(columns={'start_time': 'Start'}),
        use_container_width=True,
        hide_index=True,
    )

    with st.expander('File-level provenance'):
        st.caption('Raw FIT file rows are preserved here. They are not counted as standalone training rides.')
        fshow = files.head(40).copy()
        fshow['Distance (km)'] = fshow.distance_m / 1000
        fshow['Duration'] = fshow.elapsed_s.map(fmt_hm)
        st.dataframe(
            fshow[['filename', 'start_time', 'Distance (km)', 'Duration', 'avg_power', 'n_records', 'session_id']]
            .rename(columns={
                'filename': 'FIT file', 'start_time': 'Start',
                'avg_power': 'Avg power (W)', 'n_records': 'Records',
                'session_id': 'Session',
            }),
            use_container_width=True,
            hide_index=True,
        )

with tabs[1]:
    st.subheader('Ride detail')
    meaningful = sessions.copy()
    meaningful['label'] = meaningful.apply(session_label, axis=1)
    label = st.selectbox('Logical session', meaningful['label'])
    row = meaningful.loc[meaningful['label'] == label].iloc[0]
    rec = records_for_session(row.id)
    if not rec.empty:
        rec['ts'] = pd.to_datetime(rec['ts'])
        rec['elapsed_min'] = (rec.ts - pd.to_datetime(row.start_time)).dt.total_seconds() / 60
        c1, c2, c3, c4, c5 = st.columns(5)
        c1.metric('Distance', f'{row.distance_m / 1000:.1f} km')
        c2.metric('Sessionized elapsed', fmt_hm(row.moving_s))
        c3.metric('Avg power', f'{row.avg_power} W')
        c4.metric('Sprint max', f'{row.max_power} W')
        c5.metric('Records', f'{int(row.n_records):,}')
        chart = alt.Chart(rec).mark_line(color='#d7ff3f').encode(
            x=alt.X('elapsed_min:Q', title='Elapsed time (minutes)'),
            y=alt.Y('power:Q', title='Power (W)'),
            tooltip=['elapsed_min:Q', 'power:Q', 'filename:N'],
        ).properties(height=420)
        st.altair_chart(chart, use_container_width=True)
        if row.n_files > 1:
            st.info(f'This logical session was stitched from {row.n_files} FIT files. Source files are preserved in the provenance table.')
            st.text(row.source_filenames)
    else:
        st.warning('No timestamped records found for this session')

with tabs[2]:
    st.subheader('Power-duration curve')
    allrec = q('select activity_id, power from records where power is not null order by activity_id, ts')
    windows = [1, 5, 15, 30, 60, 120, 300, 600, 1200]
    best = {}
    for w in windows:
        val = 0
        for _, grp in allrec.groupby('activity_id', sort=False):
            p = grp.power.dropna()
            if len(p) >= w:
                val = max(val, p.rolling(w).mean().max())
        best[w] = val
    curve = pd.DataFrame({'duration_s': list(best), 'power_w': list(best.values())})
    chart = alt.Chart(curve).mark_line(point=True, color='#d7ff3f').encode(
        x=alt.X('duration_s:Q', scale=alt.Scale(type='log'), title='Record-count window (approx. seconds, log scale)'),
        y=alt.Y('power_w:Q', title='Best mean power (W)'),
    ).properties(height=430)
    st.altair_chart(chart, use_container_width=True)
    ftp = best[1200] * .95 if 1200 in best else 0
    c1, c2 = st.columns(2)
    c1.metric('Best 20 minutes', f'{best.get(1200, 0):.0f} W')
    c2.metric('FTP estimate', f'{ftp:.0f} W')

with tabs[3]:
    st.subheader('Ask the archive')
    st.caption('SQL supplies exact evidence. Vector retrieval supplies semantic context.')
    question = st.text_input('Question', 'which november 2026 ride had the highest whole-ride average power, counting rides over 20 minutes')
    if st.button('Answer'):
        with st.spinner('Retrieving evidence and generating answer'):
            import contextlib
            import io

            from rag.ask import answer, retrieve, sql_candidates
            hits = retrieve(question)
            table = sql_candidates(question)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                text = answer(question, hits, table)
            st.markdown(text)
            with st.expander('Evidence'):
                st.caption(f'Warehouse rows: {len(table)}')
                for line in table:
                    st.text(line)
                st.caption('Vector matches')
                for hit in hits:
                    src = hit['_source']
                    st.text(f"{hit['_score']:.3f}  {src['ride']}  ({src['kind']})")

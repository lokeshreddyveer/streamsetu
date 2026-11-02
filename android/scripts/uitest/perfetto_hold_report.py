#!/usr/bin/env python3
"""Where the time goes during a held direction. usage: perfetto_hold_report.py TRACE"""
import sys
from perfetto.trace_processor import TraceProcessor
tp = TraceProcessor(trace=sys.argv[1]); q = lambda s: list(tp.query(s))
proc = [p for p in q("select upid, pid, name from process where name like '%streamsetu%' order by pid desc")][0]
thr = q(f"select utid, tid, name from thread where upid={proc.upid}")
main = [t.utid for t in thr if t.tid == proc.pid][0]; rt = [t.utid for t in thr if t.name and "RenderThread" in t.name]
fr = q(f"select s.ts, s.dur from slice s join thread_track tt on s.track_id=tt.id where tt.utid={main} and s.name like 'Choreographer#doFrame%' order by s.ts")
print(f"main-thread frames in the trace: {len(fr)}")
durs = sorted((f.dur / 1e6 for f in fr), reverse=True); print("slowest doFrame (ms):", [round(x) for x in durs[:8]], "| median %.1f" % durs[len(durs) // 2] if durs else "")
busy = [f for f in fr if f.dur > 20e6]; print(f"frames over 20 ms: {len(busy)} of {len(fr)}")
if not busy: sys.exit()
a, b = busy[0].ts, busy[-1].ts + busy[-1].dur
def top(utids, label, n=14):
    ids = ",".join(str(u) for u in utids)
    rows = q(f"select s.name, count(*) c, sum(s.dur)/1e6 tot, max(s.dur)/1e6 mx from slice s join thread_track tt on s.track_id=tt.id where tt.utid in ({ids}) and s.ts>={a} and s.ts<={b} and s.depth>=1 group by s.name order by tot desc limit {n}")
    print(f"\n{label} (window {(b-a)/1e6:.0f} ms): total ms | count | slowest ms")
    for r in rows: print(f"  {r.tot:7.0f} | {r.c:4d} | {r.mx:6.1f}  {r.name[:90]}")
top([main], "MAIN THREAD, nested slices")
if rt: top(rt, "RENDER THREAD, nested slices", 10)

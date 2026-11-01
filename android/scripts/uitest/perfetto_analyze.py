import sys
from perfetto.trace_processor import TraceProcessor
tp = TraceProcessor(trace=sys.argv[1])
def q(sql): return list(tp.query(sql))
proc = q("select upid, pid, name from process where name like '%streamsetu%' order by pid desc")
print("processes:", [(r.pid, r.name) for r in proc])
upid = proc[0].upid
thr = q(f"select utid, tid, name from thread where upid={upid}")
print("threads:", [(t.tid, t.name) for t in thr][:40])
main = [t for t in thr if t.tid == proc[0].pid][0].utid
rt = [t.utid for t in thr if t.name and 'RenderThread' in t.name]
# doFrame slices on the main thread
fr = q(f"select s.ts, s.dur, s.name from slice s join thread_track tt on s.track_id=tt.id where tt.utid={main} and s.name like 'Choreographer#doFrame%' order by s.ts")
print("main doFrame count:", len(fr))
gaps = [(fr[i+1].ts - (fr[i].ts + fr[i].dur), fr[i].ts + fr[i].dur, fr[i+1].ts) for i in range(len(fr)-1)]
gaps.sort(reverse=True); print("largest gaps between doFrame (ms):", [round(g[0]/1e6) for g in gaps[:5]])
g, a, b = gaps[0]
print(f"\nBIGGEST GAP {g/1e6:.0f} ms, from {a} to {b}")
def slices(utids, a, b, minDur=3e6):
    ids = ",".join(str(u) for u in utids)
    return q(f"select s.ts, s.dur, s.name, tt.utid from slice s join thread_track tt on s.track_id=tt.id where tt.utid in ({ids}) and s.ts < {b} and s.ts + s.dur > {a} and s.dur > {minDur} order by s.dur desc limit 14")
print("\nMAIN THREAD slices overlapping the gap (>3 ms):")
for r in slices([main], a, b): print(f"  {r.dur/1e6:7.1f} ms  {r.name[:100]}")
print("\nRENDERTHREAD slices overlapping the gap (>3 ms):")
for r in slices(rt, a, b): print(f"  {r.dur/1e6:7.1f} ms  {r.name[:100]}")
print("\nMain thread state during the gap:")
for r in q(f"select state, sum(min(ts_end, {b}) - max(ts, {a})) as d from (select ts, ts+dur as ts_end, state from thread_state where utid={main} and ts < {b} and ts+dur > {a}) group by state order by d desc"): print(f"  {r.state:12} {r.d/1e6:7.1f} ms")
print("RenderThread state during the gap:")
if rt:
    for r in q(f"select state, sum(min(ts_end, {b}) - max(ts, {a})) as d from (select ts, ts+dur as ts_end, state from thread_state where utid={rt[0]} and ts < {b} and ts+dur > {a}) group by state order by d desc"): print(f"  {r.state:12} {r.d/1e6:7.1f} ms")
print("\nOther app threads busiest in the gap (running ms):")
for r in q(f"select t.name, t.tid, sum(min(ts.ts+ts.dur,{b}) - max(ts.ts,{a})) as d from thread_state ts join thread t using(utid) where t.upid={upid} and ts.state='Running' and ts.ts < {b} and ts.ts+ts.dur > {a} group by t.utid order by d desc limit 8"): print(f"  {r.name[:30]:30} {r.tid:6} {r.d/1e6:7.1f} ms")
print("\nAll processes running in the gap (cpu ms):")
for r in q(f"select p.name, p.pid, sum(min(ts.ts+ts.dur,{b}) - max(ts.ts,{a})) as d from thread_state ts join thread t using(utid) join process p using(upid) where ts.state='Running' and ts.ts < {b} and ts.ts+ts.dur > {a} group by p.upid order by d desc limit 8"): print(f"  {(r.name or '?')[:40]:40} {r.pid:6} {r.d/1e6:7.1f} ms")

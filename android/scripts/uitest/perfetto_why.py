import sys
from perfetto.trace_processor import TraceProcessor
tp = TraceProcessor(trace=sys.argv[1]); q = lambda s: list(tp.query(s))
upid = q("select upid, pid from process where name like '%streamsetu%' order by pid desc")[0]
main = q(f"select utid from thread where upid={upid.upid} and tid={upid.pid}")[0].utid
fr = q(f"select s.ts, s.dur from slice s join thread_track tt on s.track_id=tt.id where tt.utid={main} and s.name like 'Choreographer#doFrame%' order by s.ts")
gaps = sorted([(fr[i+1].ts - (fr[i].ts + fr[i].dur), fr[i].ts + fr[i].dur, fr[i+1].ts) for i in range(len(fr)-1)], reverse=True)
g, a, b = gaps[0]; print(f"gap {g/1e6:.0f} ms")
print("main thread in the gap: state, blocked function, who woke it")
for r in q(f"select ts.ts, ts.dur, ts.state, ts.blocked_function, w.name as waker, w.tid as wtid from thread_state ts left join thread w on w.utid = ts.waker_utid where ts.utid={main} and ts.ts < {b} and ts.ts + ts.dur > {a} order by ts.ts"):
    if r.dur > 2e6 or True: print(f"  +{(r.ts - a)/1e6:6.0f} ms  {r.dur/1e6:7.1f} ms  {r.state:3} {str(r.blocked_function)[:30]:30} woken by {r.waker} ({r.wtid})")
print("\nslices on arch_disk_io threads in the gap (>5 ms):")
for r in q(f"select t.name, s.dur, s.name as sn from slice s join thread_track tt on s.track_id=tt.id join thread t using(utid) where t.upid={upid.upid} and t.name like 'arch_disk%' and s.ts < {b} and s.ts+s.dur > {a} and s.dur > 5e6 order by s.dur desc limit 10"): print(f"  {r.name} {r.dur/1e6:.0f} ms {r.sn[:90]}")
print("\nbinder transactions from main in the gap:")
for r in q(f"select s.ts, s.dur, s.name from slice s join thread_track tt on s.track_id=tt.id where tt.utid={main} and s.ts < {b} and s.ts+s.dur > {a} order by s.dur desc limit 8"): print(f"  {r.dur/1e6:.1f} ms {r.name[:110]}")

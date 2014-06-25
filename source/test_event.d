module test_event;

import std.stdio;
import mercury.event;

unittest {
    writeln("'mercury.event' unittest...");

    defaultLoop.start();
    defaultLoop.stop();
    
    string test = "";
    auto loop = new Loop();
    auto w1 = new TimerWatcher(loop, 0.01, (w, r) { test ~= "1"; }).start();
    auto w2 = new TimerWatcher(loop, 0.021, (w, r) { test ~= "2"; }).start();
    loop.call((){ test ~= "+"; });
    loop.onTimeout(0.005, (){ test ~= "%"; });
    loop.onTimeout(0.49, (){ test ~= "%"; });
    new TimerWatcher(loop, 0.051, (w, r) { w.stop(); w1.stop(); w2.stop(); }).start();
    loop.start();
    assert (test == "+%1121121%");
    
    auto ws = new SignalWatcher(loop, SIGINT, (w, r){ w.stop(); });
    auto wio = new IOWatcher(loop, 2, IOREAD, (w, r){ w.stop(); });
    assert ((wio.event_mask&IOREAD) == IOREAD);
    wio.event_mask = IOREAD|IOWRITE;
    assert ((wio.event_mask&(IOREAD|IOWRITE)) == (IOREAD|IOWRITE));

    clear(loop);
    assert (w2.start() is null);
    
    writeln("Done!");
}
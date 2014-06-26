import std.stdio;
import mercury;

void hello(string name) {
    writefln("Hello, %s!", name);
}

void main()
{
    auto w = new TimerWatcher(defaultLoop, 1.0,
        (revents) {
            writefln("Hello, World!");
        }).start();
    
    defaultLoop.onSignal(SIGINT, &defaultLoop.stop);
    defaultLoop.onTimeout(10, &defaultLoop.stop);
    defaultLoop.start();
    writeln("Buy!");
}

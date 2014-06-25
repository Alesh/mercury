/**
 * Event loop and watchers.
 */
module mercury.event;

debug import std.stdio;

/** Handled object interface. */
interface IHandled
{
    /** Cancels handled object. */
    void cancel();
}


/** Watcher interface. */
interface IWatcher : IHandled
{
    /** Starts watching. */
    IWatcher start();
    /** Stops watching. */
    bool stop();
    /** Sets priority. */
    @property void priority(int value);
    /** Gets priority. */
    @property int priority();
}


/* Timer watcher interface. */
interface ITimerWatcher : IWatcher
{
    /** Sets seconds. */
    @property void seconds()(double value);
    /** Get seconds. */
    @property double seconds();
}


/* I/O watcher interface. */
interface IIOWatcher : IWatcher
{
    /** Sets I/O event mask (for I/O watcher only). */
    @property void event_mask(int value);
    /** Returns I/O event mask (for I/O watcher only). */
    @property int event_mask();
}


version(Posix) {
    import core.stdc.signal : SIGABRT, SIGFPE, SIGILL, SIGINT, SIGSEGV, SIGTERM;
}


version(LIBEV4) {
    
    import deimos.ev;
    
    /** Event loop implementation based on libev. */
    class LoopImpl {
        private ev_loop_t* p_loop;
        ///
        this(uint flags = EVFLAG_AUTO) {
            this(ev_loop_new(flags));
        }
        ///
        this(ev_loop_t* p_loop) {
            this.p_loop = p_loop;
        }
        
        ~this() {
            ev_loop_destroy(p_loop);
        }
        
        /** Starts event dispatching. */
        void start() {
            ev_run(p_loop, 0);
        }    
        
        /** Stops event dispatching. */
        void stop() {
            ev_break(p_loop, EVBREAK_ALL);
        }
        
        /** Returns current event loop time as timestamp. */
        @property double time() { return ev_time(); }
        /** Returns pointer to libev event loop structure. */
        @property ev_loop_t* ptr() { return p_loop; }
    }
    
    /** Events codes */
    enum : int {
        IOREAD  = 0x00000001, /** I/O Read */
        IOWRITE = 0x00000002, /** I/O Write */
        TIMER   = 0x00000100, /** Timer/Timeout */
        SIGNAL  = 0x00000400, /** Posix signal */
        IDLE    = 0x00002000, /** Idle */
        CLEANUP = 0x00040000,
        ASYNC   = 0x00080000,
        ERROR   = 0x80000000,
    }
    
    /** Watchers priorities */
    enum : int {
        LOWEST  = -2,  /** Lowest */
        LOW     = -1,  /** Low */
        MEDIUM  =  0,  /** Medium */
        HIGH    =  1,  /** High */
        HIGHEST =  2,  /** Highest */
    }
    
    private interface IHasEventCallback {
        protected void event_callback(int revents);
    }

    
    /* libev watcher callback */
    extern(C) static void ev_callback(T)(ev_loop_t* p_loop, T* p_watcher, int revents)
    {
        debug writefln("ev_callback; revents: %s", revents);
        auto instance = cast(Object)p_watcher.data;
        (cast(IHasEventCallback)instance).event_callback(revents);
    }
    
        /** Generic watcher class based on libev. */
    class Watcher(T) : IWatcher, IHasEventCallback 
    {
        private T watcher;
        private LoopImpl loop;
        private ev_cleanup cleanup_watcher;
        private void delegate(IWatcher, int) callback;
        
        /* base constructor. */
        private this(void delegate(IWatcher, int) callback, LoopImpl loop)
        {
            this.loop = loop;
            this.callback = callback;
            watcher.data = cast(void*)this;
            cleanup_watcher.data = cast(void*)this;
            ev_cleanup_init(&cleanup_watcher, &ev_callback!ev_cleanup);
            ev_cleanup_start(loop.ptr, &cleanup_watcher);
        }
        
        ~this() {
            cancel();
        }
        
        /** Starts watching. */
        IWatcher start()
        {
            if ((ev_is_active(&cleanup_watcher))&&(!ev_is_active(&watcher))) {
                static if (is(T == ev_io)) ev_io_start(loop.ptr, &watcher);
                static if (is(T == ev_idle)) ev_idle_start(loop.ptr, &watcher);
                static if (is(T == ev_timer)) ev_timer_start(loop.ptr, &watcher);
                static if (is(T == ev_signal)) ev_signal_start(loop.ptr, &watcher);
                return this;
            }
            return null;
        }
        
        /** Stops watching. */
        bool stop()
        {
            if ((ev_is_active(&cleanup_watcher))&&(ev_is_active(&watcher))) {
                static if (is(T == ev_io)) ev_io_stop(loop.ptr, &watcher);
                static if (is(T == ev_idle)) ev_idle_stop(loop.ptr, &watcher);
                static if (is(T == ev_timer)) ev_timer_stop(loop.ptr, &watcher);
                static if (is(T == ev_signal)) ev_signal_stop(loop.ptr, &watcher);
                return true;
            }
            return false;
        }
        
        /** Cancels watcher. */
        void cancel()
        {
            stop();
            if (ev_is_active(&cleanup_watcher))
                ev_cleanup_stop(loop.ptr, &cleanup_watcher);
        }
        
        /* event callback */
        protected void event_callback(int revents)
        {
            callback(this, revents);
            if (revents&CLEANUP) cancel();
        }
        
        /** Sets priority. */
        @property void priority(int value) {
            auto been_active = stop();
            ev_set_priority(&watcher, value);
            if (been_active) start();
        }
        /** Returns priority */
        @property int priority() { return watcher.priority; }
    }
    
    /** Idle watcher */
    class IdleWatcher : Watcher!ev_idle
    {
        ///
        this(LoopImpl loop, void delegate(IWatcher, int) callback)
        {
            ev_idle_init(&watcher, &ev_callback!ev_idle);
            super(callback, loop);
        }
        ///
        this(LoopImpl loop, void delegate(int) callback) {
            this(loop, (watcher, revents) { callback(revents); });
        }        
    }
    
    /** Timer watcher */
    class TimerWatcher : Watcher!ev_timer, ITimerWatcher
    {
        ///
        this(LoopImpl loop, double seconds, void delegate(IWatcher, int) callback)
        {
            ev_timer_init(&watcher, &ev_callback!ev_timer, seconds, seconds);
            super(callback, loop);
        }
        
        ///
        this(LoopImpl loop, double seconds, void delegate(int) callback) {
            this(loop, seconds, (watcher, revents) { callback(revents); });
        }
    
        /** Sets seconds (for timer watcher only).*/
        @property void seconds(double value) {
            if (ev_is_active(&cleanup_watcher)) {
                stop();
                ev_timer_init(&watcher, &ev_callback!ev_timer, value, value);
                if (value>0) start();
            }
        }
        /** Returns seconds (for timer watcher only). */
        @property double seconds() {
            return (cast(ev_timer)watcher).repeat;
        }    
    }
    
    /** IO event watcher */
    class  IOWatcher : Watcher!ev_io, IIOWatcher
    {
        ///
        this(LoopImpl loop, int fd, int event_mask, void delegate(IWatcher, int) callback)
        {
            ev_io_init(&watcher, &ev_callback!ev_io, fd, event_mask);
            super(callback, loop);
        }
        /// 
        this(LoopImpl loop, int fd, int event_mask, void delegate(int) callback) {
            this(loop, fd, event_mask,(watcher, revents) { callback(revents); });
        }
        
        /** Sets I/O event mask (for I/O watcher only). */
        @property void event_mask(int value) {
            if (ev_is_active(&cleanup_watcher)) {
                auto was_active = stop();
                ev_io_init(&watcher, &ev_callback!ev_io, (cast(ev_io)watcher).fd, value);
                if (was_active) start();
            }
        }
        /** Returns I/O event mask (for I/O watcher only). */
        @property int event_mask() {
            return (cast(ev_io)watcher).events;
        }
    }
    
    version(Posix) {
        /** Signal watcher */
        class SignalWatcher : Watcher!ev_signal
        {
            ///
            this(LoopImpl loop, int sigint, void delegate(IWatcher, int)  callback)
            {
                ev_signal_init(&watcher, &ev_callback!ev_signal, sigint);
                super(callback, loop);
            }
            ///
            this(LoopImpl loop, int sigint, void delegate(int)  callback){
                this(loop, sigint,(watcher, revents) { callback(revents); });
            }
        }
    }
}


/** Event loop. */
class Loop : LoopImpl {

    private IdleWatcher idle_watcher;
    private void delegate()[] call_queue;
    /** Calls callback at next idle. */
    void call(F, T...)(F callback, T args)
    {
        call_queue ~= () { callback(args); };
        if (idle_watcher is null)
            idle_watcher = new IdleWatcher(this, (watcher, revents) {
                if (revents&IDLE) {
                    if (call_queue.length<=1)
                        watcher.stop();
                    if (call_queue.length>0) {
                        auto callback = call_queue[0];
                        call_queue = call_queue[1..$];
                        callback();
                    }
                } 
            });
        idle_watcher.start();
    }
    
    private IWatcher[] watcher_queue;
    private void remove_watcher(IWatcher watcher)
    {
        for (ulong i=0; i<watcher_queue.length; i++) {
            if (watcher_queue[i]==watcher) {
                watcher_queue = watcher_queue[0..i] ~ watcher_queue[i+1..$];
                break;
            }
        }
    }

    /** Calls callback at timeout. */
    IHandled onTimeout(F, T...)(double delay, F callback, T args)
    {
        auto watcher = new TimerWatcher(this, delay, (watcher, revents) {
            if (revents&TIMER) {
                callback(args);
            }
            watcher.stop();
            remove_watcher(watcher);
        });
        watcher_queue ~= watcher;
        return watcher.start();
    }
    
    version(Posix) {
        /** Sets signal warcher. */
        IHandled onSignal(F, T...)(int sigint, F callback, T args)
        {
            auto watcher =  new SignalWatcher(this, sigint, (watcher, revents) {
                if (revents&SIGNAL) {
                    callback(args);
                }
                watcher.stop();
                remove_watcher(watcher);
            });
            watcher_queue ~= watcher;
            return watcher.start();
        }
    }
}

private Loop default_loop;
static this() {
    default_loop = new Loop();
}
static ~this() {
    clear(default_loop);
}

/** Gets a default event loop. */
@property Loop defaultLoop() {
    return default_loop;
}
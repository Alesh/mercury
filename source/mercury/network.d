/**
 * Network interfaces and base classes.
 */
module mercury.network;

import std.socket;
import mercury.event;
debug import std.stdio;


/** Transport interface */
interface ITransport
{
    /** Called to pause receiving data. */
    protected void pause_reading();

    /** Called to resume receiving data. */
    protected void resume_reading();

    /** Write some data (bytes) to the transport. */
    void write(string data);
    
    /** Sets a callback function to be called when the write buffer would be emptied. */
    void flush(void delegate() callback);

    /** Close the transport. */
    void close();

    /** Closes the transport immediately. */
    void abort();
    
    /** Gets write limit */
    @property int writeLimit();
    /** Sets write limit */
    @property void writeLimit(int value);
}

/** Transport factory interface */
interface ITransportFactory
{
    /** Creates the transport appropriate for this protocol. */
    static ITransport transport_factory(Loop loop, Socket socket, Object payload);
}


/** Protocol interface */
interface IProtocol
{
    /** Called when a connection is made. */
    protected void connection_made(ITransport transport);
    
    /** Called when the connection is lost or closed. */
    protected void connection_lost(Throwable exc=null);
    
    /** Called when some data (bytes) is received. */
    protected void data_received(string data);
}


/** Interface extends protocol for transport flow control. */
interface IFlowControl
{
    /** Called when the transport’s buffer goes over the high-water mark. */
    protected void pause_writing();

    /** Called when the transport’s buffer drains below the low-water mark. */
    protected void resume_writing();
}


/** Interface extends protocol for transport timeout control. */
interface ITimeoutControl
{
    /** Called when a transport is timed out. */
    protected void connection_timeout();
}


/**  TCP Connection (transport). */
class TcpConnection: ITransport
{
    private Loop loop;
    private Socket socket;
    private IProtocol protocol;
    private IOWatcher io_watcher;
    private TimerWatcher timer_watcher;
    ///
    this(Loop loop, Socket socket, IProtocol protocol)
    {
        this.loop = loop;
        this.socket = socket;
        this.protocol = protocol;
        io_watcher = new IOWatcher(loop, cast(int)socket.handle, IOREAD,
            (revents) {
                event_callback(revents);
            });
        timer_watcher = new TimerWatcher(loop, 0, 
            (watcher, revents) {
                event_callback(revents);
                watcher.stop();
            });
        io_watcher.start();
        this.protocol.connection_made(this);
    }
    
    ~this() {
        abort();
    }
    
    /** Sets connection timeout.*/
    @property void timeout(double value) { timer_watcher.seconds = value; }
    /** Gets connection timeout.*/
    @property double timeout() { return timer_watcher.seconds; }
    
    /** Gets remote address. */
    @property Address remoteAddress() { return socket.remoteAddress; }
    
    private byte[] write_buffer;
    /** Write some data (bytes) to the transport. */
    void write(string data)
    {
        write_buffer ~= data;
        check_write_buffer();
    }
    
    private void delegate() flush_callback;
    /** Sets a callback function to be called when the write buffer would be emptied. */
    void flush(void delegate() callback)
    {
        if (write_buffer.length>0) 
            flush_callback = callback;
        else
            callback();
        
    }
    
    private bool closing = false;
    /** Close the transport. */
    void close()
    {
        if (!closing) {
            closing = true;
            pause_reading();
            check_write_buffer();
        }         
    }
    
    /** Closes the transport immediately. */
    void abort() {
        abort(1, null);
    }
    
    private int write_limit_high = 384*1024;
    private int write_limit_low  = 256*1024;
    /** Gets write limit */
    @property int writeLimit()  { return write_limit_high; }
    /** Sets write limit */
    @property void writeLimit(int value)
    {
       if (value>=64*1024) {
            write_limit_high = value;
            write_limit_low = cast(int)(value*0.67);
            check_write_buffer();
        }        
    }
    
    static private byte[8*1024] read_buffer;
    /* event callback */
    protected void event_callback(int revents)
    {
        if ((revents&CLEANUP)||(revents&ERROR)) {
            if (revents&ERROR)
                debug writefln("Connection from: %s received error event", socket.remoteAddress);
            abort(Socket.ERROR, "Received error from loop");
        } else if (revents&TIMER) {
            if (auto timeout_control = cast(ITimeoutControl)protocol)
                timeout_control.connection_timeout();
        } else {
            if (revents&IOREAD) {
                auto received = socket.receive(read_buffer);
                if ((received!=Socket.ERROR)&&(received!=0)) 
                    protocol.data_received(cast(string)read_buffer[0..received]);
                else {
                    if (received==Socket.ERROR)
                        abort(Socket.ERROR, "Error while reading");
                    else
                        abort(0, "Closed while reading");
                }                 
            }
            if (revents&IOWRITE) {
                if (write_buffer.length>0) {
                    auto sent = socket.send(write_buffer);
                    if (sent!=Socket.ERROR) {
                        write_buffer = write_buffer[sent..$];
                        check_write_buffer();
                    } else  {
                        abort(Socket.ERROR, "Error while writing");
                    }
                }
            }            
        }
    }
    
    private bool paused_writing = true;
    private bool paused_reading = false;
    /* Called to pause receiving data. */
    protected void pause_reading()
    {
        if (!paused_reading) {
            paused_reading = true;
            if (!paused_writing)
                io_watcher.event_mask = IOWRITE;
            else
                io_watcher.stop();
        }
    }

    /* Called to resume receiving data. */
    protected void resume_reading()
    {
        if ((!closing)&&(paused_reading)) {
            paused_reading = false;
            if (!paused_writing)
                io_watcher.event_mask = IOREAD|IOWRITE;
            else
                io_watcher.event_mask = IOREAD;
        }
    }
    
    /* Called to pause sending data. */
    protected void pause_writing()
    {
        if (!paused_writing) {
            paused_writing = true;
            
            if (!paused_reading)
                io_watcher.event_mask = IOREAD;
            else
                io_watcher.stop();
        }
    }

    /* Called to resume sending data. */
    protected void resume_writing()
    {
        if (paused_writing) {
            paused_writing = false;
            if (paused_reading)
                io_watcher.event_mask = IOWRITE;
            else
                io_watcher.event_mask = IOREAD|IOWRITE;
        }
    }
    
    private bool protocol_paused_writing = false;
    /* Checks write buffer. */
    private void check_write_buffer()
    {
        if ((closing)&&(write_buffer.length==0)) {
            abort();
        } else {
            if ((paused_writing)&&(write_buffer.length>0))
                resume_writing();
            if ((!paused_writing)&&(write_buffer.length==0))
                pause_writing();
            
            if (auto flow_control = cast(IFlowControl)protocol)
            {
                if ((!protocol_paused_writing)&&(write_buffer.length>write_limit_high)) {
                    protocol_paused_writing = true;
                    flow_control.pause_writing();
                }
                if ((protocol_paused_writing)&&(write_buffer.length<write_limit_low)){
                    protocol_paused_writing = false;
                    flow_control.resume_writing();
                }
            }
            if ((flush_callback !is null)&&(write_buffer.length==0)) {
                auto callback = flush_callback;
                flush_callback = null;
                callback();
            }
        }
    }

    private void delegate(int) on_close;
    /* Closes the transport immediately. */
    protected void abort(int reason=1, string msg=null)
    {
        if (socket !is null) {
            // debug writefln("Closed connection from: %s", socket.remoteAddress);
            io_watcher.cancel();
            timer_watcher.cancel();
            msg = (msg is null) ? "Connection error" : msg;
            if ((reason==Socket.ERROR)&&(reason==0))
                protocol.connection_lost(new SocketOSException(msg));
            else 
                protocol.connection_lost();
            if (on_close !is null) on_close(socket.handle);
            socket.shutdown(SocketShutdown.BOTH);
            socket.close();
            socket = null;
        }
    }
    
}

/** TCP Listener. */
class TcpListener(T)
    if (is(T : ITransportFactory))
{
    private IOWatcher io_watcher;
    private TcpSocket socket;
    private Object payload;
    private Loop loop;
    
    ///
    this(Loop loop=null, Object payload=null) {
        this.payload = payload;
        this.loop = (loop !is null) ? loop : defaultLoop;
    }
    
    ~this() {
        stop();
    }
    
    /** Associate a local address with this listener and start listening. */
    void start(Address addr, int backlog = 64)
    {
        if ((loop !is null)&&(socket is null)) {
            socket = new TcpSocket();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
            socket.bind(addr); socket.blocking = true;
            io_watcher = new IOWatcher(loop, socket.handle, IOREAD,
                (revents) {
                    event_callback(revents);
                });
            io_watcher.start();
            socket.listen(backlog);
            debug writefln("Established listener on: %s", socket.localAddress);
        } else {
            throw new SocketOSException("Unable to bind socket");
        }
    }
    
    TcpConnection[int] connections;
    /** Stop listener and unbind networt address. */
    void stop() 
    {
        if ((loop !is null)&&(socket !is null)) {
            debug writefln("Removed listener from: %s", socket.localAddress);
            io_watcher.cancel();
            foreach(key; connections.keys.dup)
                connections[key].close();
            socket.shutdown(SocketShutdown.BOTH);
            socket.close();
            socket = null;
        }
    }
    
    /* event callback */
    protected void event_callback(int revents)
    {
        if (revents&CLEANUP) {
            stop();
            loop = null;
        }
        else if (revents&IOREAD) {
            auto client_socket = socket.accept();
            if(auto connection = cast(TcpConnection)T.transport_factory(loop, client_socket, payload))
            {
                connection.on_close = (key) { connections.remove(key); };
                connections[client_socket.handle] = connection;
                //debug writefln("Accepted connection from: %s", client_socket.remoteAddress);
            } else {
                throw new Exception("Unsupported type of transport.");
            }
        }
    }     
}
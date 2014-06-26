import std.stdio;
import std.socket;
import mercury;

class EchoProtocol : ITransportFactory, IProtocol, ITimeoutControl
{
    TcpConnection connection;
    
    static ITransport transport_factory(Loop loop, Socket socket, Object payload)
    {
        return new TcpConnection(loop, socket, new EchoProtocol());
    }
    
    protected void connection_made(ITransport transport)
    {
        connection = cast(TcpConnection)transport;
        debug writefln("Accepted connection from: %s", connection.remoteAddress);
        connection.timeout = 5;
    }
	
    void connection_timeout()
    {
        debug writefln("Timed out connection from: %s", connection.remoteAddress);
        connection.close();
    }

    protected void data_received(string data)
    {
        connection.write(data);
        connection.timeout = 15;
    };
    
    void connection_lost(Throwable exc = null)
    {
        debug writefln("Closed connection from: %s", connection.remoteAddress);
    }
	
}


void main()
{
    auto listener = new TcpListener!EchoProtocol();
    listener.start(new InternetAddress("127.0.0.1", 2007), 128);
    defaultLoop.onSignal(SIGINT, &defaultLoop.stop);
    defaultLoop.start();
    writeln("Buy!");
}

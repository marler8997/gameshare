module protocol;

static import core.stdc.stdlib;
import std.format : formattedWrite;

enum ClientToServerMessage
{
    connect    = 0,
    disconnect = 1,
    keyDown    = 2,
    keyUp      = 3,
}

enum CONNECT_MESSAGE_LENGTH = 1;

/*
ubyte ClientToServerMessage.keyDown
ubyte keyCode
ubyte scanCode
*/
enum KEYDOWN_MESSAGE_LENGTH = 3;
/*
ubyte ClientToServerMessage.keyUp
ubyte keyCode
ubyte scanCode
*/
enum KEYUP_MESSAGE_LENGTH = 3;


enum ServerToClientMessage
{
    connectAck  = 0,
    heartbeat   = 1,
    pixelFormat = 2,
    pixelData   = 3,
}

enum CONNECT_ACK_OK = 0;
enum CONNECT_ACK_MESSAGE_LENGTH = 6;

enum HEARTBEAT_MESSAGE_LENGTH = 1;

/*
ubyte ServerToClientMessage.pixelFormat
ubyte bitsPerPixel
uint width
uint height
*/
enum PIXEL_FORMAT_MESSAGE_LENGTH = 10;

/*
ubyte ServerToClientMessage.pixelData
ushort frameID
uint frameByteOffset
uint length
*/
enum PIXEL_DATA_HEADER_LENGTH = 11;

struct Size
{
    uint width;
    uint height;
    void toString(scope void delegate(const(char)[]) sink) const
    {
        formattedWrite(sink, "%s x %s", width, height);
    }
}

void serialize(uint value, ubyte* buffer)
{
    buffer[0] = cast(ubyte)(value >> 24);
    buffer[1] = cast(ubyte)(value >> 16);
    buffer[2] = cast(ubyte)(value >>  8);
    buffer[3] = cast(ubyte)(value >>  0);
}

auto deserialize(T)(ubyte* buffer)
{
    T value = 0;
    foreach(i; 0..T.sizeof)
    {
        value |= (cast(T)buffer[i]) << (8 * (T.sizeof - i - 1));
    }

    return value;
}

module util;

static import core.stdc.stdlib;
import core.stdc.string : strlen;
import core.time : dur, Duration;

import core.sys.windows.winsock2 : timeval;

import std.stdio : File;
import std.format : format;
import std.typecons : Flag, Yes, No;
import std.traits : isSomeChar;

pragma(inline)
auto checkedMalloc(size_t size)
{
    auto result = core.stdc.stdlib.malloc(size);
    assert(result, format("malloc(%s) failed", size));
    return result;
}

/**
An output range interface.

I created this type because formattedWrite only supports the 'char' type.  Using this
StringSink type allows you to use formattedWrite to write to other char types like
wchar or dchar.

Example:
----
wchar[10] message;
auto sink = StringSink!wchar(message);
formattedWrite(&sink.put, "hello");
----
 */
struct StringSink(Char)
{
    Char[] buffer;
    size_t contentLength;
    this(Char[] buffer)
    {
        this.buffer = buffer;
    }
    auto data()
    {
        return buffer[0..contentLength];
    }
    void put(const(char)[] str)
    {
        if(str.length == 0)
        {
            return;
        }
        static if(Char.sizeof == 1)
        {
            assert(contentLength + str.length <= buffer.length);
            buffer[contentLength .. contentLength + str.length] = str[];
            contentLength += str.length;
        }
        else
        {
            assert(contentLength + str.length <= buffer.length);
            foreach(c; str)
            {
                assert(c <= char.max, "non-ascii not implemented");
                buffer[contentLength++] = cast(char)c;
            }
        }
    }
}
/**
Example:
----
wchar[10] message;
auto sink = stringSink(message);
formattedWrite(&sink.put, "hello");
----
 */
auto stringSink(Char)(Char[] buffer)
{
    return StringSink!Char(buffer);
}

template cstring(string str)
{
    //static assert(str.ptr[str.length] == '\0');
    enum cstring = immutable CString(str.ptr);
}
struct CString
{
    char* ptr;
    package this(char* ptr)
    {
        this.ptr = ptr;
    }
    package this(immutable char* ptr) immutable
    {
        this.ptr = ptr;
    }
    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink(ptr[0..strlen(ptr)]);
    }
}

struct Logger
{
    private static __gshared File logFile;
    static void init(string logname)
    {
        logFile = File(logname, "wb");
    }
    static void log(string message)
    {
        // TODO: add synchronization code
        logFile.writeln(message);
        logFile.flush();
    }
    static void logf(T...)(string fmt, T args)
    {
        // TODO: add synchronization code
        logFile.writefln(fmt, args);
        logFile.flush();
    }
}

T alignTo(T,U)(T value, U alignSize)
{
    U mod = value % alignSize;
    if(mod == 0)
    {
        return value;
    }
    return value + (alignSize - mod);
}

// Note: it rounds up to the nearest microsecond
timeval toTimeval(Duration time)
{
    timeval returnValue;
    uint hnsecs;
    time.split!("seconds", "usecs", "hnsecs")(returnValue.tv_sec, returnValue.tv_usec, hnsecs);
    if(hnsecs > 0)
    {
        returnValue.tv_usec++;
        if(returnValue.tv_usec >= 1000000)
        {
            returnValue.tv_usec -= 1000000;
            returnValue.tv_sec++;
        }
    }
    return returnValue;
}
unittest
{
    void test(uint seconds, uint usecs, Duration duration)
    {
        auto val = duration.toTimeval();
        assert(val.tv_sec  == seconds);
        assert(val.tv_usec == usecs, format("expected %s, got %s", usecs, val.tv_usec));
    }
    test(0, 0, dur!"seconds"(0));
    test(1, 0, dur!"seconds"(1));
    test(1234, 0, dur!"seconds"(1234));

    test(0, 0, dur!"usecs"(0));
    test(0, 1, dur!"usecs"(1));
    test(0, 1234, dur!"usecs"(1234));

    test(0, 999999, dur!"usecs"(999999));
    test(1, 0, dur!"usecs"(1000000));
    test(1, 1, dur!"usecs"(1000001));

    test(9876, 2345, dur!"usecs"(9876002345));
    test(1234, 567890, dur!"usecs"(1234567890));

    test(4294967295, 0, dur!"usecs"(4294967295000000));

    test(0, 0, dur!"hnsecs"(0));
    test(0, 1, dur!"hnsecs"(10));
    test(0, 1234, dur!"hnsecs"(12340));

    test(0, 999999, dur!"hnsecs"(9999990));
    test(1, 0, dur!"hnsecs"(10000000));
    test(1, 1, dur!"hnsecs"(10000010));

    test(9876, 2345, dur!"hnsecs"(98760023450));
    test(1234, 567890, dur!"hnsecs"(12345678900));

    test(4294967295, 0, dur!"hnsecs"(42949672950000000));

    test(0, 1, dur!"hnsecs"(1));
    test(0, 1, dur!"hnsecs"(9));
    test(0, 2, dur!"hnsecs"(11));
    test(0, 2, dur!"hnsecs"(19));
    test(0, 1235, dur!"hnsecs"(12341));
    test(0, 1235, dur!"hnsecs"(12349));

    test(1, 0, dur!"hnsecs"(9999991));
    test(1, 0, dur!"hnsecs"(9999999));
    test(1, 1, dur!"hnsecs"(10000001));
    test(1, 1, dur!"hnsecs"(10000009));
    test(1, 2, dur!"hnsecs"(10000011));
    test(1, 2, dur!"hnsecs"(10000019));

    test(9876, 2346, dur!"hnsecs"(98760023451));
    test(9876, 2346, dur!"hnsecs"(98760023459));
    test(1234, 567891, dur!"hnsecs"(12345678901));
    test(1234, 567891, dur!"hnsecs"(12345678909));

    test(4294967295, 1, dur!"hnsecs"(42949672950000001));
    test(4294967295, 1, dur!"hnsecs"(42949672950000009));
}
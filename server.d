#!/usr/bin/env rund
//!importPath ..\mored

pragma(lib, "gdi32");

static import core.stdc.stdlib;
import core.time : MonoTime, dur, Duration;
import core.thread : Thread;
import core.stdc.stdlib : alloca;

static import core.sys.windows.windows;
alias win = core.sys.windows.windows;
import core.sys.windows.windows :
    BOOL, TRUE, FALSE, UINT,
    HWND, LONG, HDC, HBITMAP, LPARAM, WPARAM, RECT, BITMAPINFO,
    SOCKET_ERROR, SRCCOPY, BI_RGB, DIB_RGB_COLORS,
    GetLastError, EnumWindows,
    GetClientRect, GetDC, CreateCompatibleDC, BitBlt,
    CreateCompatibleBitmap, GetWindowTextA, SelectObject,
    CreateDIBSection, PostMessage,
    WM_KEYDOWN, WM_KEYUP;
import core.sys.windows.winsock2 :
    SOL_SOCKET, WSAEWOULDBLOCK,
    getsockopt,fd_set_custom, timeval;

enum SO_MAX_MSG_SIZE = 0x2003;

import std.stdio;
import std.conv : to;
import std.format : format;
import std.array : appender;
import std.typecons : Flag, Yes, No;

import more.alloc : GCDoubler;
import more.builder;
import more.net.sock;

import util;
import sharedwindows;
import protocol;
import gdibitmap;

enum PixelSource
{
    window,
    testBits,
}

enum DEFAULT_BITS_PER_PIXEL = 24;
__gshared ubyte bitsPerPixel = DEFAULT_BITS_PER_PIXEL;

immutable ushort DefaultListenPort = 8080;
__gshared bool verbose = false;
__gshared PixelSource pixelSource;
__gshared HWND windowHandle = null;
__gshared WindowScraper windowScraper;
__gshared SocketHandle sock;
__gshared uint sockMaxMessageSize;
__gshared ubyte[] sockSendBuffer;
__gshared Builder!(Client, GCDoubler!10) clients;
__gshared ubyte[512] recvBuffer;

void usage()
{
    writeln ("Usage: server [options] <window-name>");
    writeln ("Options:");
    writefln("  -bpp <num>  bits per pixel (default=%s)", DEFAULT_BITS_PER_PIXEL);
    writefln("  -port       port to listen on (default %s)", DefaultListenPort);
    writefln("  -v          verbose output", DefaultListenPort);
    writeln ();
    //writeln ("Note: use \"desktop\" to capture the desktop");
}

int main(string[] args)
{
    ushort listenPort = DefaultListenPort;

    args = args[1..$];
    {
        size_t newArgsLength = 0;
        for(size_t i = 0; i < args.length; i++)
        {
            auto arg = args[i];
            if(arg.length > 0 && arg[0] != '-')
            {
                args[newArgsLength++] = arg;
            }
            else if(arg == "-v")
            {
                verbose = true;
            }
            else if(arg == "-bpp")
            {
                i++;
                if(i >= args.length)
                {
                    writefln("Error: -bpp requires an argument");
                    return 1;
                }
                // todo: better error message if it doesn't parse
                bitsPerPixel = args[i].to!ubyte;
            }
            else if(arg == "-port")
            {
                i++;
                if(i >= args.length)
                {
                    writefln("Error: -port requires an argument");
                    return 1;
                }
                // todo: better error message if it doesn't parse
                listenPort = args[i].to!ushort;
            }
            else if(arg == "-h" || arg == "--help" || arg == "-help")
            {
                usage();
                return 1;
            }
            else
            {
                writefln("Error: unknown option \"%s\"", arg);
                return 1;
            }
        }
        args = args[0..newArgsLength];
    }

    if(args.length == 0)
    {
        usage();
        return 1;
    }
    string windowName = args[0];
    if(args.length > 1)
    {
        writeln("Error: too many arguments");
        return 1;
    }


    if(windowName == "testbits")
    {
        pixelSource = PixelSource.testBits;
        writefln("generating test bits");
    }
    else
    {
        // TODO: add a command to list all the windows
        // TODO: figure out how to handle multiple windows with
        //       the same name.  For now I should modify the code
        //       to detect this and cause an error when there are
        //       multiple windows that match the given name
        // TODO: support a regex for the window name
        pixelSource = PixelSource.window;
        {
            auto findData = FindWindowData(false, windowName, null);
            EnumWindows(&windowWithPrefixCallback, cast(LPARAM)&findData);
            if(findData.error)
            {
                // error already printed
                return 1;
            }
            if(findData.match is null)
            {
                writefln("Failed to find window that matched \"%s\"", windowName);
                return 1;
            }
            windowHandle = findData.match;
        }
        writefln("found window (handle=%s)", windowHandle);
        windowScraper.initAfterGettingWindowHandle();
    }

    // create the socket
    {
        // TODO: add option to limit the network interfaces to listen on
        auto listenAddr = sockaddr_in(AddressFamily.inet, Port(htons(listenPort)), in_addr.any);

        sock = createsocket(AddressFamily.inet, SocketType.dgram, Protocol.udp);
        if(sock.isInvalid)
        {
            writefln("Error: createsocket failed (e=%s)", GetLastError());
            return 1;
        }
        if(bind(sock, &listenAddr).failed)
        {
            writefln("Error: bind failed (e=%s)", GetLastError());
            return 1;
        }
    }
    if(setMode(sock, Blocking.no).failed)
    {
        writefln("Error: failed to set udp socket to non-blocking! (e=%d)", lastError());
        return 1;
    }
    /*
    {
        int optlen = sockMaxMessageSize.sizeof;
        if(SOCKET_ERROR == getsockopt(sock, SOL_SOCKET, SO_MAX_MSG_SIZE,
            cast(void*)&sockMaxMessageSize, &optlen))
        {
            writefln("Error: getsockopt failed (e=%s)", GetLastError());
            return 1;
        }
    }
    */
    sockMaxMessageSize = 6300;
    writefln("sockMaxMessageSize is %s", sockMaxMessageSize);
    {
        auto buffer = cast(ubyte*)checkedMalloc(sockMaxMessageSize);
        sockSendBuffer = buffer[0..sockMaxMessageSize];
    }

    for(;;)
    {
        assert(clients.data.length == 0, "code bug");
        waitForAClient();
        assert(clients.data.length == 1, "code bug");

        ushort frameID = 0;
      SERVE_CLIENTS_LOOP:
        for(;;)
        {
            //handleIncoming(dur!"msecs"(0));
            //auto before = MonoTime.currTime;
            enum WAIT_TIME_MS = 30;
            handleIncoming(dur!"msecs"(WAIT_TIME_MS));
            //auto elapsed = MonoTime.currTime - before;
            //if(elapsed < dur!"msecs"(WAIT_TIME_MS - 1)) // allow wiggle room because select
            //                                            // timeout doesn't have alot of preceision
            //{
            //    writefln("elapsed = %s", elapsed);
            //    assert(0);
            //}

            windowScraper.getFrame();
            {
                foreach(ref client; clients.data)
                {
                    client.sendFrame(frameID);
                    //client.send(windowScraper.bitmapPixelBuffer[0..windowScraper.bitmapPixelBufferSize]);
                }
                frameID++;
            }
            // send heartbeat
            {
                ubyte[1] heartbeat;
                heartbeat[0] = ServerToClientMessage.heartbeat;
                foreach(ref client; clients.data)
                {
                    //writefln("Sending heartbeat to %s", client.addr);
                    client.send(heartbeat);
                }
            }
        }
    }


    return 0;
}


void waitForAClient()
{
    writeln("waiting for a client...");
    for(;;)
    {
        waitForDatagram(sock);

        sockaddr_in from;
        writeln("waiting for clients...");
        auto recvResult = recvfrom(sock, recvBuffer, 0, &from);
        if(recvResult.failed)
        {
            writefln("Error: recvfrom failed (e=%s)", GetLastError());
            assert(0, "recvfrom failed, check log");
        }
        if(recvResult.length == 0)
        {
            writefln("Warning: got a 0-length datagram from %s", from);
        }
        else
        {
            writefln("Got a %s-byte packet!", recvResult.length);
            auto command = recvBuffer[0];
            switch(command)
            {
                case ClientToServerMessage.connect:
                    auto newClient = Client(from);
                    if(!newClient.handleConnect(recvBuffer[1..recvResult.length]))
                    {
                        // error already logged
                        break;
                    }
                    else
                    {
                        writefln("Got new client %s", from);
                        newClient.negotiateSettings();
                        clients.append(newClient);
                        return;
                    }
                default:
                    writefln("Warning: got unexpected command %s from %s", command, from);
                    break;
            }
        }
    }
}

// returns once the minimum time has expired
// Note: might want to add a maxTime parameter as well
void handleIncoming(Duration minTime/*, Duration maxTime*/)
{
    MonoTime startTime;
    if(minTime > Duration.zero)
    {
        startTime = MonoTime.currTime;
    }

    for(;;)
    {
        // receive all current datagrams
        for(;;)
        {
            // TODO: handle maxTime

            sockaddr_in from;
            auto recvResult = recvfrom(sock, recvBuffer, 0, &from);
            if(recvResult.failed)
            {
                auto error = GetLastError();
                if(error == WSAEWOULDBLOCK)
                {
                    break;
                }
                writefln("Error: recvfrom failed (e=%s)", GetLastError());
                assert(0, "recvfrom failed, check log");
            }
            handleDatagram(&from, recvBuffer[0..recvResult.length]);
        }

        if(minTime <= Duration.zero)
        {
            return;
        }

        // wait for more datagrams
        auto elapsed = MonoTime.currTime - startTime;
        auto timeLeft = minTime - elapsed;
        if(timeLeft <= Duration.zero)
        {
            return;
        }

        //writefln("[DEBUG] minTime %s, elapsed %s, timeLeft %s", minTime, elapsed, timeLeft);
        if(!waitForDatagram(sock, timeLeft))
        {
            //writefln("[DEBUG] select timeout expired");
            return;
        }
        //writefln("[DEBUG] select popped with data!");
    }
}

void waitForSocketWriteable(SocketHandle sock)
{
}
void waitForDatagram(SocketHandle sock)
{
    fd_set_custom!1 readSet;
    readSet.fd_count = 1;
    readSet.fd_array[0] = sock.val;
    auto result = select(0, cast(fd_set*)&readSet, null, null, null);
    if(result == SOCKET_ERROR)
    {
        writefln("Error: select failed (readSock=%s, timeout=INFINITE)", sock);
        assert(0, "select failed, check log");
    }
    assert(result == 1, "waitForDatagram: select returned unexpected value");
}

Flag!"haveDatagram" waitForDatagram(SocketHandle sock, Duration timeout)
    in { assert(timeout > Duration.zero, "cannot pass a non-positive timeout to waitForDatagram"); } body
{
    auto selectTimeout = timeout.toTimeval();
    //writefln("selectTimeout = %s", selectTimeout);

    fd_set_custom!1 readSet;
    readSet.fd_count = 1;
    readSet.fd_array[0] = sock.val;
    auto result = select(0, cast(fd_set*)&readSet, null, null, &selectTimeout);
    if(result == SOCKET_ERROR)
    {
        writefln("Error: select failed (readSock=%s, timeout=%s secs, %s usecs)",
            sock, selectTimeout.tv_sec, selectTimeout.tv_usec);
        assert(0, "select failed, check log");
    }
    if(result == 0)
    {
        return No.haveDatagram;
    }
    assert(result == 1, "waitForDatagram: select returned unexpected value");
    return Yes.haveDatagram;
}

void postWindowMessage(UINT msg, WPARAM wParam, LPARAM lParam)
{
    writefln("PostMessage(0x%02x, %x, %x)", msg, wParam, lParam);
    if(!PostMessage(windowHandle, msg, wParam, lParam))
    {
        writefln("PostMessage(0x%x, 0x%x, 0x%x) failed (e=%s)",
            msg, wParam, lParam, GetLastError());
        assert(0, "PostMessage failed, check log");
    }
}

void handleDatagram(sockaddr_in* from, ubyte[] datagram)
{
    if(datagram.length == 0)
    {
        writefln("WARNING: received 0 length datagram from %s", *from);
        return;
    }

    auto messageID = datagram[0];
    if(messageID == ClientToServerMessage.connect)
    {
        assert(0, "connect not implemented in the handleDatagram function");
    }
    else if(messageID == ClientToServerMessage.disconnect)
    {
        assert(0, "disconnect not implemented");
    }
    //
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // !! TODO: look into how WM_INPUT works, need to
    // !! Support that as well
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    else if(messageID == ClientToServerMessage.keyDown)
    {
        assert(datagram.length == KEYDOWN_MESSAGE_LENGTH);
        auto keyCode = datagram[1];
        auto scanCode = datagram[2];
        writefln("keyDown key=0x%02x, scan=0x%02x", keyCode, scanCode);
        postWindowMessage(WM_KEYDOWN, keyCode,
            1 | // repeatCount
            ((cast(LPARAM)scanCode) << KEY_SCAN_CODE_SHIFT));
    }
    else if(messageID == ClientToServerMessage.keyUp)
    {
        assert(datagram.length == KEYUP_MESSAGE_LENGTH);
        auto keyCode = datagram[1];
        auto scanCode = datagram[2];
        writefln("keyUp   key=0x%02x, scan=0x%02x", keyCode, scanCode);
        postWindowMessage(WM_KEYUP, keyCode,
            1 | // repeatCount
            ( (cast(LPARAM)scanCode) << KEY_SCAN_CODE_SHIFT) |
            KEY_FLAG_PREVIOUS_STATE_IS_DOWN |
            KEY_FLAG_TRANSITION_STATE);
    }
    else
    {
        assert(0, format("received unknown message id %s from %s", messageID, *from));
    }
}




void dump(ubyte[] msg)
{
    foreach(i; 0..msg.length)
    {
        writefln("[%s] 0x%02x %s", i, msg[i], msg[i]);
    }
}

pragma(inline)
auto checkedMalloc(size_t size)
{
    auto result = core.stdc.stdlib.malloc(size);
    assert(result, format("malloc %s failed", size));
    return result;
}
pragma(inline)
auto mallocArray(T)(size_t size) if(T.sizeof == 1)
{
    auto result = checkedMalloc(size);
    return (cast(T*)result)[0..size];
}

struct Client
{
    sockaddr_in addr;
    void send(const(ubyte)[] message)
    {
        // HACK: for now just keep trying to resend until it works
        for(uint attemptIndex = 0;;attemptIndex++)
        {
            const sendResult = sendto(sock, message, 0, &addr);
            if(sendResult.val == message.length)
                return;

            const error = GetLastError();
            if(sendResult.val == SOCKET_ERROR && error == WSAEWOULDBLOCK)
            {
                if(attemptIndex > 0)
                writefln("WARNING: sendto failed (attempt %s) with WSAEWOULDBLOCK, temporary hack, just sleep for a bit",
                    attemptIndex);
                Thread.sleep(dur!"msecs"(10));
                //waitForSocketWriteable(sock);
            }
            else
            {
                writefln("WARNING: sendto failed (len=%s, to=%s) (return=%s, e=%s)",
                    message.length, addr, sendResult, GetLastError());
                throw new Exception("sendto failed (check log)");
            }
            if(attemptIndex >= 10)
            {
                throw new Exception(format("sendto(len=%s, to=%s) failed %s times with WSAEWOULDBLOCK",
                    message.length, sock, addr));
            }
        }
    }
    bool handleConnect(ubyte[] args)
    {
        if(args.length > 0)
        {
            writefln("Warning: invalid connect command from %s", addr);
            return false; // fail
        }

        ubyte[CONNECT_ACK_MESSAGE_LENGTH] connectAckMessage;
        connectAckMessage[0] = ServerToClientMessage.connectAck;
        connectAckMessage[1] = CONNECT_ACK_OK;
        serialize(sockSendBuffer.length, connectAckMessage.ptr + 2);

        send(connectAckMessage);
        return true;
    }
    void negotiateSettings()
    {
        // update the screen size
        windowScraper.refresh();

        // send the maximum send size

        // send the screen size
        ubyte[PIXEL_FORMAT_MESSAGE_LENGTH] pixelFormatMessage;
        pixelFormatMessage[0] = ServerToClientMessage.pixelFormat;
        pixelFormatMessage[1] = bitsPerPixel;
        serialize(windowScraper.windowSize.width, pixelFormatMessage.ptr + 2);
        serialize(windowScraper.windowSize.height, pixelFormatMessage.ptr + 6);
        send(pixelFormatMessage);
    }
    void sendFrame(ushort frameID)
    {
        auto maxFrameChunk = sockSendBuffer.length - PIXEL_DATA_HEADER_LENGTH;

        sockSendBuffer[0] = ServerToClientMessage.pixelData;
        serialize(frameID, sockSendBuffer.ptr + 1);
        uint frameByteOffset = 0;
        uint frameBytesLeft = windowScraper.bitmap.pixelBufferSize;
        for(;frameBytesLeft > 0;)
        {
            auto frameSendLength = (frameBytesLeft <= maxFrameChunk) ? frameBytesLeft : maxFrameChunk;

            serialize(frameByteOffset, sockSendBuffer.ptr + 3);
            serialize(frameSendLength, sockSendBuffer.ptr + 7);
            //writefln("frame %s, byteOffset=%s, lenght=%s", frameID, frameByteOffset, frameSendLength);
            sockSendBuffer[11..11 + frameSendLength] =
                (windowScraper.bitmap.pixelBuffer + frameByteOffset)[0..frameSendLength];
            send(sockSendBuffer[0.. 11 + frameSendLength]);

            frameBytesLeft -= frameSendLength;
            frameByteOffset += frameSendLength;
        }
    }
}

Size GetClientSize(HWND windowHandle)
{
    RECT clientRect;
    assert(GetClientRect(windowHandle, &clientRect),
        format("GetClientRect failed (e=%s)", GetLastError()));
    return Size(
        clientRect.right - clientRect.left,
        clientRect.bottom - clientRect.top);
}

struct WindowScraper
{
    HDC windowDC;
    HDC memoryDC;

    Size windowSize;
    DeviceIndependentBitmap bitmap;

    void initAfterGettingWindowHandle()
    {
        windowDC = GetDC(windowHandle);
        assert(windowDC, format("GetDC failed (e=%s)", GetLastError()));

        memoryDC = CreateCompatibleDC(windowDC);
        assert(memoryDC, format("CreateCompatibleDC failed (e=%s)", GetLastError()));
    }
    void refresh() in { assert(windowDC); } body
    {
        if(!bitmap.handle)
        {
            windowSize = GetClientSize(windowHandle);
            createAndSetBitmap();
            return;
        }
        else
        {
            // check if the bitmap needs to be recreated
            assert(0, "not implemented");
        }
    }

    private void createAndSetBitmap()
    {
        bitmap.create(memoryDC, bitsPerPixel, windowSize.width, windowSize.height);
        assert(SelectObject(memoryDC, bitmap.handle), "SelectObject failed");
    }

    void getFrame()
    {
        if(!BitBlt(memoryDC, 0, 0,
            windowSize.width, windowSize.height,
            windowDC, 0, 0, SRCCOPY))
        {
            writefln("Error: BitBlt failed (size=%s)", windowSize);
            assert(0);
        }
    }
}

struct FindWindowData
{
    bool error;
    string windowName;
    HWND match;
}

extern(Windows) BOOL windowWithPrefixCallback(HWND window, LPARAM param) nothrow
{
    auto findData = cast(FindWindowData*)param;

    auto nameBufferSize = findData.windowName.length + 1;
    if(nameBufferSize < 30)
    {
        nameBufferSize = 30;
    }
    char* buffer = cast(char*)alloca(nameBufferSize);
    assert(buffer, "alloca returned null");

    int size = GetWindowTextA(window, buffer, nameBufferSize);
    if(size == 0)
    {
        if(GetLastError())
        {
            try { writefln("WARNING: GetWindowTextA(window=%s, len=%s) failed (e=%s)",
                    window, findData.windowName.length + 1, GetLastError()); } catch(Throwable e) { }
            findData.error = true;
            return FALSE; // error, stop iteration
        }
    }
    else
    {
        if(size >= findData.windowName.length && buffer[0..findData.windowName.length] == findData.windowName)
        {
            findData.match = window;
            return FALSE; // found match, stop
        }
        if(verbose)
        {
            try { writefln("Window %s \"%s%s\"", window, buffer[0..size],
                (size + 1 == nameBufferSize) ? "..." : ""); } catch(Throwable) { }
        }
    }

    return TRUE; // continue;
}

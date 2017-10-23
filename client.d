static import core.stdc.stdlib;
import core.time : TickDuration, Duration, MonoTime;
import core.runtime : Runtime;

static import core.sys.windows.windows;
alias win = core.sys.windows.windows;
import core.sys.windows.windows :
    BOOL, TRUE, FALSE, DWORD, ULONG, HANDLE, CHAR,
    HWND, LONG, HDC, HBITMAP, LPARAM, RECT, HINSTANCE,
    ATOM, WS_OVERLAPPEDWINDOW, LPSTR, LRESULT, INT, UINT, WPARAM,
    ERROR_IO_PENDING,
    GetLastError, EnumWindows,
    GetClientRect, MoveWindow, GetDC, CreateCompatibleDC, DeleteDC,
    CreateCompatibleBitmap, CreateDIBSection, GetWindowTextA, MsgWaitForMultipleObjects,
    SelectObject, DIB_RGB_COLORS, BitBlt, StretchBlt, SRCCOPY,
    MessageBoxA, ExitProcess, WNDCLASSA, RegisterClassA, AdjustWindowRect,
    GetActiveWindow, MB_OK, HBRUSH, LoadCursor, GetWindowRect,
    CreateWindowExA, ShowWindow, MSG, GetMessage, PeekMessage, DispatchMessage,
    DestroyWindow, PostQuitMessage, DefWindowProc,
    COLOR_WINDOW, NULL, IDC_ARROW, CW_USEDEFAULT, PM_REMOVE, TranslateMessage,
    WAIT_OBJECT_0, INFINITE, QS_ALLINPUT,
    PAINTSTRUCT, BeginPaint, EndPaint,
    ValidateRect, GetUpdateRect, InvalidateRect,
    WM_QUIT, WM_CLOSE, WM_DESTROY,  WM_NCLBUTTONDOWN, WM_SYSCOMMAND,
    WM_PAINT, WM_NCPAINT, WM_ERASEBKGND, WM_MOUSEMOVE, WM_SIZING,
    WM_GETMINMAXINFO, WM_NCCREATE, WM_NCCALCSIZE, WM_CREATE, WM_SHOWWINDOW,
    WM_WINDOWPOSCHANGING, WM_ACTIVATEAPP, WM_NCACTIVATE, WM_ACTIVATE, WM_SETFOCUS,
    WM_GETICON, WM_WINDOWPOSCHANGED, WM_SIZE, WM_MOVE, WM_SETCURSOR, WM_NCHITTEST,
    WM_KEYDOWN, WM_KEYUP, WM_INPUT,
    FillRect, CS_HREDRAW, CS_VREDRAW,
    OVERLAPPED;
import core.sys.windows.winsock2 :
    WSAOVERLAPPED;

struct WSABUF {
    ULONG len;
    ubyte* buf;
}

enum WSA_IO_PENDING = ERROR_IO_PENDING;
alias WSAEVENT = HANDLE;
enum WSA_INVALID_EVENT = null;
extern(Windows) WSAEVENT WSACreateEvent() nothrow @nogc @safe;
extern(Windows) int WSARecvFrom(
  socket_t          s,
  WSABUF*           lpBuffers,
  DWORD             dwBufferCount,
  DWORD*            lpNumberOfBytesRecvd,
  DWORD*            lpFlags,
  sockaddr          *lpFrom,
  INT*              lpFromlen,
  WSAOVERLAPPED*    lpOverlapped,
  void*             lpCompletionRoutine
)  nothrow @nogc @safe;
extern(Windows) BOOL WSAGetOverlappedResult(
  socket_t          s,
  WSAOVERLAPPED*    lpOverlapped,
  DWORD*            lpcbTransfer,
  BOOL              fWait,
  DWORD*            lpdwFlags
)  nothrow @nogc @safe;

import std.stdio : File;
import std.format : format, formattedWrite;
import std.array  : Appender;
import std.typecons : Flag, Yes, No;
import std.datetime : StopWatch, AutoStart;
import std.algorithm : sort;
import std.internal.cstring : tempCString;

import more.net;

import util;
import sharedwindows;
import protocol;
import gdibitmap;

//enum SERVER_IP = 0x7F000001;
//enum SERVER_IP = 0xC0A80002; // 192.168.0.2
enum SERVER_IP = 0x18758109; // 24.117.129.9

enum SERVER_PORT = 8080;

__gshared HINSTANCE WinMainInstance;
__gshared uint updatesToRender;

void fatalError(string message) nothrow
{
    try { Logger.log(message); } catch(Throwable) { }
    auto messageCString = tempCString(message);
    int result = MessageBoxA(GetActiveWindow(), messageCString, cstring!"Fatal Error".ptr, MB_OK);
    ExitProcess(1);
}
void fatalErrorf(T...)(string fmt, T args) nothrow
{
    string message;
    try
    {
        message = format(fmt, args);
    }
    catch(Throwable)
    {
        message = "(format error message failed) "~fmt;
    }
    fatalError(message);
}
void assertMessageBox(T)(T condition, lazy string message, string file = __FILE__, uint line = __LINE__)
{
    if(!condition)
    {
        fatalErrorf("%s(%s): %s", file, line, message);
    }
}

void* malloc(size_t size)
{
    auto ptr = core.stdc.stdlib.malloc(size);
    if(!ptr)
    {
        fatalErrorf("malloc(%s) failed (e=%s)", size, GetLastError());
        assert(0);
    }
    return ptr;
}
void dump(ubyte[] msg)
{
    foreach(i; 0..msg.length)
    {
        Logger.logf("[%s] 0x%02x %s", i, msg[i], msg[i]);
    }
}

ATOM registerWindowClass(HINSTANCE instance, const(CString) windowClassName)
{
    WNDCLASSA windowClass;
    //windowClass.style         = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc   = &WindowProc;
    windowClass.hInstance     = instance;
    windowClass.lpszClassName = windowClassName.ptr;
    //windowClass.hbrBackground = cast(HBRUSH)(COLOR_WINDOW+1);
    windowClass.hCursor       = LoadCursor(NULL, IDC_ARROW);
    assertMessageBox(windowClass.hCursor, "LoadCursor failed");
    Logger.logf("window class is %s", windowClass);
    ATOM result = RegisterClassA(&windowClass);
    if(result == 0)
    {
        fatalErrorf("RegisterClass(\"%s\") failed (e=%s)", windowClassName, GetLastError());
    }
    return result;
}

enum WINDOW_STYLE = WS_OVERLAPPEDWINDOW;

struct Datagram
{
    sockaddr_in* from;
    ubyte[] data;
}

struct EventSocket
{
    __gshared static socket_t sock;
    __gshared static HANDLE eventHandle;
    __gshared static sockaddr_in from;
    __gshared static INT fromlen;
    __gshared static WSABUF wsaBuf;
    __gshared static OVERLAPPED overlapped;

    static void initAsync()
    {
        // Create a windows event that can handle socket events
        overlapped.hEvent = WSACreateEvent();
        if(overlapped.hEvent == WSA_INVALID_EVENT)
        {
            fatalErrorf("WSACreateEvent failed (e=%s)", GetLastError());
        }
    }

    static void recvAllAsync()
    {
        for(;;)
        {
            auto datagram = recvAsync();
            if(datagram is null)
            {
                return;
            }
            handleDatagram(datagram);
        }
    }

    // returns null if no data was received yet
    private static ubyte[] recvAsync()
    {
        DWORD received;
        DWORD flags = 0;
        fromlen = from.sizeof;
        if(0 == WSARecvFrom(
            sock,
            &wsaBuf, 1,
            &received,
            &flags,
            cast(sockaddr*)&from, &fromlen,
            cast(WSAOVERLAPPED*)&overlapped,
            null))
        {
            //Logger.logf("WSARecvFrom returned immediate %s-byte packet", received);
            return wsaBuf.buf[0..received]; // got data
        }

        auto error = GetLastError();
        if(error == WSA_IO_PENDING)
        {
            return null; // no data yet
        }

        fatalErrorf("WSARecvFrom failed (e=%s)", error);
        assert(0);
    }
}
void sendToServer(ubyte[] message)
{
    auto result = sendto(EventSocket.sock, message, 0, &serverAddr);
    if(result != message.length)
    {
        fatalErrorf("Warning: sendto(len=%s, to=%s) failed (return=%s, e=%s)",
            message.length, serverAddr, result, GetLastError());
        assert(0);
    }
}

__gshared HWND windowHandle;

__gshared sockaddr_in serverAddr;

struct Gdi
{
    __gshared static HDC windowDC;
    __gshared static HDC memoryDC;
    __gshared static DeviceIndependentBitmap bitmap;
}

__gshared MonoTime globalStartTime;
__gshared TimeBin globalDefaultTimeBin;
__gshared Appender!(TimeBin[]) globalTimeBinStack;

extern (Windows) int WinMain(HINSTANCE instance, HINSTANCE previousInstance, LPSTR cmdLine, int cmdShow)
{
    try
    {
        Runtime.initialize();
        globalStartTime = MonoTime.currTime;
        globalDefaultTimeBin = new TimeBin();
        globalTimeBinStack.put(globalDefaultTimeBin);

        WinMainInstance = instance;
        Logger.init("client.log");

        //
        // TEMPORARILY PUTTING THIS HERE
        //
        serverAddr = sockaddr_in(AddressFamily.inet, htons(SERVER_PORT), in_addr(htonl(SERVER_IP)));
        EventSocket.sock = createsocket(serverAddr.sin_family, SocketType.dgram, Protocol.udp);
        if(EventSocket.sock.isInvalid)
        {
            // TODO: error message box would be better
            Logger.logf("Error: createSocket failed (e=%s)", GetLastError());
            return 1; // fail
        }
        {
            sockaddr_in localAddr = sockaddr_in(AddressFamily.inet, 0, in_addr.any);
            if(failed(bind(EventSocket.sock, &localAddr)))
            {
                Logger.logf("Error: bind failed (e=%s)", GetLastError());
                return 1;
            }
        }

        // connect to server
      SEND_RECV_LOOP:
        for(int attempt = 0;;attempt++)
        {
            Logger.logf("sending connect command to %s", serverAddr);
            {
                ubyte[CONNECT_MESSAGE_LENGTH] connectMessage;
                connectMessage[0] = ClientToServerMessage.connect;
                sendToServer(connectMessage);
            }
            for(;;)
            {
                sockaddr_in from;
                ubyte[CONNECT_ACK_MESSAGE_LENGTH] connectAck;
                Logger.logf("waiting for connect-ack");
                auto length = recvfrom(EventSocket.sock, connectAck, 0, &from);
                if(!from.equals(serverAddr))
                {
                    Logger.logf("Warning: got a packet from %s which is not the same as the server %s",
                        from, serverAddr);
                    continue;
                }
                if(length != CONNECT_ACK_MESSAGE_LENGTH || connectAck[0] != ServerToClientMessage.connectAck)
                {
                    Logger.logf("Warning: got an invalid connectAck command (length=%s, command=%s) from the server",
                        length, connectAck[0]);
                    if(attempt > 10)
                    {
                        Logger.logf("giving up after %s attempts", attempt + 1);
                        return 1; // fail
                    }
                    continue SEND_RECV_LOOP;
                }
                auto status = connectAck[1];
                if(status != CONNECT_ACK_OK)
                {
                    Logger.logf("Error: server refused connection (e=%s)", status);
                    return 1; // fail
                }
                EventSocket.wsaBuf.len = deserialize!uint(connectAck.ptr + 2);
                Logger.logf("maximum socket recv length is %s", EventSocket.wsaBuf.len);
                EventSocket.wsaBuf.buf = cast(ubyte*)malloc(EventSocket.wsaBuf.len);
                break SEND_RECV_LOOP;
            }
        }

        auto windowClassName = cstring!"GameShareWindowClass";
        auto windowClass = registerWindowClass(WinMainInstance, windowClassName);

        windowHandle = CreateWindowExA(
            0,
            windowClassName.ptr,
            cstring!"GameShare Client".ptr,
            WINDOW_STYLE,
            // Size and position
            CW_USEDEFAULT, CW_USEDEFAULT, 500, 400,
            null,       // Parent window
            null,       // Menu
            instance,   // Instance handle
            null        // Additional application data
        );
        if(windowHandle == null)
        {
            fatalErrorf("CreateWindowExA failed (e=%s)", GetLastError());
        }
        Gdi.windowDC = GetDC(windowHandle);
        assertMessageBox(Gdi.windowDC, format("GetDC failed (e=%s)", GetLastError()));
        Gdi.memoryDC = CreateCompatibleDC(Gdi.windowDC);
        assertMessageBox(Gdi.memoryDC, format("CreateCompatibleDC failed (e=%s)", GetLastError()));

        // TODO: move this to later
        EventSocket.initAsync();
        EventSocket.recvAllAsync();

        ShowWindow(windowHandle, cmdShow);
        HANDLE[1] eventObjects;
        eventObjects[0] = EventSocket.overlapped.hEvent;

        for(;;)
        {

            msgWaitForMultipleObjectsTimeBin.enter();
            auto result = MsgWaitForMultipleObjects(eventObjects.length, eventObjects.ptr, FALSE, INFINITE, QS_ALLINPUT);
            msgWaitForMultipleObjectsTimeBin.exit();
            if(result == WAIT_OBJECT_0 + eventObjects.length)
            {
                // TODO: may want to limit how long we take to process
                //       pending messages
                if(Yes.quit == processAllPendingMessages())
                {
                    break;
                }
            }
            else if(result >= WAIT_OBJECT_0 && result < WAIT_OBJECT_0 + eventObjects.length)
            {
                auto eventIndex = result - WAIT_OBJECT_0;

                // right now the only thing this could be is the socket event
                assert(eventIndex == 0);

                handleSocketEvent();
            }
            else
            {
                throw new Exception(format("unexpected return value from MsgWaitForMulipleObjects (result=%s, e=%s)", result, GetLastError()));
            }
        }

        Logger.logf("MsgWaitForMultipleObjects time (%s)",
            msgWaitForMultipleObjectsTimeBin.format);
        // Log some performance
        windowProcTimes.log("WindowProc");

        Logger.logf("Total Time: %s", (MonoTime.currTime - globalStartTime).formatDuration);
        Runtime.terminate();
        return 0;
    }
    catch(Throwable e)
    {
        try {fatalErrorf("Unhandled Exception in WinMain: %s", e); } catch(Throwable) { }
        ExitProcess(1);
        return 1;
    }
}

//
// Process All pending messages
//
// TODO: may want to limit how long we take to process
//       pending messages
Flag!"quit" processAllPendingMessages()
{
    for(;;)
    {
        MSG msg;
        if(!PeekMessage(&msg, null, 0, 0, PM_REMOVE))
        {
            return No.quit;
        }

        TranslateMessage(&msg);
        DispatchMessage(&msg);

        if(msg.message == WM_QUIT)
        {
            Logger.log("WM_QUIT");
            return Yes.quit;
        }
    }
}

void handleSocketEvent()
{
    DWORD received;
    DWORD flags;
    if(!WSAGetOverlappedResult(
        EventSocket.sock,
        cast(WSAOVERLAPPED*)&EventSocket.overlapped,
        &received,
        FALSE,
        &flags))
    {
        fatalErrorf("WSAGetOverlappedResult failed (e=%d) (not implemented)", GetLastError());
        assert(0);
    }
    handleDatagram(EventSocket.wsaBuf.buf[0..received]);
    EventSocket.recvAllAsync();
}

void handleDatagram(ubyte[] datagram)
{
    if(!EventSocket.from.equals(serverAddr))
    {
        Logger.logf("Received %s-byte datagram from non-server host %s", datagram.length, EventSocket.from);
        return;
    }

    if(datagram.length == 0)
    {
        Logger.logf("WARNING: received 0 length datagram from server?");
        return;
    }

    //Logger.logf("[DEBUG] Received %s-byte datagram from the server", datagram.length);
    /*
    foreach(i; 0..datagram.length)
    {
        import std.stdio;
        writefln("[%s] 0x%x", i, datagram[i]);
    }
    */
    auto messageID = datagram[0];
    if(messageID == ServerToClientMessage.heartbeat)
    {
        assertMessageBox(datagram.length == HEARTBEAT_MESSAGE_LENGTH, "invlid heartbeat message length");
    }
    else if(messageID == ServerToClientMessage.pixelFormat)
    {
        assertMessageBox(datagram.length == PIXEL_FORMAT_MESSAGE_LENGTH, "invalid pixel format message length");
        auto bitsPerPixel = datagram[1];
        handlePixelFormat(bitsPerPixel, Size(
            deserialize!uint(datagram.ptr + 2),
            deserialize!uint(datagram.ptr + 6)));
    }
    else if(messageID == ServerToClientMessage.pixelData)
    {
        if(datagram.length < PIXEL_DATA_HEADER_LENGTH)
        {
            fatalErrorf("Error: received pixel data message that was too small (only %s bytes)",
                datagram.length);
            assert(0);
        }
        ushort frameID       = deserialize!ushort(datagram.ptr + 1);
        uint frameByteOffset = deserialize!uint  (datagram.ptr + 3);
        uint length          = deserialize!uint  (datagram.ptr + 7);

        auto expectedLength = PIXEL_DATA_HEADER_LENGTH + length;
        if(datagram.length != expectedLength)
        {
            fatalErrorf("Error: expected pixel data message to be %s bytes but is %s",
                expectedLength, datagram.length);
            assert(0);
        }
        //Logger.logf("Received frame pixel data (frame %s, byteOffset=%s, length=%s)",
        //    frameID, frameByteOffset, length);

        // TODO: handle frame id correctly
        Gdi.bitmap.pixelBuffer[frameByteOffset..frameByteOffset + length] =
            datagram.ptr[11..11 + length];

        // for now, only invalidate on the last frame
        if(frameByteOffset + length == Gdi.bitmap.pixelBufferSize)
        {
            //auto windowRect = RECT(0, 0, windowSize.width, windowSize.height);
            assertMessageBox(InvalidateRect(windowHandle, null, false),
                format("InvalideRect failed (e=%s)", GetLastError()));
        }
    }
    else
    {
        fatalErrorf("Error: unknown message from server (id=%s, length=%s)", messageID, datagram.length);
        assert(0);
    }
}

void handlePixelFormat(ubyte bitsPerPixel, Size size)
{
    Logger.logf("Received PixelFormat bpp=%s %s", bitsPerPixel, size);
    setWindowContentSize(size);

    if(Gdi.bitmap.handle)
    {
        assertMessageBox(0, "not implemented");
    }
    Gdi.bitmap.create(Gdi.memoryDC, bitsPerPixel, size.width, size.height);
    Logger.logf("pixelBuffer is %s", Gdi.bitmap.pixelBuffer);
    /+
    // put some random data in there
    foreach(i; 0..Gdi.bitmap.pixelBufferSize)
    {
        Logger.logf("index %s", i);
        if(i % 3 == 0)
        {
            Gdi.bitmap.pixelBuffer[i] = 0xFF;
        }
        else
        {
            Gdi.bitmap.pixelBuffer[i] = 0;
        }
    }
    +/
    assertMessageBox(SelectObject(Gdi.memoryDC, Gdi.bitmap.handle), "SelectObject failed");
}


void AdjustWindowSize(Size* size)
{
    RECT adjustedRect = RECT(0, 0, size.width, size.height);
    assert(AdjustWindowRect(&adjustedRect, WINDOW_STYLE, FALSE), "AdjustWindowRect failed");
    size.width = adjustedRect.right - adjustedRect.left;
    size.height = adjustedRect.bottom - adjustedRect.top;
}

void setWindowContentSize(Size newContentSize)
{
    Size newWindowSize = newContentSize;
    AdjustWindowSize(&newWindowSize);

    RECT currentRect;
    if(!GetWindowRect(windowHandle, &currentRect))
    {
        fatalErrorf("Error: GetWindowRect failed (e=%s)", GetLastError());
        assert(0);
    }

    auto currentSize = Size(
        currentRect.right - currentRect.left,
        currentRect.bottom - currentRect.top);
    Logger.logf("Resizing window (current %s, newContentSize %s, newWindowSize %s)",
        currentSize, newContentSize, newWindowSize);

    if(!MoveWindow(windowHandle, currentRect.left, currentRect.top,
        newWindowSize.width, newWindowSize.height, TRUE))
    {
        fatalErrorf("Error: MoveWindow failed (e=%s)", GetLastError());
        assert(0);
    }
}



class TimeBin
{
    uint callCount;

    Duration inclusiveDuration;
    MonoTime inclusiveEnterTime;

    Duration exclusiveDuration;
    MonoTime exclusiveTime;

    TimeBin previousGlobalTimeBin;

    auto enter()
    {
        callCount++;
        auto now = MonoTime.currTime;
        inclusiveEnterTime = now;
        exclusiveTime = now;

        auto previous = globalTimeBinStack.data[$-1];
        auto previousDurationToAdd = now - previous.exclusiveTime;
        previous.exclusiveDuration += previousDurationToAdd;
        globalTimeBinStack.put(this);
        return previousDurationToAdd;
    }
    void exit()
    {
        auto now = MonoTime.currTime;
        inclusiveDuration += now - inclusiveEnterTime;
        exclusiveDuration += now - exclusiveTime;

        auto popped = globalTimeBinStack.data[$-1];
        assertMessageBox(this == popped, "code bug in TimeBin.exit");

        globalTimeBinStack.shrinkTo(globalTimeBinStack.data.length - 1);

        auto previous = globalTimeBinStack.data[$-1];
        previous.exclusiveTime = now;
    }
    @property auto format()
    {
        static struct Formatter
        {
            TimeBin timeBin;
            void toString(scope void delegate(const(char)[]) sink) const
            {
                formattedWrite(sink, "%s calls, inclusive=%s, exclusive=%s",
                    timeBin.callCount, timeBin.inclusiveDuration.formatDuration,
                    timeBin.exclusiveDuration.formatDuration);
            }
        }
        return Formatter(this);
    }
}
__gshared TimeBin waitForMessageTimeBin;

struct MessagePerformance
{
    uint msg;
    string msgName;
    TimeBin timeBin;
    alias timeBin this;
    this(uint msg, string msgName = null)
    {
        this.msg = msg;
        this.msgName = msgName;
        this.timeBin = new TimeBin();
    }
    void toString(scope void delegate(const(char)[]) sink) const
    {
        if(msgName !is null)
        {
            formattedWrite(sink, "%s(0x%x)", msgName, msg);
        }
        else
        {
            formattedWrite(sink, "0x%x", msg);
        }
    }
}
auto messageTimeBins(Flag!"dynamic" dynamic = No.dynamic)(MessagePerformance[] messageTable)
{
    return MessageTimeBins!dynamic(messageTable);
}
struct MessageTimeBins(Flag!"dynamic" dynamic)
{
    MessagePerformance[] messageTable;
    static if(!dynamic)
    {
        TimeBin unknownTimeBin;
    }
    this(MessagePerformance[] messageTable)
    {
        this.messageTable = messageTable;
    }
    TimeBin getTimeBin(UINT msg)
    {
        foreach(i; 0..messageTable.length)
        {
            if(messageTable[i].msg == msg)
            {
                return messageTable[i].timeBin;
            }
        }
        static if(dynamic)
        {
            messageTable ~= MessagePerformance(msg);
            assertMessageBox(messageTable[$-1].msg == msg, "code bug in MessageTimeBins");
            return messageTable[$-1].timeBin;
        }
        else
        {
            return unknownTimeBin;
        }
    }
    void log(string name)
    {
        sort!q{a.timeBin.inclusiveDuration < b.timeBin.inclusiveDuration}(messageTable);
        foreach(i; 0..messageTable.length)
        {
            auto messageTime = &messageTable[i];
            Logger.logf("%s(msg=%s) (%s)", name, *messageTime, messageTime.format);
        }
        static if(!dynamic)
        {
            Logger.logf("%s(msg=unknown) (%s)", name, unknownTimeBin.format);
        }
    }
}
__gshared TimeBin msgWaitForMultipleObjectsTimeBin = new TimeBin();
__gshared auto windowProcTimes = messageTimeBins!(Yes.dynamic)([
    MessagePerformance(WM_NCLBUTTONDOWN, "WM_NCLBUTTONDOWN"),
    MessagePerformance(WM_SYSCOMMAND   , "WM_SYSCOMMAND"),
    MessagePerformance(WM_PAINT        , "WM_PAINT"),
    MessagePerformance(WM_NCPAINT      , "WM_NCPAINT"),
    MessagePerformance(WM_SIZING       , "WM_SIZING"),
]);
/*
__gshared auto dispatchMessageTimes = messageTimeBins!(Yes.dynamic)([
    MessagePerformance(WM_NCLBUTTONDOWN),
]);
*/

auto formatSpaces(uint spaceCount)
{
    static struct Formatter
    {
        uint spaceCount;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            foreach(i; 0..spaceCount)
            {
                sink(" ");
            }
        }
    }
    return Formatter(spaceCount);
}

extern(Windows) LRESULT WindowProc(HWND windowHandle, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    try
    {
        auto messageTimeBin = windowProcTimes.getTimeBin(msg);
        auto previousTimBinDuration = messageTimeBin.enter();
        scope(exit) messageTimeBin.exit();

        /*
        static uint depth = 0;
        static bool staticStopwatchStarted = false;
        static StopWatch staticStopwatch;
        if(!staticStopwatchStarted)
        {
            staticStopwatch.start();
            staticStopwatchStarted = true;
        }

        auto previousTimeElapsed = staticStopwatch.peek();
        staticStopwatch.reset();

        auto stopwatch = StopWatch(AutoStart.yes);
        Logger.logf("%s> message=%s (%s)", formatSpaces(depth), msg, previousTimBinDuration.formatDuration);
        depth += 4;
        scope(exit)
        {
            auto timeElapsed = staticStopwatch.peek();
            staticStopwatch.reset();
            depth -= 4;
            Logger.logf("%s< message=%s (%s)", formatSpaces(depth), msg, timeElapsed.fmtNice);
        }
        */

        switch (msg)
        {
        case WM_INPUT:
            Logger.logf("WM_INPUT 0x%x 0x%x", wParam, lParam);
            break;
        case WM_KEYDOWN:
            if(0 == (lParam & KEY_FLAG_PREVIOUS_STATE_IS_DOWN))
            {
                ubyte keyCode = cast(ubyte)wParam;
                ubyte scanCode = cast(ubyte)(lParam >> KEY_SCAN_CODE_SHIFT);
                assert(keyCode == wParam, "keyCode was not 8 bits!");
                Logger.logf("KeyDown key=0x%02x scan=0x%02x (lParam = 0x%08x)", keyCode, scanCode, lParam);
                ubyte[KEYDOWN_MESSAGE_LENGTH] message;
                message[0] = ClientToServerMessage.keyDown;
                message[1] = keyCode;
                message[2] = scanCode;
                sendToServer(message);
            }
            break; // pass the message to DefWindowProc
        case WM_KEYUP:
            {
                ubyte keyCode = cast(ubyte)wParam;
                ubyte scanCode = cast(ubyte)(lParam >> KEY_SCAN_CODE_SHIFT);
                assert(keyCode == wParam, "keyCode was not 8 bits!");
                Logger.logf("KeyUp   key=0x%02x scan=0x%02x (lParam = 0x%08x)", keyCode, scanCode, lParam);
                ubyte[KEYUP_MESSAGE_LENGTH] message;
                message[0] = ClientToServerMessage.keyUp;
                message[1] = keyCode;
                message[2] = scanCode;
                sendToServer(message);
            }
            break; // pass the message to DefWindowProc
        case WM_CLOSE:
            DestroyWindow(windowHandle);
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_PAINT:
            {
                PAINTSTRUCT paintStruct;
                auto dc = BeginPaint(windowHandle, &paintStruct);
                assertMessageBox(dc, format("BeginPaint failed (e=%s)", GetLastError()));
                //assertMessageBox(dc == Gdi.windowDC,
                //    format("BeginPaint returned unexpected DC (expected %s, got %s)", Gdi.windowDC, dc));
                // TODO: just need to make sure the current memoryDC and bitmap are compatible

                Size paintSize = Size(
                    paintStruct.rcPaint.right - paintStruct.rcPaint.left,
                    paintStruct.rcPaint.bottom - paintStruct.rcPaint.top);
                //Logger.logf("WM_PAINT %s, %s %s", paintStruct.rcPaint.left, paintStruct.rcPaint.top, paintSize);

                if(Gdi.bitmap.handle)
                {
                /*
                    assertMessageBox(BitBlt(dc, paintStruct.rcPaint.left, paintStruct.rcPaint.top,
                        paintSize.width, paintSize.height, Gdi.memoryDC,
                        paintStruct.rcPaint.left, paintStruct.rcPaint.top, SRCCOPY),
                        format("BitBlt failed (e=%s)", GetLastError()));
                        */
                    RECT clientRect;
                    assertMessageBox(GetClientRect(windowHandle, &clientRect), "GetClientRect failed");
                    assertMessageBox(StretchBlt(dc, 0, 0, clientRect.right - clientRect.left,
                        clientRect.bottom - clientRect.top,
                        Gdi.memoryDC, 0, 0,
                        Gdi.bitmap.info.gdiInfo.bmiHeader.biWidth,
                        -Gdi.bitmap.info.gdiInfo.bmiHeader.biHeight, SRCCOPY),
                        format("BitBlt failed (e=%s)", GetLastError()));
                }
                else
                {
                    // paint something here?
                }

                EndPaint(windowHandle, &paintStruct);
            }
            return 0;
        default:
            break;
        }

        /*
        if(true
            && msg != WM_NCPAINT
            && msg != WM_NCLBUTTONDOWN
            && msg != WM_SYSCOMMAND
            //&& msg != WM_GETMINMAXINFO
            && msg != WM_NCCREATE
            && msg != WM_NCCALCSIZE
            && msg != WM_CREATE
            && msg != WM_SHOWWINDOW
            //&& msg != WM_WINDOWPOSCHANGING
            && msg != WM_ACTIVATEAPP
            && msg != WM_NCACTIVATE
            && msg != WM_NCHITTEST
            && msg != WM_ACTIVATE
            && msg != WM_SETFOCUS
            //&& msg != WM_GETICON
            //&& msg != WM_WINDOWPOSCHANGED
            //&& msg != WM_SIZE
            //&& msg != WM_MOVE
            && msg != WM_SETCURSOR
        )
        {
            Logger.logf("Ignoring Windows Message %s", msg);
            return 0;
        }
        */

        return DefWindowProc(windowHandle, msg, wParam, lParam);
    }
    catch(Throwable e)
    {
        try {fatalErrorf("Unhandled Exception in WindowProc: %s", e); } catch(Throwable) { }
        ExitProcess(1);
        return 1; // fail
    }
}

@property auto formatDuration(Duration duration)
{
    struct Formatter
    {
        Duration duration;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            if(duration.total!"msecs" == 0)
            {
                formattedWrite(sink, "%s us", duration.total!"usecs");
            }
            else if(duration.total!"seconds" == 0)
            {
                formattedWrite(sink, "%s.%03d ms", duration.total!"msecs", duration.total!"usecs" % 1000);
            }
            else
            {
                formattedWrite(sink, "%s.%03d s", duration.total!"seconds", duration.total!"msecs" % 1000);
            }
        }
    }
    return Formatter(duration);
}
auto fmtNice(TickDuration duration)
{
    struct Formatter
    {
        TickDuration duration;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            if(duration.msecs == 0)
            {
                formattedWrite(sink, "%s us", duration.usecs);
            }
            else if(duration.seconds == 0)
            {
                formattedWrite(sink, "%s.%03d ms", duration.msecs, duration.usecs % 1000);
            }
            else
            {
                formattedWrite(sink, "%s.%03d s", duration.seconds, duration.msecs % 1000);
            }
        }
    }
    return Formatter(duration);
}

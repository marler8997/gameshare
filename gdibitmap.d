module gdibitmap;

import core.sys.windows.windows;

import std.format : format;

import util : alignTo, checkedMalloc;

struct BitmapInfo
{
    BITMAPINFO gdiInfo;
    uint scanSize; // size of each row
    uint pixelBufferSize;

    void set(ushort bitsPerPixel, uint width, uint height)
    {
        uint unpaddedRowSize = (cast(uint)bitsPerPixel * width) / 8;
        scanSize = unpaddedRowSize.alignTo(4);
        //writefln("row is %s pixels, bitsPerPixel = %s, unpadded bytes size is %s, padded is %s",
        //    width, bitsPerPixel, unpaddedRowSize, scanSize);

        pixelBufferSize = scanSize * height;

        gdiInfo.bmiHeader.biSize          = gdiInfo.bmiHeader.sizeof;
        gdiInfo.bmiHeader.biWidth         = width;
        gdiInfo.bmiHeader.biHeight        = -cast(LONG)height;
        gdiInfo.bmiHeader.biPlanes        = 1;
        gdiInfo.bmiHeader.biBitCount      = bitsPerPixel;
        gdiInfo.bmiHeader.biCompression   = BI_RGB;
        gdiInfo.bmiHeader.biSizeImage     = 0;
        gdiInfo.bmiHeader.biXPelsPerMeter = 0;
        gdiInfo.bmiHeader.biYPelsPerMeter = 0;
        gdiInfo.bmiHeader.biClrUsed       = 0;
        gdiInfo.bmiHeader.biClrImportant  = 0;
    }
}

struct DeviceIndependentBitmap
{
    BitmapInfo info;
    HBITMAP handle;
    ubyte* pixelBuffer;
    alias info this;
    
    void create(HDC dc, ushort bitsPerPixel, uint width, uint height) in { assert(!handle); } body
    {
        info.set(bitsPerPixel, width, height);
        void* bits;
        handle = CreateDIBSection(dc, &info.gdiInfo, DIB_RGB_COLORS, &bits, null, 0);
        this.pixelBuffer = cast(ubyte*)bits;
        assert(handle, format("CreateDIBSection failed (e=%s)", GetLastError()));
    }
}

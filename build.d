import dbuild;

int main(string[] args)
{
    auto morePath = buildPath("..", "mored");
    auto netSource = buildPath(morePath, "more", "net.d");
    auto builderSource = buildPath(morePath, "more", "builder.d");

    dlang.exe("client")
        .library("windows.def")
        .library("gdi32.lib")
        .library("ws2_32.lib")
        // TODO: this is the wrong way to configure a version
        .library("-version=ANSI")
        .includePath(morePath)
        .source("client.d")
        .source("util.d")
        .source("sharedwindows.d")
        .source("protocol.d")
        .source("gdibitmap.d")
        .source(netSource)
        ;
    dlang.exe("server")
        .library("gdi32.lib")
        .includePath(morePath)
        .source("server.d")
        .source("util.d")
        .source("sharedwindows.d")
        .source("protocol.d")
        .source("gdibitmap.d")
        .source(netSource)
        .source(builderSource)
        ;
    return runBuild(args);
}
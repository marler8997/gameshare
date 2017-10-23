* Support monochrome to decrease network traffic
* Create a custom gdi or directx driver that looks like a different display.
  You can direct the game to render to that display.
  Checkout how virtualmonitor does this (http://virtualmonitor.github.io/)
* Add "control commands" to the server via UDP (maybe also tcp)?
* Add UI to client, allow you to write the server host/port.
* Add persistent configuration to server and client

* Add server setting to maintain 2 buffers and send the client diffs instead of the whole frame.  This would mean adding a parameter or a new command to indicate when the frame data is complete (since the whole frame is no longer sent, that can't be used to know when the frame data has all been sent)
* No drop messages. Every message sent should include the latest nodrop sequence id.  This allows the receiver to detect if any previous "no drop" messages were lost.
* Add pallet bitmaps. Add server setting to limit the palette table by some power of 2. This will change the bits per pixel to some lower value. Also, maybe support dynamic palettes, the server sends and remembers a set of palettes it has sent to the client and reuses them.
* Add performance information, especially on client side.  Keeps track of how much time it spends in windows events, vs receiving packets, vs drawing, etc.
* Implement disconnect

# Saved Notes

> Modify client to repaint immediately on last frame data, also, the recv loop could be modified to call handleAllPendingEvents if it hasnt handled events for a while (dont want to starve the window message loop)
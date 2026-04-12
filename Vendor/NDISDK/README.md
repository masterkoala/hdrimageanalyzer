# NDI SDK (optional)

**NewTek NDI** is used by the Network module for source discovery (Phase 9, NET-001).

The app **does not require** the NDI SDK at build time. It loads the NDI library **dynamically at runtime** from these locations (in order):

- `libndi.dylib` (current working directory or `DYLD_LIBRARY_PATH`)
- `/usr/local/lib/libndi.dylib`
- `/Library/NDI Advanced SDK for Apple/lib/macOS/libndi.dylib`

To enable NDI source discovery:

1. Download **NDI SDK for Apple** from [ndi.video/sdk](https://ndi.video/sdk) (free).
2. Install the NDI runtime or copy `libndi.dylib` (or `libndi.5.dylib`) to one of the paths above.

If the NDI library is not found, discovery is a no-op and `currentNDISources()` returns an empty list.

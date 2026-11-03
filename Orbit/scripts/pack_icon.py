"""Pack PNG representations into an ICNS container without external libraries."""
import pathlib
import struct
import sys

folder = pathlib.Path(sys.argv[1])
chunks = []
for code, name in [(b"ic07", "icon_128x128.png"), (b"ic08", "icon_256x256.png"),
                   (b"ic09", "icon_512x512.png"), (b"ic10", "icon_512x512@2x.png")]:
    data = (folder / name).read_bytes()
    chunks.append(code + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
pathlib.Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)

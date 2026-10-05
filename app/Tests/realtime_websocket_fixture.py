"""Single-use localhost RFC 6455 fixture; standard library only, no provider calls."""
import base64
import hashlib
import json
import pathlib
import socket
import struct
import sys


def read_exact(connection, count):
    result = b""
    while len(result) < count:
        block = connection.recv(count - len(result))
        if not block:
            raise RuntimeError("fixture client disconnected")
        result += block
    return result


with socket.socket() as listener:
    listener.settimeout(15)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    pathlib.Path(sys.argv[1]).write_text(str(listener.getsockname()[1]))
    connection, address = listener.accept()
    with connection:
        connection.settimeout(10)
        request = b""
        while not request.endswith(b"\r\n\r\n"):
            request += read_exact(connection, 1)
        lines = request.decode("ascii").split("\r\n")
        headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
        headers = {name.lower(): value.strip() for name, value in headers.items()}
        assert headers.get("x-test-credential") == "fixture-local-only"
        key = headers["sec-websocket-key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
        first, second = read_exact(connection, 2)
        assert first & 0x0F == 1
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(connection, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(connection, 8))[0]
        assert second & 0x80
        mask = read_exact(connection, 4)
        payload = read_exact(connection, length)
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        result = json.dumps({"echo": payload.decode()}).encode()
        assert len(result) < 126
        connection.sendall(bytes([0x81, len(result)]) + result)
        # Wait for the client's close so native receive is exercised without a race.
        connection.recv(256)

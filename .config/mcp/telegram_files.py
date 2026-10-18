"""Bounded attachment envelopes shared by the client, broker and Telegram route.

The client snapshots bytes before confirmation. Services receive bytes, never an
owner-controlled path or URL. The installer copies this module beside each service.
"""
import base64
import binascii
import hashlib
import os
import stat

MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_REQUEST_BYTES = 4 * ((MAX_FILE_BYTES + 2) // 3) + 65536
MAX_CAPTION = 1024


def validate_attachment(value):
    """Return decoded bytes, or ValueError before any popup/upload."""
    if not isinstance(value, dict):
        raise ValueError("attachment must be an object")
    name, encoded = value.get("name"), value.get("data")
    if (not isinstance(name, str) or not name or len(name.encode('utf-8')) > 255
            or name in ('.', '..') or any(c in name for c in '/\\')
            or any(ord(c) < 32 or ord(c) == 127 for c in name)):
        raise ValueError("attachment needs a filename without a path or control characters")
    size = value.get("size")
    if type(size) is not int or not 0 < size <= MAX_FILE_BYTES:
        raise ValueError("file must contain between 1 byte and 5 MiB")
    if not isinstance(encoded, str) or len(encoded) > 4 * ((MAX_FILE_BYTES + 2) // 3):
        raise ValueError("file data is missing or too large")
    try:
        content = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("file data must be valid base64") from None
    if len(content) != size or hashlib.sha256(content).hexdigest() != value.get("sha256"):
        raise ValueError("file size or SHA-256 does not match the bytes")
    return content


def snapshot_file(path):
    """Read one local regular file once; reject URLs, symlinks, devices and FIFOs."""
    path = os.path.expanduser(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_FILE_BYTES:
            raise ValueError("choose a non-empty regular file of at most 5 MiB")
        content = stream.read(MAX_FILE_BYTES + 1)
    value = dict(name=os.path.basename(path), size=len(content),
                 sha256=hashlib.sha256(content).hexdigest(),
                 data=base64.b64encode(content).decode('ascii'))
    validate_attachment(value)
    return value


def attachment_description(value):
    """Only metadata goes into the popup, never binary content or base64."""
    return f"File: {value['name']}\nSize: {value['size']} bytes\nSHA-256: {value['sha256']}\nSent as a document (original bytes)."

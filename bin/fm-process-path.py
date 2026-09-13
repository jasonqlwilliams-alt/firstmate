#!/usr/bin/env python3
"""Read a process's PATH from its native environment: fm-process-path.py <pid>."""

import ctypes
import os
from pathlib import Path
import struct
import sys


CTL_KERN = 1
KERN_ARGMAX = 8
KERN_PROCARGS2 = 49


def darwin_environment(pid):
    sysctl = ctypes.CDLL(None, use_errno=True).sysctl
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
    ]
    sysctl.restype = ctypes.c_int

    def read(mib, buffer):
        size = ctypes.c_size_t(ctypes.sizeof(buffer))
        names = (ctypes.c_int * len(mib))(*mib)
        if sysctl(names, len(mib), ctypes.byref(buffer), ctypes.byref(size), None, 0):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        if size.value > ctypes.sizeof(buffer):
            raise ValueError("oversized process environment buffer")
        return size.value

    argmax = ctypes.c_int()
    if read([CTL_KERN, KERN_ARGMAX], argmax) != ctypes.sizeof(argmax):
        raise ValueError("invalid process argument limit")
    if not 0 < argmax.value <= 64 * 1024 * 1024:
        raise ValueError("invalid process argument limit")
    buffer = ctypes.create_string_buffer(argmax.value)
    size = read([CTL_KERN, KERN_PROCARGS2, pid], buffer)
    return parse_darwin_environment(buffer.raw[:size])


def parse_darwin_environment(data):
    integer_size = struct.calcsize("@i")
    if len(data) < integer_size:
        raise ValueError("missing process argument count")
    argc = struct.unpack_from("@i", data)[0]
    if not 0 < argc <= len(data) - integer_size:
        raise ValueError("invalid process argument count")

    def next_string(offset):
        end = data.find(b"\0", offset)
        if end < 0:
            raise ValueError("unterminated process entry")
        return end + 1

    offset = next_string(integer_size)
    while offset < len(data) and data[offset] == 0:
        offset += 1
    for _ in range(argc):
        offset = next_string(offset)
    entries = []
    while offset < len(data) and data[offset] != 0:
        end = next_string(offset)
        entries.append(data[offset:end - 1])
        offset = end
    return entries


def process_env(pid, name="PATH"):
    if not 0 < pid <= 2**31 - 1:
        raise ValueError("pid must be a positive native process id")
    if not name.isidentifier() or not name.isascii():
        raise ValueError("environment name must be an identifier")
    if sys.platform == "darwin":
        entries = darwin_environment(pid)
    elif sys.platform.startswith("linux"):
        entries = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    else:
        raise ValueError("native process environment is unsupported")
    prefix = name.encode() + b"="
    matches = [entry[len(prefix):] for entry in entries if entry.startswith(prefix)]
    if len(matches) != 1 or not matches[0]:
        raise ValueError(f"process environment has no unique nonempty {name}")
    return matches[0]


def process_path(pid):
    return process_env(pid, "PATH")


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: fm-process-path.py <pid> [NAME]", file=sys.stderr)
        return 2
    name = argv[2] if len(argv) == 3 else "PATH"
    try:
        value = process_env(int(argv[1]), name)
    except (OSError, ValueError) as error:
        print(f"error: cannot read process {name}: {error}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

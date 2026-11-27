"""Read the macOS kernel's process creation timestamp for the session lock."""

import ctypes
import errno
import sys


class ProcBsdInfo(ctypes.Structure):
    # struct proc_bsdinfo, from <sys/proc_info.h>.
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("ids", ctypes.c_uint32 * 10),
        ("comm", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("tty_and_nice", ctypes.c_uint32 * 6),
        ("start_seconds", ctypes.c_uint64),
        ("start_microseconds", ctypes.c_uint64),
    ]


def main():
    info = ProcBsdInfo()
    proc_pidinfo = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True).proc_pidinfo
    proc_pidinfo.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
    ]
    proc_pidinfo.restype = ctypes.c_int
    size = ctypes.sizeof(info)
    if proc_pidinfo(int(sys.argv[1]), 3, 0, ctypes.byref(info), size) != size:
        return 2 if ctypes.get_errno() == errno.ESRCH else 1
    if info.status == 5:  # SZOMB
        return 2
    if not info.start_seconds or info.start_microseconds >= 1_000_000:
        return 1
    print(f"darwin:{info.start_seconds}:{info.start_microseconds}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

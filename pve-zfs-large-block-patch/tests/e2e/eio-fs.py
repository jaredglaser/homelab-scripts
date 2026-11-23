#!/usr/bin/env python3
# FUSE filesystem with one file, ZFSPoolPlugin.pm, whose stat works and whose
# reads fail with EIO, the way a failing disk looks to grep. The container
# kernel has no device-mapper, so dm-error is not an option.
# usage: eio-fs.py <source .pm for size and mode> <mountpoint>
import errno, os, stat, sys
from fusepy import FUSE, FuseOSError, Operations

class EIO(Operations):
    def __init__(self, src):
        self.st = os.lstat(src)

    def getattr(self, path, fh=None):
        if path == "/":
            return dict(st_mode=stat.S_IFDIR | 0o755, st_nlink=2)
        if path == "/ZFSPoolPlugin.pm":
            s = self.st
            return dict(st_mode=s.st_mode, st_nlink=1, st_size=s.st_size,
                        st_mtime=s.st_mtime, st_atime=s.st_atime, st_ctime=s.st_ctime)
        raise FuseOSError(errno.ENOENT)

    def readdir(self, path, fh):
        return [".", "..", "ZFSPoolPlugin.pm"]

    def open(self, path, flags):
        return 0

    def read(self, path, size, offset, fh):
        raise FuseOSError(errno.EIO)

FUSE(EIO(sys.argv[1]), sys.argv[2], foreground=True, allow_other=True)

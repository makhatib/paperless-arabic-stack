#!/usr/bin/env python3
"""Reject path traversal and links, including nested archives, before restore.

Volume archives are extracted inside a throwaway container, where symlinks the images
themselves create (Authentik's /data/media -> /media) must survive a round trip. They
may contain symlinks, but nothing may be written through one. Archives extracted on
the host stay links-free."""
import io
from pathlib import PurePosixPath
import sys
import tarfile


CONTAINER_ARCHIVES = {'media.tar.gz', 'data.tar.gz', 'auth-data.tar.gz', 'letsencrypt.tar.gz'}


def validate(archive, allow_symlinks=False):
    members = archive.getmembers()
    links = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Unsafe archive member')
        if member.issym() and allow_symlinks:
            links.add(path)
        elif not (member.isfile() or member.isdir()):
            raise ValueError('Unsafe archive member')
    for member in members:
        path = PurePosixPath(member.name)
        if any(parent in links for parent in path.parents):
            raise ValueError('Archive member written through a symlink')
    return members


def unpack(source, destination):
    with tarfile.open(source, 'r:gz') as archive:
        members = validate(archive)
        names = {m.name.removeprefix('./') for m in members}
        if not {'db.sql.gz', 'media.tar.gz', 'data.tar.gz', 'files.tar.gz', 'MANIFEST'} <= names:
            raise ValueError('Backup is incomplete')
        for member in members:
            if member.isfile() and member.name.endswith('.tar.gz'):
                with tarfile.open(fileobj=archive.extractfile(member), mode='r:gz') as nested:
                    validate(nested, allow_symlinks=member.name.removeprefix('./') in CONTAINER_ARCHIVES)
        # Every member (including nested members) has been checked above.
        archive.extractall(destination, members=members)


if __name__ == '__main__':
    try:
        unpack(sys.argv[1], sys.argv[2])
    except (ValueError, OSError, tarfile.TarError):
        print('Backup rejected: incomplete, damaged or unsafe archive. Nothing was changed.', file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Offline Gitloom snapshots. Run from the Gitloom installation directory."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import zipfile


def config(overrides):
    values = {}
    for item in overrides:
        key, sep, value = item.partition('=')
        if not sep:
            raise ValueError('-D requires KEY=VALUE')
        values[key] = value
    for filename in ('gitloom.local.cfg', 'gitloom.cfg'):
        path = Path(filename)
        if path.exists():
            for line in path.read_text(encoding='utf-8-sig').splitlines():
                key, sep, value = line.strip().partition('=')
                if sep and not key.startswith(('#', ';')):
                    values.setdefault(key.strip(), value.strip())
    return values


def paths(cfg):
    return {key: Path(cfg.get(option, default)).resolve() for key, option, default in (
        ('repos', 'REPO_ROOT', 'repos'), ('data', 'DATA_DIR', 'data'),
        ('users', 'USERS_FILE', 'data/users.json'))}


def offline(cfg):
    host = cfg.get('LISTEN_HOST', '0.0.0.0')
    if host in ('0.0.0.0', ''):
        host = '127.0.0.1'
    elif host == '::':
        host = '::1'
    try:
        with socket.create_connection((host, int(cfg.get('LISTEN_PORT', '8686'))), timeout=5):
            raise ValueError('listener is active; stop Gitloom and all Git workers first')
    except ConnectionRefusedError:
        pass


def backend(cfg):
    driver = cfg.get('DB_DRIVER', 'none').lower()
    if driver not in ('', 'none', 'mysql'):
        raise ValueError('unsupported DB_DRIVER')
    return 'mysql' if driver == 'mysql' else 'json'


def mysql(cfg, executable, options, **streams):
    name = cfg.get('DB_NAME', 'gitloom')
    argv = [executable, '--host=' + cfg.get('DB_HOST', '127.0.0.1'),
            '--port=' + cfg.get('DB_PORT', '3306'), '--user=' + cfg.get('DB_USER', ''),
            *options, name]
    env = dict(os.environ)
    env['MYSQL_PWD'] = cfg.get('DB_PASSWORD', '')
    result = subprocess.run(argv, env=env, stderr=subprocess.PIPE,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
                            **streams)
    if result.returncode:
        raise ValueError('MySQL command failed; check client availability, credentials and database permissions')
    return result.stdout


def files(root):
    if not root.is_dir():
        raise ValueError('snapshot source directory does not exist: ' + str(root))
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = Path(directory, name)
            attributes = getattr(path.lstat(), 'st_file_attributes', 0)
            if path.is_symlink() or attributes & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0):
                raise ValueError('linked snapshot paths are not supported: ' + str(path))
        for name in sorted(names):
            path = Path(directory, name)
            if not path.is_file():
                raise ValueError('snapshot contains a non-regular file')
            if path.as_posix().endswith('/objects/info/alternates') and path.stat().st_size:
                raise ValueError('repositories with external object alternates must be made self-contained first')
            yield path, path.relative_to(root).as_posix()


def add_file(archive, source, name, manifest):
    digest = hashlib.sha256()
    size = 0
    info = zipfile.ZipInfo(name)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | stat.S_IMODE(source.stat().st_mode)) << 16
    with source.open('rb') as reader, archive.open(info, 'w', force_zip64=True) as writer:
        for chunk in iter(lambda: reader.read(1024 * 1024), b''):
            writer.write(chunk)
            digest.update(chunk)
            size += len(chunk)
    manifest[name] = {'size': size, 'sha256': digest.hexdigest()}


def backup(args, cfg, source):
    destination = Path(args.archive).resolve()
    if any(destination.is_relative_to(source[key]) for key in ('repos', 'data')):
        raise ValueError('write the archive outside the repository and data directories')
    driver = backend(cfg)
    if source['users'].is_symlink():
        raise ValueError('linked account files are not supported')
    if driver == 'json' and not source['users'].is_file():
        raise ValueError('account file does not exist; check USERS_FILE')
    with tempfile.TemporaryDirectory(prefix='gitloom-backup-') as scratch:
        dump = Path(scratch, 'database.sql')
        if driver == 'mysql':
            with dump.open('wb') as output:
                mysql(cfg, args.mysqldump, ['--single-transaction', '--hex-blob',
                      '--no-tablespaces', '--skip-add-drop-table'],
                      stdout=output)
        created = False
        try:
            fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created = True
            with os.fdopen(fd, 'wb') as output:
                with zipfile.ZipFile(output, 'w', allowZip64=True) as archive:
                    manifest = {}
                    directories = []
                    for key in ('repos', 'data'):
                        for path, relative in files(source[key]):
                            add_file(archive, path, key + '/' + relative, manifest)
                        directories.extend(key if Path(directory) == source[key] else
                                           key + '/' + Path(directory).relative_to(source[key]).as_posix()
                                           for directory, _, _ in os.walk(source[key]))
                    if driver == 'json':
                        add_file(archive, source['users'], 'accounts.json', manifest)
                    else:
                        add_file(archive, dump, 'database.sql', manifest)
                    archive.writestr('manifest.json', json.dumps({
                        'format': 'gitloom-backup', 'version': 1, 'backend': driver,
                        'created_at': datetime.now(timezone.utc).isoformat(),
                        'files': manifest, 'directories': sorted(directories)}, sort_keys=True))
                output.flush()
                os.fsync(output.fileno())
        except BaseException:
            if created:
                destination.unlink(missing_ok=True)
            raise
    print('Backup created: ' + str(destination))


def safe_name(name, directory=False):
    path = PurePosixPath(name)
    reserved = {'CON', 'PRN', 'AUX', 'NUL', *('COM' + str(i) for i in range(1, 10)),
                *('LPT' + str(i) for i in range(1, 10))}
    if (not name or path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name
            or path.as_posix() != name or name.endswith('/')
            or any(part.endswith((' ', '.')) or part.split('.')[0].upper() in reserved for part in path.parts)
            or (name not in ('accounts.json', 'database.sql') and
                (path.parts[0] not in ('repos', 'data') or (len(path.parts) < 2 and not directory)))):
        raise ValueError('unsafe snapshot entry')


def validate(archive, driver):
    names = archive.namelist()
    if len(set(name.casefold() for name in names)) != len(names):
        raise ValueError('duplicate archive entries')
    manifest = json.loads(archive.read('manifest.json'))
    if (not isinstance(manifest, dict) or manifest.get('format') != 'gitloom-backup' or manifest.get('version') != 1
            or manifest.get('backend') != driver):
        raise ValueError('unsupported snapshot format or database backend mismatch')
    entries = manifest['files']
    if not isinstance(entries, dict) or set(names) != set(entries) | {'manifest.json'}:
        raise ValueError('snapshot manifest does not match archive contents')
    required = 'accounts.json' if driver == 'json' else 'database.sql'
    if required not in entries or (driver == 'json' and 'repos/index.json' not in entries):
        raise ValueError('snapshot is missing account or repository metadata')
    directories = manifest.get('directories')
    if (not isinstance(directories, list) or not all(isinstance(name, str) for name in directories)
            or not {'repos', 'data'}.issubset(directories)
            or len(set(name.casefold() for name in directories)) != len(directories)):
        raise ValueError('invalid snapshot directory manifest')
    for name in directories:
        safe_name(name, directory=True)
        if name.split('/')[0] not in ('repos', 'data'):
            raise ValueError('unsafe snapshot directory')
    directory_names = {name.casefold() for name in directories}
    if directory_names.intersection(name.casefold() for name in entries):
        raise ValueError('snapshot file/directory collision')
    for name, expected in entries.items():
        safe_name(name)
        if name.startswith(('repos/', 'data/')) and str(PurePosixPath(name).parent) not in directories:
            raise ValueError('snapshot file has no parent directory')
        info = archive.getinfo(name)
        mode = info.external_attr >> 16
        if stat.S_IFMT(mode) not in (0, stat.S_IFREG):
            raise ValueError('snapshot contains a non-regular entry')
        digest = hashlib.sha256()
        size = 0
        with archive.open(name) as reader:
            for chunk in iter(lambda: reader.read(1024 * 1024), b''):
                digest.update(chunk)
                size += len(chunk)
        if size != expected['size'] or digest.hexdigest() != expected['sha256']:
            raise ValueError('snapshot checksum mismatch: ' + name)
    return entries, directories


def restore(args, cfg, target):
    driver = backend(cfg)
    if target['repos'] == target['data'] or any(
            target[a].is_relative_to(target[b]) for a, b in (('repos', 'data'), ('data', 'repos'))):
        raise ValueError('repository and data destinations must be separate directories')
    for key in ('repos', 'data'):
        path = target[key]
        if path.exists() and (not path.is_dir() or any(path.iterdir())):
            raise ValueError('restore requires empty destination directories: ' + str(path))
    if target['users'].exists():
        raise ValueError('restore will not overwrite an existing account file')
    with zipfile.ZipFile(args.archive) as archive:
        entries, directories = validate(archive, driver)
        if driver == 'json':
            for key in ('repos', 'data'):
                if target['users'].is_relative_to(target[key]):
                    name = key + '/' + target['users'].relative_to(target[key]).as_posix()
                    if name in entries and entries[name] != entries['accounts.json']:
                        raise ValueError('account file conflicts with the data snapshot')
        if driver == 'mysql':
            count = mysql(cfg, args.mysql, ['--batch', '--skip-column-names',
                          '--execute=SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()'],
                          stdout=subprocess.PIPE)
            if count.strip() != b'0':
                raise ValueError('MySQL restore requires an existing empty database')
        # Validate every byte before publishing files or touching the database.
        with tempfile.TemporaryDirectory(prefix='gitloom-restore-') as scratch:
            stage = Path(scratch)
            for name in directories:
                (stage / name).mkdir(parents=True, exist_ok=True, mode=0o700)
            for name in entries:
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as reader, path.open('xb') as writer:
                    shutil.copyfileobj(reader, writer, 1024 * 1024)
                os.chmod(path, stat.S_IMODE(archive.getinfo(name).external_attr >> 16) or 0o600)
            if driver == 'mysql':
                with (stage / 'database.sql').open('rb') as sql:
                    mysql(cfg, args.mysql, [], stdin=sql, stdout=subprocess.DEVNULL)
            for key in ('repos', 'data'):
                target[key].mkdir(parents=True, exist_ok=True, mode=0o700)
                for name in directories:
                    parts = PurePosixPath(name).parts
                    if parts[0] == key:
                        target[key].joinpath(*parts[1:]).mkdir(parents=True, exist_ok=True, mode=0o700)
                for path, relative in files(stage / key) if (stage / key).exists() else []:
                    destination = target[key] / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with path.open('rb') as reader, destination.open('xb') as writer:
                        shutil.copyfileobj(reader, writer, 1024 * 1024)
                    shutil.copymode(path, destination)
            if driver == 'json':
                account = stage / 'accounts.json'
                if target['users'].exists():
                    if target['users'].read_bytes() != account.read_bytes():
                        raise ValueError('account file conflicts with the data snapshot')
                    os.chmod(target['users'], 0o600)
                else:
                    target['users'].parent.mkdir(parents=True, exist_ok=True)
                    with target['users'].open('xb') as writer, account.open('rb') as reader:
                        shutil.copyfileobj(reader, writer)
                    os.chmod(target['users'], 0o600)
    print('Restore complete. Keep Gitloom stopped until repository checks and configuration review finish.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('backup', 'restore'))
    parser.add_argument('archive')
    parser.add_argument('--offline', required=True, action='store_true',
                        help='confirm Gitloom, its workers and automatic restarts are stopped')
    parser.add_argument('-D', action='append', default=[], metavar='KEY=VALUE')
    parser.add_argument('--mysql', default='mysql')
    parser.add_argument('--mysqldump', default='mysqldump')
    args = parser.parse_args()
    cfg = config(args.D)
    offline(cfg)
    (backup if args.command == 'backup' else restore)(args, cfg, paths(cfg))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, zipfile.BadZipFile) as error:
        print('Backup/restore failed: ' + str(error), file=sys.stderr)
        sys.exit(1)

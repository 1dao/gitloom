# Running gitloom for real

`start.sh` runs in the foreground, which is right for trying it out and wrong
for keeping it. This directory has what turns it into something that survives a
closed terminal and a reboot, plus the two operational things nothing else in
the repository covers: what to back up, and what stops the logs growing forever.

## Install (systemd)

```bash
sudo useradd -r -s /sbin/nologin gitloom
sudo mkdir -p /opt/gitloom
sudo cp -r . /opt/gitloom/                    # from a checkout
sudo mkdir -p /opt/gitloom/{repos,data,tmp,logs}
sudo chown -R gitloom:gitloom /opt/gitloom
```

`bin/` is **not** in the repository — copy the runtime from xnet2lua first, as
`../xpauth` does. `bin/xnet` for Linux; `bin/xnet.exe` beside it is harmless.

```bash
sudo install -m 0644 deploy/gitloom.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gitloom
systemctl status gitloom
journalctl -u gitloom -f
```

Set `ADMIN_USER` / `ADMIN_PASSWORD` in `gitloom.local.cfg` before the first
start — that is the only moment the administrator account is created. **The
first boot prints a recovery code; take it out of the log and keep it somewhere
else.** See the README's "If you forget the password": once an account exists,
changing `ADMIN_PASSWORD` does nothing, and that code is the only way back in.

With `DB_DRIVER=mysql`, create the database first. gitloom migrates its tables
on every boot but never creates the database itself — the driver names it in the
handshake, and a pooled `USE` would only move whichever connection ran it.

## Backups

`repos/` **is the data.** Everything else can be rebuilt; the bare repositories
cannot. What to keep:

| | JSON backend (default) | `DB_DRIVER=mysql` |
|---|---|---|
| repositories | `repos/` | `repos/` |
| accounts | `data/users.json` | the database |
| issues | `data/issues.json` | the database |
| repository index | `repos/index.json` | the database |
| secrets | `gitloom.local.cfg` | `gitloom.local.cfg` |

`tmp/` and `logs/` are not data. Do not restore them.

### Copying repos/ while the service runs is not safe

git writes objects and packfiles to temporary names and renames them, and moves
refs under lockfiles. A `cp -r` or `rsync` that runs during a push can capture a
ref that already points at an object the copy has not reached, and the restored
repository is then quietly broken — `git fsck` finds it, a clone may not.

Pick one that actually gives a consistent view:

**Stop, copy, start** — simplest, and a personal instance can afford the seconds.

```bash
sudo systemctl stop gitloom
sudo tar czf /backup/gitloom-$(date +%F).tar.gz \
    -C /opt/gitloom repos data gitloom.local.cfg
sudo systemctl start gitloom
```

**Let git do it** — no downtime, and the result is a repository rather than a
directory of files. git takes its own consistent view of each one.

```bash
for d in /opt/gitloom/repos/*/*.git; do
    git clone --mirror "$d" "/backup/mirrors/$(basename "$(dirname "$d")")-$(basename "$d")"
done
```

**A filesystem snapshot** (LVM, ZFS, btrfs) is atomic and needs no downtime, if
you already have one.

With MySQL, add the database and take it at the same time as `repos/`:

```bash
mysqldump --single-transaction gitloom > /backup/gitloom-$(date +%F).sql
```

### Restoring

Put the files back, make sure `gitloom` owns them, and start. Nothing else is
needed: the schema migrates itself, and `repos/index.json` (or the database)
already names every repository.

## Logs

The runtime rolls its log file by size and **never deletes the old ones** — it
moves on to `xnet_main_002.log` and keeps going. Left alone, that fills the disk
eventually. Two knobs:

```
# gitloom.cfg -- size of one file before it rolls
LOG_MAX_FILE_MB=32
# higher is quieter
LOG_LEVEL=3
```

and something to delete what has rolled away:

```
# /etc/logrotate.d/gitloom
/opt/gitloom/logs/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
```

`copytruncate` on purpose: the runtime holds its file open and does not reopen
on a signal, so renaming it out from under the process leaves it writing to a
file nobody can find.

Note that the **recovery code printed at first boot is in these files**. That is
one more reason to take it out and to keep `logs/` off any backup that travels.

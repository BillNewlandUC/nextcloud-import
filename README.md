# OneDrive → Nextcloud, several people at once

Files are written onto the host disk and Nextcloud is told to index
them. The alternative — uploading through WebDAV or the web UI — puts
everything through PHP, and on any real volume that is hours slower
and runs into upload limits and timeouts.

## Order

```bash
sudo ./nc-import.sh check                # before anything moves
./nc-import.sh paste od-bill bill@...    # once per person
sudo ./nc-import.sh bg fetch bill        # download to staging, detached
sudo ./nc-import.sh install bill         # move into Nextcloud and index
sudo ./nc-import.sh verify bill          # compare source against result
sudo ./nc-import.sh shared               # the Team folder, if you have one
```

`fetch`, `install` and `verify` take a Nextcloud user name, or
`--all`. Only `auth` and `paste` take the rclone remote name
(`od-bill`) — mixing the two up is the single easiest mistake to
make, and the script now refuses rather than doing nothing quietly.

**Run it with `sudo`.** `install` writes into Nextcloud's data
directory and chowns to uid 33; `check` creates the staging
directory. The rclone configs live in this directory rather than your
home, so `sudo` does not lose them.

**Do one person at a time.** Staging then holds one account rather
than four, and `install` frees it before the next `fetch` begins —
peak disk is the largest single account, not the sum. It also means
the first run is a rehearsal on data you can redo without asking
anyone to re-authorise.

`fetch` and `install` are separate on purpose: a scan that runs while
files are still arriving indexes half-written ones. Do not install
until the fetch has printed its summary.

### Surviving a dropped connection

A fetch runs for hours and rclone dies with its terminal, so an SSH
drop or a closed laptop lid kills it mid-transfer. Prefix any
subcommand with `bg`:

```bash
sudo ./nc-import.sh bg fetch hilary
```

It prints a pid and a log path and returns immediately. `setsid`
gives the run its own session, so the hangup never reaches it.

```bash
tail -f nc-import-fetch-*.log     # watch
pgrep -a rclone                   # confirm it is alive
```

Authenticate first with `sudo -v`, or the password prompt appears
inside the detached process where you cannot answer it.

`tmux` is the better choice when you want to watch live progress and
interact; `bg` is for fire-and-forget.

### Knowing a fetch finished

A completed run ends with a summary block — `Transferred:`,
`Errors:`, `Elapsed time:`. A log whose last line is a file being
copied means the run was interrupted, however healthy it looks.

```bash
tail -5 rclone-bill.log
```

Re-running `fetch` resumes: it skips what is already present. To see
exactly what is still missing:

```bash
rclone --config rclone-configs/od-bill.conf check \
  od-bill: /mnt/data-2/cloud/bill/files \
  --exclude-from excludes.txt --one-way --missing-on-dst /tmp/missing.txt
```

`--one-way` reports only what OneDrive has and the destination does
not, so Nextcloud's own files produce no noise.

## Settings

```bash
cp config.env.example config.env
```

Nothing in the script needs editing. Resolution order, highest first:

1. environment variables on the command line
2. `config.env`
3. the Nextcloud stack's own `.env`, via `NC_STACK_DIR`
4. built-in defaults

Point `NC_STACK_DIR` at the Nextcloud stack and `NC_DATA` comes from
there — one source of truth for that path instead of two files that
can quietly disagree. The container name is derived from the running
stack too (`docker compose ps -q app`) rather than guessed.

`./nc-import.sh check` prints what every value resolved to, so you can
see it without reading the script.

| Variable | Default | Notes |
|---|---|---|
| `NC_STACK_DIR` | unset | Path to the Nextcloud stack; supplies `NC_DATA` and the container |
| `NC_CONTAINER` | derived | The container `occ` runs in |
| `NC_DATA` | `/srv/nextcloud/data` | Host path of Nextcloud's data dir |
| `STAGING` | `/srv/nextcloud/import-staging` | **Same filesystem as `NC_DATA`, and not inside it** |
| `IMPORT_SUBDIR` | empty | Empty puts the import at the root of the user's files; a name keeps it in that folder |
| `NC_UID`/`NC_GID` | `33` | `www-data` in the official image |
| `RCLONE_FLAGS` | see `config.env.example` | Throttling and parallelism |
| `OD_CLIENT_ID`/`_SECRET` | unset | Your own Azure app registration |

`check` refuses to continue if staging is on a different filesystem
from the data directory. `install` uses `mv`, which on one filesystem
is instant and needs no extra space; across two it becomes a full
copy — twice the disk and hours longer.

It also refuses a staging path *inside* `NC_DATA`. Half-downloaded
files would otherwise sit in Nextcloud's data directory for the
duration of the fetch. Put it alongside:

```
NC_DATA=/mnt/data-2/cloud
STAGING=/mnt/data-2/import-staging
```

### Where the files land

With `IMPORT_SUBDIR` empty — the default — each person's OneDrive
goes to the root of their Nextcloud files, so it looks like their
OneDrive did. Nextcloud creates skeleton files at first login
(`Documents/`, `Photos/`, `Readme.md`), so `install` moves entry by
entry and refuses to overwrite anything already there, naming what it
left behind in staging. Usually you want the OneDrive version:
delete the Nextcloud one and rerun.

Set `IMPORT_SUBDIR=OneDrive` to keep the import in its own folder
instead, which cannot collide with anything.

### Excluding paths

Patterns go one per line in `excludes.txt` beside the script, not in
`RCLONE_FLAGS`. That variable is word-split when expanded, so a
pattern containing a space arrives at rclone in pieces — rclone then
rejects the arguments before it opens its log file, which looks
exactly like nothing happening at all. Every flag and value in
`RCLONE_FLAGS` must be a single whitespace-separated word.

## Authorisation, and why there is no central token

Personal Microsoft accounts have no tenant, so there is no admin
consent and no service-principal flow. Every token for someone's
personal OneDrive comes from that person signing in once. An API
token you create centrally cannot reach another person's files.

(On a Microsoft 365 tenant it would be different: an app registration
with the `Files.Read.All` application permission plus admin consent
reads every user's OneDrive with no interaction.)

Two ways to handle it, both one interaction per person:

**They generate the token, you paste it.** Nothing of theirs touches
this machine, and you never see their password:

```bash
# they run this on their own laptop
rclone authorize "onedrive"

# you paste what it prints
./nc-import.sh paste od-hilary hilary@example.com
```

**Or configure it here** with `./nc-import.sh auth od-hilary` — but
only if this machine has a browser. On a headless server the OAuth
callback to `localhost:53682` has nothing listening for it, so `auth`
hangs and then fails. It warns you before doing that.

**Or forward the callback port**, which needs nothing installed on
the other machine — just SSH and a browser. Windows has an OpenSSH
client built in:

```bash
ssh -L 53682:localhost:53682 media@home-server
```

Run `auth` *inside that session*, answer `y` to the no-browser
warning, and open the printed URL in the browser on your own machine.
The redirect comes back down the tunnel. One person at a time: the
port can only be bound once. Use a private browser window for each,
so you are not silently reusing the previous Microsoft session.

### drive_id

`rclone authorize` returns a bare token, while rclone's OneDrive
backend also needs `drive_id` — something only the interactive
`rclone config` flow normally asks for. `paste` looks it up from
Microsoft Graph with the access token and writes it in. Without it,
every operation fails with *unable to get drive_id and drive_type*.

To repair a config written before this existed:

```bash
./nc-import.sh drive od-bill
```

Access tokens last an hour, so if that reports a failed Graph request
the token has simply expired and needs a fresh `rclone authorize`.

rclone itself *is* needed on the server, for the transfers. A browser
is not, and those are separate requirements.

Either way the refresh token then renews itself indefinitely — it is
genuinely once per person, not a recurring chore.

### Use your own Azure app registration

Optional, and worth the ten minutes. rclone's built-in client ID is
rate-limited across every rclone user in the world, which is a common
cause of slow OneDrive transfers. Register an app (personal accounts
supported, redirect URI `http://localhost:53682/`), then:

```bash
export OD_CLIENT_ID=...
export OD_CLIENT_SECRET=...
```

It does not remove the per-person sign-in — nothing does, for
personal accounts — but the transfers get materially faster.

## Things that will bite

**OneNote notebooks cannot be downloaded** through the OneDrive API.
rclone skips them and says so in the log. Export those by hand from
OneNote if they matter.

**Filenames.** OneDrive allows names Linux or Nextcloud will reject —
trailing spaces, very long path components, some Unicode. Every skip
is in `rclone-<user>.log`; read it rather than assuming a clean run:

```bash
grep -i 'error\|skip\|failed' rclone-bill.log
```

**Personal Vault cannot be read at all.** Its contents are
BitLocker-protected and invisible to the Graph API whether the vault
is locked or not. `excludes.txt` skips it by default; rclone would
otherwise log an error on every listing pass. Anything in there has
to be moved across by hand through the OneDrive web UI — worth
checking whether a camera roll ended up in there before concluding
photos are missing.

**Create the Nextcloud users first, and log in as each once.**
`install` needs `data/<user>/files`, and Nextcloud creates that at
first login rather than at `user:add`.

**Ownership.** Anything written into the data directory must be owned
by uid 33. Wrong ownership makes a scan appear to work and the files
show as unreadable.

## After importing

Previews are generated on demand, so first browse through a large
photo library is slow. The Preview Generator app fixes that:

```bash
docker compose -f ../nextcloud-stack/docker-compose.yml \
  exec -u www-data app php occ app:install previewgenerator
docker compose -f ../nextcloud-stack/docker-compose.yml \
  exec -u www-data app php occ preview:generate-all
```

Run it overnight — it is CPU-heavy.

If Recognize is enabled for face detection, leave its backlog pass
until every account is in. Classifying while files are still arriving
means doing the work twice and competing for the same CPU.

## Leave OneDrive in place for a while

`verify` compares the source against what landed, one-way, so extra
local files are fine and missing ones are reported. Keep the OneDrive
accounts until you have browsed the result properly and taken one
backup of the Nextcloud data. Deleting the only other copy on the
strength of a script's exit code is not a good trade.

## Keeping this in git

Uploading files through the GitHub web UI stores everything mode
`100644`, so **executable bits do not survive**. After cloning or
updating from the repo:

```bash
chmod +x *.sh
find . -name '*.sh' -exec chmod +x {} +
```

On this project that matters most for the hook scripts and the
helper scripts — a hook without the executable bit is silently
skipped, which is easy to spend an afternoon on.

What is deliberately not tracked is listed in `.gitignore`, with the
reason on each entry. Check it before adding a file that holds a
password, a token or a key.

# OneDrive → Nextcloud, several people at once

Files are written onto the host disk and Nextcloud is told to index
them. The alternative — uploading through WebDAV or the web UI — puts
everything through PHP, and on any real volume that is hours slower
and runs into upload limits and timeouts.

## Order

```bash
./nc-import.sh check                  # before anything moves
./nc-import.sh auth od-bill           # once per person
./nc-import.sh fetch                  # download everyone to staging
./nc-import.sh install                # move into Nextcloud and index
./nc-import.sh verify                 # compare source against result
./nc-import.sh shared                 # the Team folder, if you have one
```

`fetch` and `install` are separate on purpose: a scan that runs while
files are still arriving indexes half-written ones.

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
| `STAGING` | `/srv/nextcloud/import-staging` | **Must be the same filesystem as `NC_DATA`** |
| `NC_UID`/`NC_GID` | `33` | `www-data` in the official image |
| `RCLONE_FLAGS` | see `config.env.example` | Throttling and parallelism |
| `OD_CLIENT_ID`/`_SECRET` | unset | Your own Azure app registration |

`check` refuses to continue if staging is on a different filesystem
from the data directory. `install` uses `mv`, which on one filesystem
is instant and needs no extra space; across two it becomes a full
copy — twice the disk and hours longer.

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

**Create the Nextcloud users first.** `install` skips anyone with no
`data/<user>/files` directory, rather than inventing one.

**Ownership.** Anything written into the data directory must be owned
by uid 33. Wrong ownership makes a scan appear to work and the files
show as unreadable.

## After importing

Previews are generated on demand, so first browse through a large
photo library is slow. The Preview Generator app fixes that:

```bash
docker exec -u www-data nextcloud php occ app:install previewgenerator
docker exec -u www-data nextcloud php occ preview:generate-all
```

Run it overnight — it is CPU-heavy.

## Leave OneDrive in place for a while

`verify` compares the source against what landed, one-way, so extra
local files are fine and missing ones are reported. Keep the OneDrive
accounts until you have browsed the result properly and taken one
backup of the Nextcloud data. Deleting the only other copy on the
strength of a script's exit code is not a good trade.

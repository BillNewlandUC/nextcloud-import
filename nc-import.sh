#!/usr/bin/env bash
# Import OneDrive into Nextcloud, for several people.
#
#   ./nc-import.sh check              validate the setup before moving data
#   ./nc-import.sh auth <remote>      configure one person's OneDrive here
#   ./nc-import.sh paste <remote> <who>  ...or from a token they generated
#   ./nc-import.sh fetch [user|--all] download to staging
#   ./nc-import.sh install [user|--all]  move into Nextcloud and index
#   ./nc-import.sh verify [user|--all]   compare source against result
#   ./nc-import.sh shared             fetch + install the group folder
#
# Files land on disk directly and Nextcloud is told to index them,
# rather than being uploaded through WebDAV. On any real volume that
# is hours faster and sidesteps PHP upload limits entirely.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- settings -------------------------------------------------------
NC_CONTAINER="${NC_CONTAINER:-nextcloud}"
# Host path of Nextcloud's data directory.
NC_DATA="${NC_DATA:-/srv/nextcloud/data}"
# Staging MUST be on the same filesystem as NC_DATA: install uses mv,
# which is then instant and needs no extra space. Across filesystems
# it becomes a full copy — twice the disk, hours longer.
STAGING="${STAGING:-/srv/nextcloud/import-staging}"
# www-data inside the official image.
NC_UID="${NC_UID:-33}"
NC_GID="${NC_GID:-33}"
# Microsoft throttles hard; unthrottled runs stall.
RCLONE_FLAGS="${RCLONE_FLAGS:---transfers 4 --checkers 8 --tpslimit 10}"
# Your own Azure app registration. Optional but worth it: rclone's
# built-in client ID is rate-limited across every rclone user
# everywhere, which is a common cause of slow OneDrive transfers.
# Personal accounts still require each person to sign in once — there
# is no tenant, so no admin consent and no service-principal path.
OD_CLIENT_ID="${OD_CLIENT_ID:-}"
OD_CLIENT_SECRET="${OD_CLIENT_SECRET:-}"

CONFDIR="$DIR/rclone-configs"
USERS="$DIR/users.conf"
SHARED="$DIR/shared.conf"

trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
occ() { docker exec -u www-data "$NC_CONTAINER" php occ "$@"; }

rc() {  # rclone with the right person's config
    local remote="$1"; shift
    rclone --config "$CONFDIR/$remote.conf" "$@"
}

each_user() {  # each_user <callback> [filter]
    local cb="$1" want="${2:---all}"
    while IFS='|' read -r u r n <&3; do
        u="$(trim "${u:-}")"; r="$(trim "${r:-}")"; n="$(trim "${n:-$u}")"
        [[ -z "$u" || "$u" == \#* ]] && continue
        [[ "$want" == "--all" || "$want" == "$u" ]] || continue
        "$cb" "$u" "$r" "$n"
    done 3< "$USERS"
}

# ---- check ----------------------------------------------------------
cmd_check() {
    local fail=0

    command -v rclone >/dev/null || { echo "MISSING: rclone not installed" >&2; fail=1; }

    docker inspect "$NC_CONTAINER" >/dev/null 2>&1 \
        || { echo "MISSING: container '$NC_CONTAINER' not found" >&2; fail=1; }

    [[ -d "$NC_DATA" ]] || { echo "MISSING: NC_DATA '$NC_DATA' is not a directory" >&2; fail=1; }

    mkdir -p "$STAGING"
    if [[ -d "$NC_DATA" ]]; then
        local a b
        a="$(stat -c %d "$NC_DATA")"
        b="$(stat -c %d "$STAGING")"
        if [[ "$a" != "$b" ]]; then
            echo "WARNING: $STAGING and $NC_DATA are on different filesystems." >&2
            echo "         install will copy rather than move: double the disk," >&2
            echo "         and far slower. Set STAGING somewhere under the same" >&2
            echo "         mount as NC_DATA." >&2
            fail=1
        fi
    fi

    echo
    echo "Per-person rclone configs:"
    each_user _check_user

    if grep -qv '^[[:space:]]*\(#.*\)\?$' "$SHARED" 2>/dev/null; then
        echo
        if occ app:list 2>/dev/null | grep -q groupfolders; then
            echo "  groupfolders app: enabled"
        else
            echo "  groupfolders app: NOT enabled — occ app:install groupfolders" >&2
            fail=1
        fi
    fi

    echo
    [[ "$fail" -eq 0 ]] && echo "Ready." || echo "Fix the above before importing." >&2
    return "$fail"
}

_check_user() {
    local u="$1" r="$2"
    if [[ -f "$CONFDIR/$r.conf" ]]; then
        printf '  %-10s %-12s configured' "$u" "$r"
        if [[ -d "$NC_DATA/$u" ]]; then echo; else echo "  (no Nextcloud user '$u' yet)"; fi
    else
        printf '  %-10s %-12s NOT configured — ./nc-import.sh auth %s\n' "$u" "$r" "$r"
    fi
}

# ---- auth -----------------------------------------------------------
# Write a config from a token blob the person generated themselves,
# so they never touch this machine and you never see their password.
cmd_paste() {
    local remote="${1:?usage: $0 paste <remote> <upn-or-email>}"
    local who="${2:-unknown}"
    mkdir -p "$CONFDIR"
    local target="$CONFDIR/$remote.conf"
    [[ -e "$target" ]] && { echo "error: $target exists already" >&2; exit 1; }

    cat <<NOTE

Ask $who to run this on a machine with a browser:

  rclone authorize "onedrive"${OD_CLIENT_ID:+ \"$OD_CLIENT_ID\" \"$OD_CLIENT_SECRET\"}

They sign in, and it prints a line beginning with:

  {"access_token":"...

Paste that whole single line below, then press enter.

NOTE
    read -rp "token: " token
    [[ "$token" == \{* ]] || { echo "error: that does not look like a token blob" >&2; exit 1; }

    {
        echo "[$remote]"
        echo "type = onedrive"
        echo "drive_type = personal"
        [[ -n "$OD_CLIENT_ID" ]]     && echo "client_id = $OD_CLIENT_ID"
        [[ -n "$OD_CLIENT_SECRET" ]] && echo "client_secret = $OD_CLIENT_SECRET"
        echo "token = $token"
    } > "$target"
    chmod 600 "$target"

    echo
    echo "Wrote $target — checking it works:"
    rc "$remote" about "$remote:" \
        || echo "!! rclone could not use it; the token may be incomplete" >&2
}

cmd_auth() {
    local remote="${1:?usage: $0 auth <remote>}"
    mkdir -p "$CONFDIR"

    # On a headless box the OAuth callback to localhost:53682 has
    # nothing listening for it, so this hangs and then fails. Say so
    # rather than letting someone discover it the slow way.
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        cat >&2 <<WARN

This machine appears to have no browser. 'auth' needs one for the
OAuth callback, so it will hang.

Use 'paste' instead:

  1. On a machine with a browser:
       rclone authorize "onedrive"
  2. Here:
       $0 paste $remote <their-address>

Or forward the callback port from a machine with a browser and rerun:

       ssh -L 53682:localhost:53682 $(whoami)@$(hostname)

WARN
        read -rp "Continue with 'auth' anyway? [y/N] " go
        [[ "$go" == [yY] ]] || exit 1
    fi

    cat <<NOTE

Configuring '$remote' in its own config file, so each person's
OneDrive stays separate:

  $CONFDIR/$remote.conf

Answer: n (new remote), name '$remote', storage 'onedrive', leave
client_id and client_secret blank, choose OneDrive Personal, and let
it open a browser. Each person needs to sign in themselves — you
cannot do this on their behalf without their password.

Headless box? Run this on a machine with a browser:

  rclone authorize "onedrive"

then paste the result when this asks for it.

NOTE
    read -rp "Press enter to start rclone config... " _
    rclone --config "$CONFDIR/$remote.conf" config
}

# ---- fetch ----------------------------------------------------------
_fetch_user() {
    local u="$1" r="$2"
    [[ -f "$CONFDIR/$r.conf" ]] || { echo "skip $u: '$r' not configured" >&2; return 0; }

    local dest="$STAGING/$u"
    mkdir -p "$dest"
    echo "==> $u from $r:"
    rc "$r" size "$r:" || true
    # copy is resumable: re-running skips what is already present.
    rc "$r" copy "$r:" "$dest" $RCLONE_FLAGS \
        --progress \
        --log-file "$DIR/rclone-$u.log" --log-level INFO \
        || { echo "!! $u failed — rerun to resume; see rclone-$u.log" >&2; return 1; }
    echo "    staged at $dest"
}

cmd_fetch() { each_user _fetch_user "${1:---all}"; }

# ---- install --------------------------------------------------------
_install_user() {
    local u="$1"
    local src="$STAGING/$u"
    local dst="$NC_DATA/$u/files/OneDrive"

    [[ -d "$src" ]] || { echo "skip $u: nothing staged" >&2; return 0; }
    [[ -d "$NC_DATA/$u/files" ]] || {
        echo "skip $u: no Nextcloud user '$u' — create them first" >&2; return 0; }
    [[ -e "$dst" ]] && { echo "skip $u: $dst already exists" >&2; return 0; }

    mv "$src" "$dst"
    chown -R "$NC_UID:$NC_GID" "$dst"
    echo "==> $u: indexing $dst"
    occ files:scan --path="$u/files/OneDrive"
}

cmd_install() { each_user _install_user "${1:---all}"; }

# ---- verify ---------------------------------------------------------
_verify_user() {
    local u="$1" r="$2"
    local dst="$NC_DATA/$u/files/OneDrive"
    [[ -d "$dst" ]] || { echo "skip $u: not installed" >&2; return 0; }
    echo "==> $u"
    # one-way: extra files locally are fine, missing ones are not.
    rc "$r" check "$r:" "$dst" --one-way || true
}

cmd_verify() { each_user _verify_user "${1:---all}"; }

# ---- shared / group folder ------------------------------------------
cmd_shared() {
    while IFS='|' read -r srcspec name group <&3; do
        srcspec="$(trim "${srcspec:-}")"; name="$(trim "${name:-}")"; group="$(trim "${group:-}")"
        [[ -z "$srcspec" || "$srcspec" == \#* ]] && continue

        local remote="${srcspec%%:*}"
        [[ -f "$CONFDIR/$remote.conf" ]] || { echo "skip '$name': '$remote' not configured" >&2; continue; }

        # find or create the folder, and take its numeric id
        local id
        id="$(occ groupfolders:list --output=json 2>/dev/null \
              | grep -o "\"id\":[0-9]*,\"mount_point\":\"$name\"" \
              | grep -o '[0-9]\+' | head -1 || true)"
        if [[ -z "$id" ]]; then
            echo "==> creating group folder '$name'"
            id="$(occ groupfolders:create "$name" | tr -dc '0-9')"
            [[ -n "$group" ]] && occ groupfolders:group "$id" "$group" write
        fi
        echo "==> group folder '$name' is id $id"

        local stage="$STAGING/__gf-$id"
        mkdir -p "$stage"
        rc "$remote" copy "$srcspec" "$stage" $RCLONE_FLAGS --progress \
            --log-file "$DIR/rclone-gf-$id.log" --log-level INFO

        local dst="$NC_DATA/__groupfolders/$id"
        mkdir -p "$dst"
        # merge rather than replace: the folder may already hold things
        cp -a "$stage/." "$dst/"
        rm -rf "$stage"
        chown -R "$NC_UID:$NC_GID" "$dst"

        occ groupfolders:scan "$id"
    done 3< "$SHARED"
}

# ---------------------------------------------------------------------
case "${1:-}" in
    check)   shift; cmd_check "$@" ;;
    auth)    shift; cmd_auth "$@" ;;
    paste)   shift; cmd_paste "$@" ;;
    fetch)   shift; cmd_fetch "${1:---all}" ;;
    install) shift; cmd_install "${1:---all}" ;;
    verify)  shift; cmd_verify "${1:---all}" ;;
    shared)  shift; cmd_shared "$@" ;;
    *) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac

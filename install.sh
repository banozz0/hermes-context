#!/bin/sh
# Hermes Context: the menu-bar app plus the observer plugin in every Hermes profile, in one line.
#
#   curl -fsSL https://github.com/banozz0/hermes-context/releases/latest/download/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --uninstall [--purge]
#
# Run it again to connect a profile added later or to update. Uninstall keeps your history unless
# --purge is given. release.sh stamps VERSION and COMMIT, so the app and the plugin always come from
# one commit. The HERMES_CONTEXT_* variables below point it at a local build or a throwaway Hermes home.
set -eu

VERSION="@VERSION@"
COMMIT="@COMMIT@"
REPO="banozz0/hermes-context"
PLUGIN="hermes-context-observer"
APP="HermesContext.app"

plugin_source=${HERMES_CONTEXT_PLUGIN_SOURCE:-$REPO/hermes_context_observer}
app_zip=${HERMES_CONTEXT_APP_ZIP:-https://github.com/$REPO/releases/download/v$VERSION/HermesContext.zip}
history_dir="$HOME/Library/Application Support/dev.banozz0.hermes-context"

say() { printf '%s\n' "$*"; }
die() { printf 'Hermes Context: %s\n' "$*" >&2; exit 1; }

# Where the app may live: /Applications when writable, else ~/Applications; the override replaces both.
app_dirs() {
    if [ -n "${HERMES_CONTEXT_INSTALL_DIR:-}" ]; then
        printf '%s\n' "$HERMES_CONTEXT_INSTALL_DIR"
    else
        [ -w /Applications ] && printf '%s\n' /Applications
        printf '%s\n' "$HOME/Applications"
    fi
}

has_hermes() { command -v hermes >/dev/null 2>&1; }

# Every profile id Hermes knows, default included, read from its table: the label runs up to the
# model just before the Gateway column (running or stopped), and a display name shows as `Name (id)`.
# The table ends at its first blank line; warnings may follow.
profiles() {
    hermes profile list </dev/null | awk '
        /───/ { rows = 1; next }
        rows && !NF { exit }
        rows {
            sub("◆", "")
            for (gateway = 3; gateway <= NF; gateway++) if ($gateway == "running" || $gateway == "stopped") break
            label = $1
            for (i = 2; i <= gateway - 2; i++) label = label " " $i
            if (match(label, /\([^()]+\)$/)) label = substr(label, RSTART + 1, RLENGTH - 2)
            print label
        }'
}

# True when the profile already runs this release's observer, enabled.
current() {
    hermes -p "$1" plugins list --json </dev/null 2>/dev/null | tr -d '\n' \
        | grep -o "\"name\": *\"$PLUGIN\"[^}]*" | grep "\"status\": *\"enabled\"" \
        | grep -q "pinned@$(printf '%s' "$COMMIT" | cut -c1-8)"
}

# Quits the app running from this directory (a build elsewhere is left alone) and deletes it.
remove_app() {
    pkill -f "$1/$APP/Contents/MacOS/HermesContext" 2>/dev/null || true
    rm -rf "${1:?}/$APP"
}

install() {
    [ "$(uname -s)" = Darwin ] || die "needs macOS."
    macos=$(sw_vers -productVersion)
    [ "${macos%%.*}" -ge 14 ] || die "needs macOS 14 or later; this Mac runs $macos."
    has_hermes || die "needs Hermes: there is no \`hermes\` command on your PATH. Install Hermes first."
    printf '%s' "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "this install.sh was not stamped by release.sh."
    names=$(profiles)
    [ -n "$names" ] || die "Hermes lists no profiles."

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    say "Downloading Hermes Context ${VERSION}…"
    case $app_zip in
        http://* | https://*) curl -fsSL "$app_zip" -o "$work/app.zip" || die "could not download $app_zip." ;;
        *) cp "$app_zip" "$work/app.zip" ;;
    esac
    ditto -x -k "$work/app.zip" "$work/unpacked"
    [ -d "$work/unpacked/$APP" ] || die "the download holds no $APP."

    for name in $names; do
        if current "$name"; then
            say "Hermes profile $name is already connected."
            continue
        fi
        say "Connecting Hermes profile ${name}…"
        hermes -p "$name" plugins install "$plugin_source" --ref "$COMMIT" --enable --force \
            </dev/null >"$work/hermes.log" 2>&1 \
            || { cat "$work/hermes.log" >&2; die "could not install the observer into profile $name."; }
        # Hermes asks a running gateway to reload; when none answers it says to restart instead.
        ! grep -q "hermes gateway restart" "$work/hermes.log" || unloaded="${unloaded:-} $name"
    done

    dir=$(app_dirs | head -n 1)
    if diff -rq "$work/unpacked/$APP" "$dir/$APP" >/dev/null 2>&1; then
        say "$dir/$APP is already this version."
    else
        mkdir -p "$dir"
        remove_app "$dir"
        mv "$work/unpacked/$APP" "$dir/$APP"
        say "Installed $dir/$APP."
    fi
    say "Connected:" $names
    [ -z "${unloaded:-}" ] || say "No running gateway loaded the observer for:${unloaded}. Run \`hermes gateway restart\` to start it."
    [ -n "${HERMES_CONTEXT_NO_OPEN:-}" ] || open "$dir/$APP"
}

uninstall() {
    purge=$1
    if has_hermes; then
        for name in $(profiles); do
            if hermes -p "$name" plugins show "$PLUGIN" </dev/null >/dev/null 2>&1; then
                say "Disconnecting Hermes profile ${name}…"
                hermes -p "$name" plugins remove "$PLUGIN" </dev/null >/dev/null
            fi
            if [ "$purge" = yes ]; then
                home=$(hermes profile show "$name" </dev/null | awk '$1 == "Path:" { sub(/^Path:[ ]+/, ""); print; exit }')
                [ -z "$home" ] || rm -rf "$home/hermes-context"
            fi
        done
    fi
    app_dirs | while IFS= read -r dir; do
        if [ -d "$dir/$APP" ]; then
            remove_app "$dir"
            say "Removed $dir/$APP"
        fi
    done
    if [ "$purge" = yes ]; then
        rm -rf "$history_dir"
        say "Deleted history and bridge files."
    else
        say "History kept in $history_dir"
    fi
}

case "${1:-}" in
    "") install ;;
    --uninstall)
        case "${2:-}" in
            "") uninstall no ;;
            --purge) uninstall yes ;;
            *) die "unknown option: $2" ;;
        esac ;;
    *) die "usage: install.sh [--uninstall [--purge]]" ;;
esac

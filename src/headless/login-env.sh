#!/bin/sh
# mMac read the login shell's environment once and started this backend with it. discoverCli in
# src/main/cli.ts runs "$SHELL -ilc <command>" to read it again; src/headless/server.ts points
# SHELL here, so this answers that read from the environment the backend already has, with the
# real shell put back. MMAC_LOGIN_SHELL is left out of that environment: it names the real shell for
# this stub only, and must not reach muse serve or the agent commands that inherit the environment.
# Any other command goes to the real shell unchanged.
login_shell="${MMAC_LOGIN_SHELL:-/bin/zsh}"
# A login shell that names this stub would exec itself forever.
[ "$login_shell" -ef "$0" ] && login_shell=/bin/zsh
case "$2" in
  *MUSE_DESKTOP_ENV*)
    printf '\0MUSE_DESKTOP_ENV\0'
    SHELL="$login_shell" exec /usr/bin/env -u MMAC_LOGIN_SHELL -0
    ;;
esac
SHELL="$login_shell" exec "$login_shell" "$@"

#!/bin/sh
# mMac read the login shell's environment once and started this backend with it. discoverCli in
# src/main/cli.ts runs "$SHELL -ilc <command>" to read it again; src/headless/server.ts points
# SHELL here, so this answers from the environment the backend already has, with the real shell
# put back. The arguments are ignored.
printf '\0MUSE_DESKTOP_ENV\0'
SHELL="$MMAC_LOGIN_SHELL" exec /usr/bin/env -0

#!/bin/sh

# Try to figure out the user's PATH to pick up their installed utilities.
login_path=$(env -i HOME="$HOME" USER="$USER" SHELL="${SHELL:-/bin/zsh}" /bin/zsh -lc 'print -r -- $PATH' 2>/dev/null || true)
if [ -n "$login_path" ]; then
    export PATH="$PATH:$login_path"
fi

ninja "$@"

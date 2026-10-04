#!/bin/sh
# /etc/hostname.sh — применить имя хоста и проверить /etc/hosts.
BB=/bin/busybox

NAME=$(cat /etc/hostname 2>/dev/null)
[ -n "$NAME" ] || NAME=slattware

$BB hostname "$NAME" 2>/dev/null

# /etc/hosts нужен, иначе многие программы не резолвят даже localhost
if ! grep -q "$NAME" /etc/hosts 2>/dev/null; then
    {
        printf '127.0.0.1\tlocalhost\n'
        printf '127.0.1.1\t%s\n' "$NAME"
    } > /etc/hosts
fi

exit 0

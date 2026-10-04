#!/bin/sh
# /etc/autologin.sh — вход без логина/пароля.
# Вызывается getty через -l, поэтому шелл не закрывается после выхода.
#
# Если нужен обычный вход с паролем — в /etc/dinit.d/boot замени
#   -l /etc/autologin.sh
# на
#   (убрать -l)
USER_NAME=${USER_NAME:-slat}
USER_HOME=${USER_HOME:-/home/$USER_NAME}

# На диске /home могло не оказаться — тогда работаем в /root
if [ ! -d "$USER_HOME" ]; then
    USER_HOME=/root
fi
[ -d "$USER_HOME" ] || USER_HOME=/

cd "$USER_HOME" 2>/dev/null || cd /

export HOME="$USER_HOME"
export USER="$USER_NAME"
export LOGNAME="$USER_NAME"
export SHELL=/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TERM=${TERM:-vt100}

# -f: не спрашивать пароль, пользователь уже «аутентифицирован»
exec /bin/busybox login -f "$USER_NAME" -p

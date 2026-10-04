#!/bin/sh
echo "### date -s поддержка ###"
busybox date --help 2>&1 | head -5
echo "--- пробуем date -s ---"
busybox date -s "2026-10-02 18:20:00" 2>&1; echo "код=$?"
date
echo "--- date -d @epoch ---"
busybox date -d "@1790953934" '+%Y-%m-%d %H:%M:%S' 2>&1; echo "код=$?"
echo "--- TZ=UTC ---"
TZ=UTC busybox date -d "@1790953934" '+%Y-%m-%d %H:%M:%S' 2>&1
echo "--- точность ---"
cat /proc/uptime
echo "### dinit лог ###"
ls -la /var/log/ 2>&1
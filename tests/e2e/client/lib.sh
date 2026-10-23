#!/bin/bash
# Helpers run inside the client container via `docker exec`.
rd_logdir=/home/rd/.local/share/logs/RustDesk

rd_id() { su rd -c 'DISPLAY=:0 timeout 10 rustdesk --get-id' 2>/dev/null | grep -E '^[0-9a-zA-Z_-]+$' | tail -1; }

rd_shot() { # rd_shot <name>
    mkdir -p /artifacts
    DISPLAY=:0 import -window root "/artifacts/$(hostname)-$1.png"
}

rd_gui() { # start the main window (shows ID and the "Ready" status line)
    pgrep -u rd -fx rustdesk >/dev/null && return 0
    su rd -c 'DISPLAY=:0 nohup rustdesk >/tmp/rustdesk-gui.out 2>&1 &'
}

# Check helpers, sourced by run-matrix.sh (after env.sh).
# Every check prints exactly one result line via `result`:
#   PASS | FAIL | SKIP | MANUAL   <name>   <detail>
# MANUAL means the automated part ran and a screenshot needs a human look.

RESULTS=${RESULTS:-$E2E_STATE/out/results.tsv}
OUT=$E2E_STATE/out
WSS_ID=wss://rd.e2e.test/ws/id

result() { # result <status> <name> <detail...>
    local st=$1 name=$2; shift 2
    printf '%s\t%s\t%s\n' "$st" "$name" "$*" | tee -a "$RESULTS" >&2
}

cexec() { # cexec <container> <bash snippet>  (snippet may use rd-lib.sh helpers)
    docker exec "$1" bash -c ". /usr/local/bin/rd-lib.sh; $2"
}

device_id() { cexec "$1" rd_id; }

# The client sets key_confirmed and the per-host flag only after it receives
# RegisterPkResponse.OK; the GUI derives "Ready" from the same flags.
device_ready() { # device_ready <container>
    cexec "$1" 'f=/home/rd/.config/rustdesk/RustDesk.toml
        grep -q "^key_confirmed = true" "$f" 2>/dev/null &&
        sed -n "/^\[keys_confirmed\]/,/^\[/p" "$f" | grep -q "= true"'
}

wait_ready() { # wait_ready <container> <seconds>
    local c=$1 t=$2 i
    for ((i = 0; i < t; i += 3)); do
        device_ready "$c" && return 0
        sleep 3
    done
    return 1
}

# Count rendezvous (re)connections and registration errors in the client log.
server_log() { cexec "$1" 'cat /home/rd/.local/share/logs/RustDesk/server/*.log 2>/dev/null'; }
count_log() { server_log "$1" | grep -c -- "$2" || true; }

probe() { # probe <args...>   runs the probe on the wan network (trusted path via nginx)
    # One retry when the probe produced no output (it crashed before printing);
    # stderr of every call is kept in probe-stderr.log.
    local out attempt
    for attempt in 1 2; do
        out=$("${DC[@]}" --profile probe run --rm -T probe "$@" 2>>"$OUT/probe-stderr.log" | tail -1)
        [ -n "$out" ] && break
        echo "[probe attempt $attempt produced no output: $*]" >>"$OUT/probe-stderr.log"
        sleep 2
    done
    printf '%s\n' "$out"
}

online_state() { # online_state <id>  -> true|false|no_response
    probe online "$WSS_ID" --peers "$1" --brief
}

shot() { cexec "$1" "rd_shot $2" >/dev/null 2>&1; echo "$OUT/${1#patina-e2e-}-$2.png"; }

# Fraction (0-100) of the controller screen that has the device's desktop
# colour: a remote-desktop window showing that device renders a large solid area.
colour_share() { # colour_share <container> <png-name> <#rrggbb>
    cexec "$1" "convert /artifacts/\$(hostname)-$2.png -fuzz 6% -fill black +opaque '$3' -fill white -opaque '$3' -format '%[fx:100*mean]' info:"
}

# Open a remote desktop (or file transfer) session from a controller GUI.
connect_gui() { # connect_gui <controller> <id> [--file-transfer]
    local mode=${3:---connect}
    cexec "$1" "su rd -c 'DISPLAY=:0 nohup rustdesk $mode $2 --password $RD_PASSWORD >/tmp/connect.out 2>&1 &'"
}

# `--connect` hands the session to the running main window and exits, so the
# only reliable way to close sessions is restarting the controller's GUI.
# (Kill and relaunch are separate execs: pkill -f would match its own shell.)
close_gui_sessions() { # close_gui_sessions <controller>
    docker exec "$1" pkill -u rd -x rustdesk
    sleep 2
    cexec "$1" rd_gui
    sleep 5
}

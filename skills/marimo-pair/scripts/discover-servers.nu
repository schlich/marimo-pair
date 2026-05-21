#!/usr/bin/env nu
# List running marimo instances from the server registry.
# Cleans up stale entries (dead PIDs) and outputs live servers as JSON.
# No marimo installation required.

def is-windows []: nothing -> bool {
    $nu.os-info.name == "windows"
}

def servers-dir []: nothing -> string {
    let home = $nu.home-dir
    if (is-windows) {
        $"($home)/.marimo/servers"
    } else {
        let xdg = ($env.XDG_STATE_HOME? | default $"($home)/.local/state")
        $"($xdg)/marimo/servers"
    }
}

# Liveness check. On POSIX, `kill -0 $pid` is cheap and reliable. On Windows
# `kill` operates on Cygwin PIDs, not the native Windows PIDs marimo writes,
# so fall back to an HTTP probe against marimo's /health.
def check-live [entry: record]: nothing -> bool {
    if (is-windows) {
        let url = $"http://($entry.host):($entry.port)($entry.base_url)/health"
        (^curl -sf --max-time 1 $url | complete).exit_code == 0
    } else {
        (^kill -0 $entry.pid | complete).exit_code == 0
    }
}

def main [] {
    let dir = (servers-dir)
    if not ($dir | path exists) {
        print "[]"
        return
    }

    let files = (try { glob $"($dir)/*.json" } catch { [] })

    let live = ($files | each {|f|
        let entry = try { open --raw $f | from json } catch { null }
        if ($entry == null) {
            null
        } else if (check-live $entry) {
            $entry
        } else {
            # On Windows the HTTP probe can fail transiently (slow start, busy
            # server), so keep the entry; only POSIX `kill -0` is reliable
            # enough to delete on.
            if not (is-windows) {
                try { rm --force $f }
            }
            null
        }
    } | compact)

    print ($live | to json --indent 2)
}

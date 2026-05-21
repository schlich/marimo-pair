#!/usr/bin/env nu
# Execute code in a running marimo session's scratchpad.
# No marimo installation required — talks directly to the HTTP API.
# Usage:
#   nu execute-code.nu [--port PORT] [--session ID] -c "code"        # inline code
#   nu execute-code.nu [--port PORT] [--session ID] script.py        # code from file
#   "code" | nu --stdin execute-code.nu [--port PORT] [--session ID] # stdin
#   nu execute-code.nu --url URL [--session ID] -c "code"            # skip discovery
#
# For heredocs from bash: `nu --stdin execute-code.nu <<'EOF'` ... `EOF`.
#
# Auth: set MARIMO_TOKEN env var (preferred) or pass --token TOKEN
# (visible in process listings).

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

# Find the single live registry entry matching the optional port filter.
def find-server [port: string]: nothing -> record {
    let dir = (servers-dir)
    if not ($dir | path exists) {
        print -e "No running marimo instances found."
        exit 1
    }

    let files = (try { glob $"($dir)/*.json" } catch { [] })

    let entries = ($files | each {|f|
        let entry = try { open --raw $f | from json } catch { null }
        if ($entry == null) {
            null
        } else if (check-live $entry) {
            $entry
        } else {
            if not (is-windows) {
                try { rm --force $f }
            }
            null
        }
    } | compact)

    let matches = if ($port | is-empty) {
        $entries
    } else {
        $entries | where port == ($port | into int)
    }

    if ($matches | is-empty) {
        print -e "No running marimo instances found."
        exit 1
    }

    if (($matches | length) > 1) {
        print -e "Multiple instances found. Use --port to specify:"
        for s in ($matches | get server_id) {
            print -e $s
        }
        exit 1
    }

    $matches | first
}

def warn-non-local [url: string] {
    let host = ($url
        | parse --regex '^[a-z]+://(?P<h>[^:/]+)'
        | get h?
        | default [""]
        | first)
    match $host {
        "localhost" | "127.0.0.1" | "::1" | "0.0.0.0" | "" => {}
        _ => {
            print -e $"Warning: connecting to non-local server '($host)'. Ensure this is trusted."
        }
    }
}

def main [
    --port: string = ""
    --url: string = ""
    --token: string = ""
    --session: string = ""
    --code (-c): string = ""
    file?: string
] {
    let stdin_in = $in

    # Optional eval logging: set EXECUTE_CODE_LOG to a file path
    let log = ($env.EXECUTE_CODE_LOG? | default "")
    if ($log | is-not-empty) {
        $"(date now | format date '%Y-%m-%dT%H:%M:%SZ')\n" | save --append $log
    }

    let token = if ($token | is-empty) {
        $env.MARIMO_TOKEN? | default ""
    } else {
        $token
    }

    # Resolve code from -c flag, file argument, or stdin
    let stdin_str = if ($stdin_in == null) { "" } else { $stdin_in | into string }
    let code = if ($code | is-not-empty) {
        $code
    } else if ($file != null) {
        open --raw $file
    } else if ($stdin_str | is-not-empty) {
        $stdin_str
    } else {
        print -e "Usage: nu execute-code.nu [--port PORT | --url URL] -c 'code'"
        print -e "       nu execute-code.nu [--port PORT | --url URL] script.py"
        print -e "       'code' | nu --stdin execute-code.nu [--port PORT | --url URL]"
        print -e "Auth:  set MARIMO_TOKEN env var (preferred) or pass --token TOKEN"
        exit 1
    }

    # Resolve base URL
    let base = if ($url | is-not-empty) {
        warn-non-local $url
        $url | str trim --right --char '/'
    } else {
        let entry = (find-server $port)
        $"http://($entry.host):($entry.port)($entry.base_url)"
    }

    # Build optional auth header args
    let auth_args = if ($token | is-empty) {
        []
    } else {
        ["-H" $"Authorization: Bearer ($token)"]
    }

    # Discover session ID
    let session_id = if ($session | is-not-empty) {
        $session
    } else {
        let resp = (^curl -sf ...$auth_args $"($base)/api/sessions" | complete)
        if $resp.exit_code != 0 {
            print -e $"Failed to connect to marimo server at ($base)"
            exit 1
        }
        let sessions = ($resp.stdout | from json)
        let keys = ($sessions | columns)
        if ($keys | is-empty) {
            print -e "No active sessions on the server. Make sure a notebook is open in the browser."
            exit 1
        }
        if (($keys | length) > 1) {
            print -e "Multiple sessions on server. Cannot auto-select:"
            for entry in ($sessions | items {|k, v| $"($k)  ($v.filename? | default '')"}) {
                print -e $entry
            }
            exit 1
        }
        $keys | first
    }

    # Execute code via SSE stream.
    # Events: stdout/stderr stream as JSON {"data":"..."}; `done` is the final result.
    let body = ({code: $code} | to json)

    mut exit_code = 0
    mut current_event = ""

    let stream = (
        ^curl -sN -X POST $"($base)/api/kernel/execute"
            -H "Content-Type: application/json"
            -H $"Marimo-Session-Id: ($session_id)"
            ...$auth_args
            -d $body
        | lines
    )

    for line in $stream {
        if ($line | str starts-with "event:") {
            $current_event = ($line | str replace --regex '^event:\s*' '')
        } else if ($line | str starts-with "data:") {
            let payload = ($line | str replace --regex '^data:\s*' '')
            match $current_event {
                "stdout" => {
                    print --no-newline ($payload | from json | get data)
                }
                "stderr" => {
                    print --stderr --no-newline ($payload | from json | get data)
                }
                "done" => {
                    let data = ($payload | from json)
                    if (($data.success? | default true) == false) {
                        print --stderr ($data.error?.msg? | default "Unknown error")
                        $exit_code = 1
                    } else {
                        let out = ($data.output?.data? | default "")
                        if ($out | is-not-empty) {
                            print $out
                        }
                    }
                    break
                }
                _ => {}
            }
        }
    }

    exit $exit_code
}

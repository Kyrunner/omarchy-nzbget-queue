#!/usr/bin/env bash
# Where the NZBGet credentials may go, and what reply the plugin will parse.
#
#   bash endpoint-safety.test.sh
#
# Runs against stub JSON-RPC servers on localhost, so it needs no real NZBGet and
# no credentials. Marketplace review (2026-09-11) asked for three guarantees on
# the public fallback: the Basic-auth header never follows a redirect, never
# travels to a public address over plain HTTP, and a reply is capped in size
# before it is parsed. Each stub records the Authorization header it received,
# which is the only way to prove where the credentials actually went.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'kill ${STUB_PID:-} 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"   # keep the endpoint memory out of the real one

PORT="${NZBGET_TEST_PORT:-8793}"
TLS_PORT=$((PORT + 30)); REDIR_PORT=$((PORT + 31)); CATCH_PORT=$((PORT + 32)); BIG_PORT=$((PORT + 33))
GOOD_AUTH="Basic dTpw"                # u:p
export STUB_AUTH="$GOOD_AUTH" STUB_LOG="$WORK/seen-auth.txt" CATCH_LOG="$WORK/caught-auth.txt"
export STUB_PORT="$PORT" TLS_PORT REDIR_PORT CATCH_PORT BIG_PORT

# The TLS cert is self-signed for 127.0.0.1 and trusted through SSL_CERT_FILE, so
# the public-address path runs over real HTTPS rather than being faked.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
export SSL_CERT_FILE="$WORK/cert.pem" STUB_CERT="$WORK/cert.pem" STUB_CERTKEY="$WORK/key.pem"

python3 - <<'PY' &
import http.server, json, os, ssl, threading
AUTH = os.environ["STUB_AUTH"]; LOG = os.environ["STUB_LOG"]; CATCH_LOG = os.environ["CATCH_LOG"]
IDLE = {"DownloadRate": 0, "RemainingSizeMB": 0, "PostJobCount": 0, "UrlCount": 0,
        "DownloadPaused": False, "ServerPaused": False, "FreeDiskSpaceMB": 1024}


def reply(h, code, obj=None, raw=None):
    body = raw if raw is not None else json.dumps(obj).encode()
    h.send_response(code)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)


def rpc_result(h):
    n = int(h.headers.get("Content-Length") or 0)
    method = (json.loads(h.rfile.read(n) or b"{}")).get("method")
    return IDLE if method == "status" else ([] if method == "listgroups" else True)


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        got = self.headers.get("Authorization", "")
        with open(LOG, "w") as f:
            f.write(got)
        if got != AUTH:
            return reply(self, 401, {})
        reply(self, 200, {"result": rpc_result(self)})

    def log_message(self, *a):
        pass


class Redirect(H):
    def do_POST(self):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%s%s" % (os.environ["CATCH_PORT"], self.path))
        self.send_header("Content-Length", "0")
        self.end_headers()


class Catch(H):
    # urllib turns a redirected POST into a GET, so the catcher must answer both --
    # a catcher that 501s a GET never records the header and passes by accident.
    def do_POST(self):
        with open(CATCH_LOG, "w") as f:
            f.write(self.headers.get("Authorization", ""))
        reply(self, 200, {"result": rpc_result(self)})

    def do_GET(self):
        with open(CATCH_LOG, "w") as f:
            f.write(self.headers.get("Authorization", ""))
        reply(self, 200, {"result": IDLE})


class Big(H):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        reply(self, 200, raw=b'{"result": {}, "pad": "' + b"x" * (5 * 1024 * 1024) + b'"}')


def serve(port, handler, tls=False):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.environ["STUB_CERT"], os.environ["STUB_CERTKEY"])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


serve(os.environ["STUB_PORT"], H)
serve(os.environ["TLS_PORT"], H, tls=True)
serve(os.environ["REDIR_PORT"], Redirect)
serve(os.environ["CATCH_PORT"], Catch)
serve(os.environ["BIG_PORT"], Big)
threading.Event().wait()
PY
STUB_PID=$!

for p in "$PORT" "$TLS_PORT" "$REDIR_PORT" "$CATCH_PORT" "$BIG_PORT"; do
  for _ in $(seq 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && break
    read -r -t 0.1 < /dev/zero 2>/dev/null || true
  done
done

pass=0
fail=0

run() { # name, expected-substring, config-json, [backend args...]
  local name="$1" want="$2" cfg="$3" out
  shift 3
  rm -f "$STUB_LOG"
  printf '%s' "$cfg" >"$WORK/config.json"
  out=$(OMARCHY_NZBGET_CONFIG="$WORK/config.json" "$PLUGIN/backend.sh" "$@" 2>&1)
  if [[ "$out" == *"$want"* ]]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$name" "$want" "$out"
  fi
}

# Nothing listens on port 1, so the LAN address fails fast and deterministically.
DEAD="http://127.0.0.1:1"
U="http://127.0.0.1:$PORT"
UT="https://127.0.0.1:$TLS_PORT"
UR="http://127.0.0.1:$REDIR_PORT"
UB="http://127.0.0.1:$BIG_PORT"
ENDPOINT="$WORK/state/omarchy-nzbget/endpoint.json"
CREDS='"user":"u","password":"p"'

echo "the public address over HTTPS still works:"
rm -f "$ENDPOINT"
run "LAN dead, https public_url answers" '"endpoint": "public"' "{\"url\":\"$DEAD\",\"public_url\":\"$UT\",$CREDS}"
rm -f "$ENDPOINT"   # the public choice above is sticky for 10 minutes
run "LAN alive is reported as lan"       '"endpoint": "lan"'    "{\"url\":\"$U\",\"public_url\":\"$UT\",$CREDS}"

echo "public address safety:"
rm -f "$ENDPOINT"
run "an http:// public_url is refused" '"error": "public_url must be https"' "{\"url\":\"$DEAD\",\"public_url\":\"$U\",$CREDS}"
if [ ! -e "$STUB_LOG" ]; then
  pass=$((pass + 1)); echo "  ok    the credentials were never sent to the plain-HTTP public address"
else
  fail=$((fail + 1)); echo "  FAIL  the credentials reached a plain-HTTP public address"
fi
rm -f "$ENDPOINT" "$CATCH_LOG"
run "a redirect is refused, not followed" '"error": "http 302"' "{\"url\":\"$UR\",$CREDS}"
run "a control refuses a redirect too"    '"error": "http 302"' "{\"url\":\"$UR\",$CREDS}" pause
if [ ! -e "$CATCH_LOG" ]; then
  pass=$((pass + 1)); echo "  ok    the redirect target never received the credentials"
else
  fail=$((fail + 1)); echo "  FAIL  the redirect target received the credentials: '$(cat "$CATCH_LOG")'"
fi
rm -f "$ENDPOINT"
run "an oversized response is refused" '"error": "response too large"' "{\"url\":\"$UB\",$CREDS}"

echo
if [ "$fail" -eq 0 ]; then
  echo "endpoint safety: all $pass assertions passed"
else
  echo "endpoint safety: $fail of $((pass + fail)) failed"
fi
[ "$fail" -eq 0 ]

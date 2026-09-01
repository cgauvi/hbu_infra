#!/usr/bin/env bash
# Port-forward the database to localhost through the SSM bastion.
#
# For the private posture: db_publicly_accessible = false, enable_bastion = true.
# Session Manager carries the TCP stream over the bastion's outbound agent
# connection, so this needs no open port, no SSH key, and no VPN — only IAM
# permission to start a session.
#
#   ./scripts/tunnel.sh [env] [local-port] [region]
#
# Then, in another shell:
#   psql "postgresql://USER:PASS@127.0.0.1:5433/urban_rag?sslmode=require"
#   DATABASE_URL="postgresql://USER:PASS@127.0.0.1:5433/urban_rag" ./scripts/db.py check
#
# Address it as 127.0.0.1, never `localhost`: the plugin binds IPv4 only, and a
# Windows resolver that answers `localhost` with ::1 first makes libpq burn its
# whole connect_timeout on the dead address before falling back to IPv4 and
# succeeding — which reads as a slow tunnel rather than as a misresolution.
#
# The tunnel runs in the foreground; Ctrl-C closes it.
#
# ---------------------------------------------------------------------------
# Supervised by default
#
# A raw port-forward is not durable enough to run a pipeline through. SSM closes
# an idle session after ~20 minutes, and `setbacks` is 53 minutes of server-side
# work with no traffic on this port; worse, when the session dies upstream the
# plugin keeps running and keeps its listener, so the port stays open and every
# later connect hangs for its full connect_timeout instead of failing. A dead
# tunnel and a healthy one look identical from the client.
#
# So this script supervises the session rather than exec'ing it: a Postgres
# SSLRequest round trip every TUNNEL_KEEPALIVE_INTERVAL seconds both keeps the
# session from idling out and detects the case where it died anyway, and a
# failed probe tears the session down and reconnects with backoff. The address
# on 127.0.0.1 stays the same across a reconnect, so a psql or a Dagster run
# that is merely idle survives one.
#
# It does not make an in-flight query survive: a reconnect drops the TCP
# connections through it, so whatever was running gets a closed connection and
# has to retry. What it fixes is the tunnel not being there afterwards.
#
# Tunables, all environment variables — see the block further down:
#   TUNNEL_SUPERVISE=0            one-shot foreground session, the old behaviour
#   TUNNEL_KEEPALIVE_INTERVAL=120 seconds between probes
#   TUNNEL_READY_TIMEOUT=60       seconds a new session gets to come up
#   TUNNEL_PROBE_TIMEOUT=10       seconds one probe waits for a reply
#   TUNNEL_BACKOFF_MAX=60         reconnect backoff ceiling
# ---------------------------------------------------------------------------

set -euo pipefail

ENV_NAME="${1:-dev}"
LOCAL_PORT="${2:-5433}"
REGION="${3:-${AWS_REGION:-us-east-1}}"
PROJECT="${HBU_PROJECT:-hbu}"
PREFIX="/${PROJECT}-${ENV_NAME}"

UNAME="$(uname -s)"

# ---------------------------------------------------------------------------
# Windows: run the real thing inside WSL
#
# The Session Manager plugin is a native binary, installed per kernel. On this
# machine it exists in WSL and not on Windows, so `make db-tunnel` from Git Bash
# or PowerShell died on the plugin check below while the identical command
# worked one shell over. Re-exec there instead of making that the operator's
# problem.
#
# This is only sound because .wslconfig sets networkingMode=mirrored: a listener
# bound to 127.0.0.1 inside WSL is then reachable from Windows' own loopback and
# from Docker Desktop containers via host-gateway — which is exactly what
# hbu_rag_map's `make docker-run-tunnel` connects back through. Under the older
# NAT mode the port stays inside the WSL VM and this would forward nothing, so
# the assumption is named here rather than left to be rediscovered.
# ---------------------------------------------------------------------------
case "$UNAME" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS= ;;
esac

if [ -n "$IS_WINDOWS" ] && ! command -v session-manager-plugin >/dev/null 2>&1; then
  WSL_EXE="$(command -v wsl.exe 2>/dev/null || true)"
  if [ -z "$WSL_EXE" ]; then
    WSL_EXE="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null || echo /c/Windows)/System32/wsl.exe"
  fi

  no_plugin_anywhere() {
    cat >&2 <<'MSG'
error: the AWS Session Manager plugin is not installed — not on Windows, and not
  in a WSL distribution this script could reach. Install it in either one:
  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
MSG
    exit 1
  }

  [ -x "$WSL_EXE" ] || no_plugin_anywhere

  # msys rewrites anything that looks like a Unix path before handing it to a
  # Windows binary, which mangles the /mnt/c command below. Both variables are
  # needed: msys2 reads the first, Git Bash the second.
  export MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1

  # wsl.exe writes UTF-16LE, so every name comes back interleaved with NULs.
  has_plugin() {
    if [ -z "$1" ]; then
      "$WSL_EXE" -e bash -c 'command -v session-manager-plugin' >/dev/null 2>&1
    else
      "$WSL_EXE" -d "$1" -e bash -c 'command -v session-manager-plugin' >/dev/null 2>&1
    fi
  }

  # The default distro first; then every other one, because docker-desktop is in
  # that list too and does not carry the plugin.
  DISTRO=
  FOUND=
  if has_plugin ""; then
    FOUND=1
  else
    for d in $("$WSL_EXE" -l -q 2>/dev/null | tr -d '\0\r'); do
      if has_plugin "$d"; then DISTRO="$d"; FOUND=1; break; fi
    done
  fi
  [ -n "$FOUND" ] || no_plugin_anywhere

  REPO_WIN="$(cygpath -m "$(cd "$(dirname "$0")/.." && pwd)")"
  if [ -z "$DISTRO" ]; then
    REPO_WSL="$("$WSL_EXE" -e wslpath -a "$REPO_WIN" | tr -d '\0\r')"
  else
    REPO_WSL="$("$WSL_EXE" -d "$DISTRO" -e wslpath -a "$REPO_WIN" | tr -d '\0\r')"
  fi

  # AWS_PROFILE has to be carried across: WSL starts a non-login shell here, so
  # nothing in ~/.bashrc runs and the profile pinned by the Makefile would be
  # lost, leaving the delegated run on the default account. AWS_CA_BUNDLE is
  # deliberately *not* carried — a Windows path means nothing over there, and
  # the block further down picks the Linux trust store instead.
  REMOTE="cd $(printf %q "$REPO_WSL") && export AWS_PROFILE=$(printf %q "${AWS_PROFILE:-}")"
  REMOTE="$REMOTE HBU_PROJECT=$(printf %q "$PROJECT")"

  # The supervisor's tunables have to be carried for the same reason. They are
  # forwarded only when actually set, so an unset one keeps the default in the
  # delegated run rather than arriving as an empty string — TUNNEL_SUPERVISE=""
  # is not 1, which would silently disable supervision for every Windows caller.
  for _v in TUNNEL_SUPERVISE TUNNEL_KEEPALIVE_INTERVAL TUNNEL_READY_TIMEOUT \
            TUNNEL_PROBE_TIMEOUT TUNNEL_BACKOFF_MAX; do
    if [ -n "${!_v:-}" ]; then
      REMOTE="$REMOTE ${_v}=$(printf %q "${!_v}")"
    fi
  done

  REMOTE="$REMOTE &&"
  REMOTE="$REMOTE exec ./scripts/tunnel.sh $(printf %q "$ENV_NAME") $(printf %q "$LOCAL_PORT") $(printf %q "$REGION")"

  echo "session-manager-plugin is not installed on Windows; running the tunnel in WSL${DISTRO:+ ($DISTRO)}" >&2
  if [ -z "$DISTRO" ]; then
    exec "$WSL_EXE" -e bash -c "$REMOTE"
  else
    exec "$WSL_EXE" -d "$DISTRO" -e bash -c "$REMOTE"
  fi
fi

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }

# The Session Manager plugin is a separate install from the CLI, and its
# absence surfaces as an unhelpful "SessionManagerPlugin is not found".
if ! session-manager-plugin --version >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: the AWS Session Manager plugin is not installed.
  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
MSG
  exit 1
fi

# botocore ships its own CA bundle and never reads the system trust store, so
# behind a TLS-inspecting proxy every call below dies with
# CERTIFICATE_VERIFY_FAILED. param() used to discard that, which is how a proxy
# problem came out as "has make apply run?". The system bundle is a superset of
# the public roots, so this is a no-op where nothing is in the way. The same
# reasoning as the Makefile's AWS_CA_BUNDLE, repeated because the delegated WSL
# run above has no make around it to set it.
if [ -z "${AWS_CA_BUNDLE:-}" ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; then
  export AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
fi

# ---------------------------------------------------------------------------
# Tunables. All are environment variables so the Makefile — and a long pipeline
# run that wants a gentler probe — can override them without editing this file.
# ---------------------------------------------------------------------------

# 0 disables the supervisor and runs a single session in the foreground, which
# is what this script did before. Useful when the plugin itself is what is being
# debugged and its output should not be captured to a log.
SUPERVISE="${TUNNEL_SUPERVISE:-1}"

# How often the health probe runs. It doubles as the keepalive: SSM closes an
# idle session (~20 min by default, 60 min at the very most), and a `setbacks`
# materialisation is 53 minutes of server-side work during which this port
# carries no traffic at all, so something has to keep it warm. 120s is well
# inside the shortest timeout and costs nothing.
KEEPALIVE_INTERVAL="${TUNNEL_KEEPALIVE_INTERVAL:-120}"

# How long a freshly started session has to open the port and answer a probe.
READY_TIMEOUT="${TUNNEL_READY_TIMEOUT:-60}"

# How long one probe waits for the far end to answer.
PROBE_TIMEOUT="${TUNNEL_PROBE_TIMEOUT:-10}"

# Restart backoff ceiling, in seconds. A laptop that suspends overnight comes
# back to a poll every minute rather than to a hot loop.
BACKOFF_MAX="${TUNNEL_BACKOFF_MAX:-60}"

SESSION_LOG="${TMPDIR:-/tmp}/hbu-tunnel-${ENV_NAME}-${LOCAL_PORT}.log"

SESSION_PID=
SHUTDOWN=

log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# ---------------------------------------------------------------------------
# Reading AWS
#
# Failures are reported rather than swallowed: an expired profile and a
# never-applied environment produce the same empty output otherwise.
# ---------------------------------------------------------------------------

param() {
  local out
  if ! out="$(aws ssm get-parameter --name "${PREFIX}/$1" --region "$REGION" \
              --query Parameter.Value --output text 2>&1)"; then
    {
      echo "error: could not read ${PREFIX}/$1 (AWS_PROFILE=${AWS_PROFILE:-<unset>}):"
      echo "$out" | tail -n 2 | sed 's/^/  /'
    } >&2
    return 1
  fi
  printf '%s' "$out"
}

# Re-resolved before every (re)connect rather than once at startup. The bastion
# is cattle: a stop/start or a replacement gives it a new instance id, and a
# supervisor holding the old one would retry against a machine that no longer
# exists until someone restarted it by hand.
resolve_target() {
  DB_HOST="$(param db/host)" || return 1
  DB_PORT="$(param db/port)" || return 1
  if [ -z "${DB_HOST:-}" ] || [ "$DB_HOST" = "None" ]; then
    echo "error: no database parameters under ${PREFIX} in ${REGION} — has 'make apply ENV=${ENV_NAME}' run?" >&2
    return 1
  fi

  # Tagged by Terraform as <project>-<env>-bastion. `|| BASTION_ID=` for the
  # same errexit reason as in kill_session: a describe-instances that fails
  # because the SSO session expired overnight has to become a retry with
  # backoff, not the death of the supervisor.
  BASTION_ID="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${PROJECT}-${ENV_NAME}-bastion" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)" \
    || BASTION_ID=

  if [ -z "$BASTION_ID" ] || [ "$BASTION_ID" = "None" ]; then
    echo "error: no running bastion named ${PROJECT}-${ENV_NAME}-bastion." >&2
    echo "       Set enable_bastion = true in ${ENV_NAME}.tfvars and re-apply," >&2
    echo "       or start it if it is merely stopped." >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The health probe
#
# A dead SSM session is indistinguishable from a healthy one at the TCP layer.
# When the session times out upstream, session-manager-plugin keeps running and
# keeps its 127.0.0.1 listener, so connect() still succeeds and nothing ever
# comes back: every client blocks for its full connect_timeout and then reports
# something that reads like a slow database rather than a dead tunnel. So "is
# the port open" is not a health check. Only a round trip to the far end is.
#
# The round trip is Postgres' SSLRequest: eight bytes — length 8, request code
# 80877103 — to which any live server replies with a single byte, 'S' if it will
# do TLS and 'N' if it will not. It needs no credentials, so the probe cannot
# fail for a reason that has nothing to do with the tunnel, and it holds no
# connection open.
#
# Its one cost is server-side noise: the probe hangs up after reading the reply
# instead of completing a handshake, and Postgres logs that as a failed SSL
# connection. At the default interval that is ~700 lines a day in the instance's
# CloudWatch log group. Raise TUNNEL_KEEPALIVE_INTERVAL if that matters more
# than detecting a dead session quickly.
# ---------------------------------------------------------------------------

probe() {
  # LOCAL_PORT and PROBE_TIMEOUT are integers, so interpolating them into the
  # child's source is safe. `timeout` wraps the whole thing because bash has no
  # connect timeout on /dev/tcp: a connect to a live listener returns from the
  # kernel immediately, but the half-open socket a suspended laptop leaves
  # behind would otherwise hang here for the kernel's whole retry budget.
  timeout "$((PROBE_TIMEOUT + 2))" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/'"$LOCAL_PORT"' || exit 1
    printf "\x00\x00\x00\x08\x04\xd2\x16\x2f" >&3 || exit 1
    IFS= read -r -N1 -t '"$PROBE_TIMEOUT"' reply <&3 || exit 2
    [ "$reply" = S ] || [ "$reply" = N ] || exit 3
  ' >/dev/null 2>&1
}

port_listening() {
  ss -ltn 2>/dev/null | grep -q ":${LOCAL_PORT} "
}

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

start_session() {
  aws ssm start-session \
    --region "$REGION" \
    --target "$BASTION_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"${DB_HOST}\"],\"portNumber\":[\"${DB_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
    >"$SESSION_LOG" 2>&1 &
  SESSION_PID=$!
}

# The plugin is a child of the `aws` process, and killing only the parent
# orphans it — still holding the port, so the next attempt dies on "Address
# already in use". Take the children with it, then wait for the listener to go.
kill_session() {
  [ -n "${SESSION_PID:-}" ] || return 0
  local kids i
  # The `|| true` is load-bearing under `set -euo pipefail`. By the time this
  # runs the aws process is usually already dead, so pgrep matches nothing and
  # exits 1; pipefail carries that past `tr`, and a failed command substitution
  # in an assignment trips errexit. The supervisor would then exit(1) at exactly
  # the moment it is supposed to reconnect — which is how this was found.
  kids="$(pgrep -P "$SESSION_PID" 2>/dev/null | tr '\n' ' ' || true)"
  # shellcheck disable=SC2086
  kill -TERM "$SESSION_PID" $kids 2>/dev/null || true

  for i in $(seq 1 50); do
    port_listening || break
    sleep 0.1
  done
  if port_listening; then
    # shellcheck disable=SC2086
    kill -KILL "$SESSION_PID" $kids 2>/dev/null || true
    sleep 0.5
  fi
  wait "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=
}

# Sleep in short slices so a SIGTERM is acted on promptly: a bash trap does not
# interrupt a running command, so one `sleep 120` would delay shutdown by up to
# a whole keepalive interval.
nap() {
  local left="$1"
  while [ "$left" -gt 0 ]; do
    [ -n "$SHUTDOWN" ] && return 0
    if [ "$left" -gt 5 ]; then sleep 5; left=$((left - 5)); else sleep "$left"; left=0; fi
  done
  return 0
}

wait_ready() {
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    [ -n "$SHUTDOWN" ] && return 1
    kill -0 "$SESSION_PID" 2>/dev/null || return 1
    probe && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Returns when the session needs replacing — either the process died or the
# probe stopped getting an answer.
monitor() {
  while :; do
    nap "$KEEPALIVE_INTERVAL"
    [ -n "$SHUTDOWN" ] && return 0
    if ! kill -0 "$SESSION_PID" 2>/dev/null; then
      log "session process exited"
      return 0
    fi
    if ! probe; then
      log "keepalive probe got no answer — the session is dead upstream"
      return 0
    fi
  done
}

# The plugin's own output is captured rather than shown: it is a three-line
# banner plus one "Connection accepted" per connect, which buries the status
# lines that matter. It is worth reading when a start fails, though, and that is
# where the real reason lives — an expired SSO session says so here and nowhere
# else.
dump_log() {
  [ -s "$SESSION_LOG" ] || return 0
  tail -n 6 "$SESSION_LOG" | sed 's/^/    /' >&2
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

if port_listening; then
  echo "error: something already listens on 127.0.0.1:${LOCAL_PORT}." >&2
  pgrep -af 'start-session|session-manager-plugin' >&2 || true
  echo "       Close it first, or pick another port: make db-tunnel LOCAL_PORT=5434" >&2
  exit 1
fi

if [ "$SUPERVISE" != "1" ]; then
  resolve_target || exit 1
  echo "tunnelling ${DB_HOST}:${DB_PORT} -> 127.0.0.1:${LOCAL_PORT} via ${BASTION_ID}"
  echo "unsupervised (TUNNEL_SUPERVISE=0); leave this running, Ctrl-C to close"
  exec aws ssm start-session \
    --region "$REGION" \
    --target "$BASTION_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"${DB_HOST}\"],\"portNumber\":[\"${DB_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
fi

trap 'SHUTDOWN=1; log "closing"; kill_session; exit 0' INT TERM

attempt=0
announced=

while :; do
  if resolve_target; then
    # stderr, like every other status line here. Mixing the two streams put
    # this line and the first log line in a race — stdout is block-buffered
    # when it is a file, stderr is not — and the banner lost.
    if [ -z "$announced" ]; then
      echo "tunnelling ${DB_HOST}:${DB_PORT} -> 127.0.0.1:${LOCAL_PORT} via ${BASTION_ID}" >&2
      announced=1
    fi
    start_session
    if wait_ready; then
      attempt=0
      log "up on 127.0.0.1:${LOCAL_PORT} — probing every ${KEEPALIVE_INTERVAL}s, Ctrl-C to close"
      monitor
    else
      [ -n "$SHUTDOWN" ] || { log "session did not come up within ${READY_TIMEOUT}s"; dump_log; }
    fi
    kill_session
  else
    log "could not resolve the tunnel target"
  fi

  [ -n "$SHUTDOWN" ] && exit 0

  attempt=$((attempt + 1))
  if [ "$attempt" -lt 6 ]; then delay=$((5 * 2 ** (attempt - 1))); else delay="$BACKOFF_MAX"; fi
  # `if` rather than `[ ... ] && ...`: a bare && list whose test is false leaves
  # a non-zero status behind, and this file runs under errexit.
  if [ "$delay" -gt "$BACKOFF_MAX" ]; then delay="$BACKOFF_MAX"; fi
  log "reconnecting in ${delay}s (attempt ${attempt})"
  nap "$delay"
  [ -n "$SHUTDOWN" ] && exit 0
done

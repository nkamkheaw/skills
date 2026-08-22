#!/usr/bin/env bash
#
# Deploy a Streamlit app to Azure App Service (Linux) and make it publicly
# reachable over HTTPS.
#
# Usage:
#   ./deploy.sh <app-name> [resource-group] [region]
#   ./deploy.sh <app-name> --detach          # returns immediately, deploys in background
#   ./deploy.sh <app-name> --remote-build    # let Azure install dependencies instead
#   ./deploy.sh --status <app-name>          # progress of a detached deploy
#
# <app-name> must be globally unique across Azure — it becomes the hostname
# https://<app-name>.azurewebsites.net
#
# Dependencies are installed locally as linux/x86_64 wheels and shipped with the
# code, because that is the faster of the two options here. Measured on this app
# over a ~1 MB/s uplink:
#
#   default (dependencies shipped)   ~27s packaging + ~303s upload + cold start
#                                    ≈ 6.5-8 min end to end
#   --remote-build                   840s end to end
#
# The upload dominates and is volatile — the same 128 MB payload has taken
# between ~120s and ~303s across runs — so on a slow or congested connection the
# advantage narrows and can disappear. --remote-build is also the fallback when
# a dependency publishes no prebuilt Linux wheel.
#
# Everything is created inside one resource group so `az group delete` is a
# complete teardown.

set -euo pipefail

STATE_ROOT="${HOME}/.azure-deploys"

# --- status mode: report on a detached run and exit ---------------------------
if [[ "${1:-}" == "--status" ]]; then
  app="${2:-}"
  run_dir="${STATE_ROOT}/${app}"
  if [[ -z "$app" || ! -d "$run_dir" ]]; then
    echo "usage: $0 --status <app-name>" >&2
    echo "known deploys: $(ls "$STATE_ROOT" 2>/dev/null | tr '\n' ' ')" >&2
    exit 2
  fi
  status="$(cat "$run_dir/status" 2>/dev/null || echo UNKNOWN)"
  echo "status: $status"
  echo "app:    https://${app}.azurewebsites.net"
  echo "log:    $run_dir/log"
  echo "--- last 15 lines ---"
  tail -15 "$run_dir/log" 2>/dev/null || true
  # Exit code doubles as a machine-readable answer: 0 done, 1 failed, 2 running.
  case "$status" in
    SUCCESS) exit 0 ;;
    FAILED)  exit 1 ;;
    *)       exit 2 ;;
  esac
fi

APP_NAME="${1:-}"

# --- flag parsing ----------------------------------------------------------
DETACH=0
# Dependencies are shipped with the code by default; --remote-build opts out and
# has Azure run pip install instead. See the timing note in the header.
VENDORED=1
# Where shipped dependencies live, relative to the site root. This must match
# the PYTHONPATH app setting below; Oryx will not discover it on its own.
VENDOR_DIR_REL=".python_packages/lib/site-packages"
args=()
for a in "$@"; do
  case "$a" in
    --detach)       DETACH=1 ;;
    --remote-build) VENDORED=0 ;;
    # Accepted for compatibility with older invocations; this is now the default.
    --vendored)     VENDORED=1 ;;
    *)              args+=("$a") ;;
  esac
done
set -- "${args[@]:-}"

if [[ "$DETACH" == "1" && "${_AZDEPLOY_CHILD:-}" != "1" ]]; then
  RUN_DIR="${STATE_ROOT}/${APP_NAME}"
  mkdir -p "$RUN_DIR"
  : > "$RUN_DIR/log"
  echo RUNNING > "$RUN_DIR/status"
  # Flags were stripped during parsing, so re-attach them for the child.
  child_flags=()
  [[ "$VENDORED" == "0" ]] && child_flags+=(--remote-build)
  # Run the child from an immutable snapshot. bash reads a script lazily by byte
  # offset, so editing this file while a deploy is in flight makes the running
  # copy jump to the wrong offset and fail with nonsense like
  # "line 138: t: command not found". Detached runs can last 15 minutes, which is
  # ample time to want to edit the script, so the child gets its own copy.
  SNAPSHOT="${RUN_DIR}/deploy-snapshot.sh"
  cp "$0" "$SNAPSHOT"
  chmod +x "$SNAPSHOT"
  _AZDEPLOY_CHILD=1 nohup "$SNAPSHOT" "$@" "${child_flags[@]:-}" >> "$RUN_DIR/log" 2>&1 &
  echo $! > "$RUN_DIR/pid"
  echo "==> Deploying ${APP_NAME} in the background (pid $(cat "$RUN_DIR/pid"))."
  echo "    Check on it:  $0 --status ${APP_NAME}"
  echo "    Follow along: tail -f ${RUN_DIR}/log"
  exit 0
fi

RESOURCE_GROUP="${2:-rg-${APP_NAME}}"
LOCATION="${3:-centralus}"
PLAN_NAME="plan-${APP_NAME}"
SKU="B1"
RUNTIME="PYTHON:3.14"
ENTRYPOINT="${ENTRYPOINT:-app.py}"

# When running detached, record the final outcome so --status can report it
# without the caller having to parse the log.
if [[ "${_AZDEPLOY_CHILD:-}" == "1" ]]; then
  RUN_DIR="${STATE_ROOT}/${APP_NAME}"
  record_outcome() {
    local rc=$?
    rm -f "${ZIP:-}" "${UPLOAD_LOG:-}" 2>/dev/null || true
    if [[ $rc -eq 0 ]]; then echo SUCCESS > "$RUN_DIR/status"
    else echo FAILED > "$RUN_DIR/status"; fi
  }
  trap record_outcome EXIT
  # A killed deploy must not look like a successful one. Without these, a SIGTERM
  # runs the EXIT trap while $? is still 0, so `--status` cheerfully reports
  # SUCCESS for a run that never finished -- and callers that gate on exit code 0
  # would act on a deployment that did not happen.
  trap 'echo FAILED > "$RUN_DIR/status"; rm -f "${ZIP:-}" "${UPLOAD_LOG:-}" 2>/dev/null; exit 143' TERM
  trap 'echo FAILED > "$RUN_DIR/status"; rm -f "${ZIP:-}" "${UPLOAD_LOG:-}" 2>/dev/null; exit 130' INT
fi

# Wall-clock budgets, in seconds. Every wait in this script is bounded, so the
# script always terminates rather than hanging on a container that will never
# start. Override from the environment for a slow or unusually large app.
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-900}"   # remote pip install
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-420}"   # container boot after the build

# Streamlit's own health endpoint. For a non-Streamlit app set this to "/".
HEALTH_PATH="${HEALTH_PATH:-/_stcore/health}"

if [[ -z "$APP_NAME" ]]; then
  echo "usage: $0 <app-name> [resource-group] [region] [--detach] [--remote-build]" >&2
  exit 2
fi

if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "error: $ENTRYPOINT not found in $(pwd)" >&2
  exit 2
fi

if [[ ! -f requirements.txt ]]; then
  echo "error: requirements.txt not found in $(pwd)" >&2
  exit 2
fi

echo "==> Signed in as:"
az account show --query "{subscription:name, user:user.name}" -o table

echo "==> Resource group: $RESOURCE_GROUP ($LOCATION)"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "==> App Service plan: $PLAN_NAME ($SKU, Linux)"
az appservice plan create \
  --name "$PLAN_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$SKU" \
  --is-linux \
  -o none

echo "==> Web app: $APP_NAME ($RUNTIME)"
# Note whether the app already exists. On a redeploy there is a previous
# container still serving traffic, which the health check further down has to be
# protected against; on a first deploy there is not.
if az webapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
     -o none 2>/dev/null; then
  APP_ALREADY_EXISTED=1
else
  APP_ALREADY_EXISTED=0
fi

az webapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" \
  --runtime "$RUNTIME" \
  -o none

# Oryx, the App Service build system, only installs requirements.txt when this
# is set. Without it the app starts with no dependencies and crashes on import.
#
# By default we ship dependencies ourselves, so the remote build is turned
# OFF instead -- that is where the time saving comes from.
if [[ "$VENDORED" == "1" ]]; then
  echo "==> Disabling server-side build (dependencies ship with the code)"
  # Oryx looks for a virtual environment named "antenv" or a package directory
  # named "__oryx_packages__". It does NOT know about .python_packages -- that
  # is the Azure Functions convention, and assuming it applies here is what
  # makes the deploy die with "No module named <framework>". The
  # interpreter path has to be set explicitly.
  BUILD_SETTING=(
    "SCM_DO_BUILD_DURING_DEPLOYMENT=false"
    "PYTHONPATH=/home/site/wwwroot/${VENDOR_DIR_REL}"
  )
else
  echo "==> Enabling server-side build"
  BUILD_SETTING=("SCM_DO_BUILD_DURING_DEPLOYMENT=true")
fi
az webapp config appsettings set \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings "${BUILD_SETTING[@]}" \
  -o none

# Streamlit keeps a long-lived WebSocket open between browser and server for
# every widget interaction. App Service does not enable WebSockets by default,
# and without it the page renders but nothing reacts.
#
# App Service routes external traffic to port 8000 on the container, so
# Streamlit must be told to listen there rather than on its default 8501.
#
# This must run BEFORE the code is deployed. Without a startup command the
# container falls back to gunicorn auto-detection, fails to boot, and any
# deploy command that waits for a healthy site will time out.
echo "==> Configuring WebSockets, Always On and the startup command"
az webapp config set \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --web-sockets-enabled true \
  --always-on true \
  --startup-file "python -m streamlit run ${ENTRYPOINT} --server.port 8000 --server.address 0.0.0.0 --server.headless true" \
  -o none

echo "==> Packaging source"
T_PACKAGE_START=$(date +%s)

# Install dependencies locally for the *target* platform and ship
# them. Oryx does not look inside .python_packages, so the PYTHONPATH app setting
# configured earlier is what actually makes these importable.
#
# The --platform flags are what make this work from an arm64 Mac: they tell pip
# to fetch x86_64 Linux wheels rather than wheels for this machine. --only-binary
# is mandatory alongside them, since anything built from source would compile for
# the wrong architecture.
if [[ "$VENDORED" == "1" ]]; then
  VENDOR_DIR="$VENDOR_DIR_REL"
  echo "    Installing dependencies for linux/x86_64 into ${VENDOR_DIR}"
  rm -rf .python_packages
  mkdir -p "$VENDOR_DIR"
  if ! python3 -m pip install -q -r requirements.txt --target "$VENDOR_DIR" \
      --platform manylinux_2_28_x86_64 \
      --platform manylinux_2_17_x86_64 \
      --platform any \
      --only-binary=:all: \
      --python-version "${VENDOR_PYTHON_VERSION:-3.14}" \
      --no-compile; then
    echo "==> Could not install dependencies for linux/x86_64." >&2
    echo "    A dependency has no prebuilt Linux wheel for that platform." >&2
    echo "    Re-run with --remote-build to have Azure install them instead." >&2
    exit 1
  fi
  # Test suites and bytecode caches are dead weight in the upload.
  find .python_packages -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find .python_packages -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
  echo "    Dependency payload: $(du -sh .python_packages | cut -f1)"
fi

ZIP="$(mktemp -t deploy-XXXXXX).zip"
UPLOAD_LOG="$(mktemp -t upload-XXXXXX).log"
# In detached mode the outcome recorder installed above already removes this,
# and a second `trap ... EXIT` here would silently clobber it.
if [[ "${_AZDEPLOY_CHILD:-}" != "1" ]]; then
  trap 'rm -f "${ZIP:-}" "${UPLOAD_LOG:-}"' EXIT
fi
cleanup_zip() { rm -f "$ZIP" "${UPLOAD_LOG:-}"; }
# -1 (fastest compression). On a payload of a few hundred megabytes the
# default level costs far more time than the bytes it saves on upload.
zip -r -q -1 "$ZIP" . \
  -x '*.git*' -x '*.venv*' -x '*venv/*' -x '*__pycache__*' \
  -x '*.zip' -x '*.DS_Store' -x '*.pyc'
echo "    Upload size: $(du -h "$ZIP" | cut -f1)"
echo "    Packaging took $(( $(date +%s) - T_PACKAGE_START ))s"

T_DEPLOY_START=$(date +%s)
if [[ "$VENDORED" == "1" ]]; then
  echo "==> Deploying source (dependencies included; no remote build)"
else
  echo "==> Deploying source (Oryx will install requirements.txt remotely)"
fi
# Use the classic ZipDeploy endpoint rather than `az webapp deploy`. The newer
# OneDeploy path reports "Deployment successful" with zero errors but does not
# reliably create the `antenv` virtual environment for Python, which leaves the
# container crash-looping on "No module named <your framework>".
#
# Run it in the background against a wall-clock deadline. A remote pip install
# routinely outlives the Kudu gateway's patience, which surfaces as a spurious
# HTTP 504 while the build carries on regardless -- so a hang here must not be
# allowed to block the script forever.
az webapp deployment source config-zip \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src "$ZIP" \
  -o none >"${UPLOAD_LOG}" 2>&1 &
deploy_pid=$!

waited=0
while kill -0 "$deploy_pid" 2>/dev/null; do
  if (( waited >= DEPLOY_TIMEOUT )); then
    echo "==> Deploy exceeded ${DEPLOY_TIMEOUT}s. Giving up on the upload." >&2
    kill "$deploy_pid" 2>/dev/null || true
    echo "    az webapp log deployment show --name $APP_NAME --resource-group $RESOURCE_GROUP" >&2
    exit 1
  fi
  sleep 10
  waited=$(( waited + 10 ))
  if (( waited % 60 == 0 )); then
    echo "    building... ${waited}s elapsed"
  fi
done
# A non-zero exit here means different things in the two modes.
#
# Remote build: the Kudu gateway routinely gives up (HTTP 504) while the build
# carries on server-side, so a failure is often cosmetic and worth riding out.
#
# With dependencies shipped, there is no remote build to rescue it: a failed
# upload means the new payload never landed -- and because the previous
# deployment is still running and still healthy, the health check below would
# sail through on stale code and report a success that never happened. Fail
# loudly instead.
if ! wait "$deploy_pid"; then
  echo "    Upload command failed. Azure said:" >&2
  sed 's/^/      /' "${UPLOAD_LOG}" | grep -v 'SyntaxWarning\|^\s*$' | tail -15 >&2
  if [[ "$VENDORED" == "1" ]]; then
    echo >&2
    echo "==> Dependencies ship with the code, so no remote build can rescue" >&2
    echo "    a failed upload: the new payload simply never landed." >&2
    echo "    The previously deployed code may still be serving traffic, so do" >&2
    echo "    not trust a green health check. Re-run the deploy." >&2
    exit 1
  fi
  echo "    (remote build mode: this is often a cosmetic gateway timeout;" >&2
  echo "     the build may still be running server-side. Continuing.)" >&2
fi

# Make the health check below capable of failing.
#
# Redeploying over a running app leaves the previous container serving traffic,
# so the health endpoint answers 200 the instant it is asked -- from the old
# code. `az webapp restart` is not enough: it returns immediately and the
# recycle happens asynchronously, so the poll still races the old container and
# reports "Healthy after 0s".
#
# Stop the site, wait until it genuinely stops answering, then start it again.
# `az webapp stop` returns before the platform has finished, and App Service
# keeps the previous worker serving while a replacement warms up, so neither a
# restart nor a bare stop guarantees the old container is gone. Observing a
# non-200 is the only reliable proof; see the loop below.
#
# This runs after the upload, never before it: the Kudu/SCM endpoint that
# receives the ZipDeploy is unreachable while the site is stopped, and in
# remote-build mode the Oryx build has to finish first.
#
# Skipped on a first-ever deploy, where there is no previous container to be
# fooled by and the site may not be running yet anyway.
URL="https://${APP_NAME}.azurewebsites.net"

# Close out the upload measurement before cycling the site, so the time spent
# waiting for the old container to die is not billed to the upload phase.
T_UPLOAD_SECS=$(( $(date +%s) - T_DEPLOY_START ))

if [[ "${APP_ALREADY_EXISTED:-0}" == "1" ]]; then
  echo "    Cycling the site so the health check tests the new payload, not the old one"
  az webapp stop --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" -o none 2>/dev/null || true

  # Wait for the site to actually go down before starting it again.
  #
  # Neither `az webapp restart` nor `az webapp stop` is enough on its own. Both
  # return before the platform has finished, and App Service deliberately keeps
  # the previous worker answering requests while a new one warms up -- that is
  # its zero-downtime behaviour. The result is a health endpoint that returns
  # 200 without interruption straight through a redeploy, which is exactly the
  # false "Healthy after 0s" this is meant to prevent.
  #
  # Observing a non-200 is the only proof the old container is genuinely gone,
  # so the timer below measures a real cold start of the new payload.
  down=0
  while (( down < 120 )); do
    dcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${URL}${HEALTH_PATH}" || true)"
    [[ "$dcode" != "200" ]] && break
    sleep 5
    down=$(( down + 5 ))
  done
  if (( down >= 120 )); then
    # Rather than silently measure the wrong thing, say so. The deploy itself is
    # fine; only the startup timing below is untrustworthy.
    echo "    WARNING: site still answering 200 after ${down}s of being stopped." >&2
    echo "    The startup time below may reflect the old container, not the new one." >&2
  else
    echo "    Site is down after ${down}s; starting it again"
  fi

  az webapp start --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" -o none 2>/dev/null || true
fi

echo "    Upload/deploy took ${T_UPLOAD_SECS}s"
echo "==> Waiting up to ${HEALTH_TIMEOUT}s for the app to come up at $URL"

elapsed=0
while (( elapsed < HEALTH_TIMEOUT )); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${URL}${HEALTH_PATH}" || true)"
  if [[ "$code" == "200" ]]; then
    echo "==> Healthy after ${elapsed}s."
    echo
    echo "    Timing: packaging $(( T_DEPLOY_START - T_PACKAGE_START ))s"
    echo "            upload/deploy ${T_UPLOAD_SECS}s"
    echo "            startup ${elapsed}s"
    echo "            TOTAL $(( $(date +%s) - T_PACKAGE_START ))s (from packaging)"
    echo
    echo "    Public URL: $URL"
    echo "    Live logs:  az webapp log tail --name $APP_NAME --resource-group $RESOURCE_GROUP"
    echo "    Teardown:   az group delete --name $RESOURCE_GROUP --yes --no-wait"
    exit 0
  fi

  # Fail fast. After repeated cold-start failures App Service gives up and stops
  # the site outright, at which point no amount of further polling will help.
  if (( elapsed > 0 && elapsed % 60 == 0 )); then
    state="$(az webapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
      --query state -o tsv 2>/dev/null || true)"
    if [[ "$state" == "Stopped" ]]; then
      echo "==> App Service stopped the site after repeated startup failures." >&2
      echo "    The container is crashing on boot. Most likely causes:" >&2
      echo "      - dependencies never installed (no antenv) -> 'No module named ...'" >&2
      echo "      - startup command points at the wrong file or port" >&2
      echo >&2
      echo "    az webapp log tail --name $APP_NAME --resource-group $RESOURCE_GROUP" >&2
      exit 1
    fi
  fi

  echo "    ${elapsed}s: HTTP ${code:-none}, retrying in 10s"
  sleep 10
  elapsed=$(( elapsed + 10 ))
done

echo "==> App did not become healthy within ${HEALTH_TIMEOUT}s. Check the logs:" >&2
echo "    az webapp log tail --name $APP_NAME --resource-group $RESOURCE_GROUP" >&2
exit 1

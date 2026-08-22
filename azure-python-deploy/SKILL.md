---
name: azure-python-deploy
description: Deploy a Python web application (Streamlit, Flask, FastAPI, or Gradio) to Azure App Service so it is publicly reachable on the internet over HTTPS. Use when the user says "deploy this to Azure", "put this app online", "host my Python app", "make this Streamlit app public", "azure app service", or asks how to spend their Visual Studio Enterprise Azure credit. Covers activating the Visual Studio Enterprise $150/month Azure credit, the Azure Command-Line Interface deploy sequence, running the deploy detached so a long build never blocks the conversation, shipping dependencies as prebuilt Linux wheels so the deploy takes about half as long, the framework-specific startup command and WebSocket settings that App Service does not set by default, the quota and virtual-environment failures that make a first deploy fail, live log debugging, cost guardrails, and one-command teardown. NOT for production services, which should not run on a personal Azure subscription.
---

# Deploy a Python web app to Azure App Service

Take a local Python web application and put it on the public internet with a
managed HTTPS URL, using the Azure Command-Line Interface only. Portal clicks
are deliberately avoided because they cannot be replayed.

## When this applies

Use for personal learning, prototypes, and demos on a Visual Studio Enterprise
Azure credit. **Do not** use it for production services, and do not put employer
code or data on a personal Azure subscription — the credit is a personal
dev/test benefit with no service level agreement.

## Step 0 — prerequisites

```bash
az version            # install with: brew install azure-cli
az account show       # if this errors, sign in (see below)
```

### Signing in

```bash
az login --use-device-code
```

Sign in with the **personal** Microsoft account that holds the credit, not a
work account. Then confirm the right subscription is selected:

```bash
az account show --query "{subscription:name, user:user.name, state:state}" -o table
az account list -o table                 # if several, pick the right one
az account set --subscription "<name-or-id>"
```

The target subscription is normally named **"Visual Studio Enterprise
Subscription"**.

### First time only — activating the Visual Studio Enterprise Azure credit

A Visual Studio Enterprise subscription includes a **$150 per month Azure
credit** for development and testing. If your employer provides Visual Studio
Enterprise, check your internal documentation for the activation path; the
general shape is:

1. Create a personal Microsoft account at `live.com` if you do not have one.
2. Sign in to `https://my.visualstudio.com` with your work account and confirm a
   *Visual Studio Enterprise* subscription is listed. If it is missing, ask
   whoever administers your licences to upgrade it.
3. On the Subscriptions tab, add the **personal** email as an alternate email.
4. Activate the Azure credit benefit.
5. Sign in to `portal.azure.com` with the **personal** account and confirm the
   subscription and credit balance appear.

Two properties worth knowing: a **$0 spending limit is on by default and no
credit card is required**, so exhausting the credit suspends the subscription
rather than billing anyone; and Visual Studio Enterprise often bundles free
Microsoft certification vouchers, which are worth checking for separately.

## Step 1 — verify the app runs locally first

Never debug a framework problem and a hosting problem at the same time.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m streamlit run app.py     # or the framework's own run command
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8501/
```

`requirements.txt` must exist and must pin versions. Without it the Azure build
installs nothing and the app crashes on its first import.

## Step 2 — deploy

Replace `APP_NAME` with a **globally unique** name; it becomes the hostname
`https://<APP_NAME>.azurewebsites.net`.

```bash
APP_NAME="my-unique-app-name"
RESOURCE_GROUP="rg-${APP_NAME}"
LOCATION="centralus"
PLAN_NAME="plan-${APP_NAME}"
SKU="B1"
RUNTIME="PYTHON:3.14"

az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az appservice plan create \
  --name "$PLAN_NAME" --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" --sku "$SKU" --is-linux

az webapp create \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" --runtime "$RUNTIME"

# Install dependencies here rather than on the server. The --platform flags are
# what make this work from an arm64 Mac: they fetch x86_64 Linux wheels instead
# of wheels for this machine. --only-binary is mandatory alongside them, because
# anything built from source would compile for the wrong architecture.
rm -rf .python_packages
pip install -r requirements.txt --target .python_packages/lib/site-packages \
  --platform manylinux_2_28_x86_64 \
  --platform manylinux_2_17_x86_64 \
  --platform any \
  --only-binary=:all: \
  --python-version 3.14 --no-compile

# Two settings, both required. Turning the server-side build off is the point;
# PYTHONPATH is what makes the shipped packages importable, because App Service
# does NOT add .python_packages to the path on its own (see the warning below).
az webapp config appsettings set \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false \
             PYTHONPATH=/home/site/wwwroot/.python_packages/lib/site-packages

# Configure BEFORE deploying. With no startup command the container falls back
# to gunicorn auto-detection, fails to boot, and every later step times out
# waiting on a site that was never going to start.
az webapp config set \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --web-sockets-enabled true \
  --always-on true \
  --startup-file "<STARTUP COMMAND — see the table below>"

# Zip the source AND the dependencies, excluding the local virtualenv and
# version control metadata. -1 is fastest compression: on a payload this size
# the extra minute of compression costs more than the bytes it saves.
ZIP="$(mktemp -t deploy-XXXXXX).zip"
zip -r -q -1 "$ZIP" . \
  -x '*.git*' -x '*.venv*' -x '*venv/*' -x '*__pycache__*' -x '*.pyc'

# Use config-zip, NOT `az webapp deploy`. See the warning below.
az webapp deployment source config-zip \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --src "$ZIP"

rm -f "$ZIP"

# Poll the health endpoint until it answers. Expect 000/503 for a minute or two
# while the container cold-starts.
```

Put every resource in one resource group. That makes teardown a single command
and makes it impossible to leave something running by accident.

**Why install dependencies locally rather than letting Azure do it?** It is
roughly twice as fast, and the slow part becomes your upload rather than a
remote `pip install` you cannot observe. Measured on a small Streamlit app over
a ~1 MB/s uplink:

| | Dependencies shipped (above) | Azure builds them |
|---|---|---|
| Local install | ~27s (warm pip cache) | — |
| Upload | ~303s for 128 MB | seconds (source only) |
| Azure-side | unpacking ~15,000 files | `pip install`, 8–14 min |
| **End to end** | **~6.5–8 min** | **~14 min** |

The upload dominates and is volatile — the same 128 MB payload took anywhere
from ~120s to ~303s across runs — so on a slow or congested connection the
advantage narrows. If your uplink is poor, or a dependency publishes no prebuilt
Linux wheel, use the fallback below.

### Never block the user while a deploy runs

A deploy takes **roughly 7 minutes** with dependencies shipped, and **8–15
minutes** if Azure builds them. Never run it in the foreground — the user is
left staring at a dead terminal and the agent cannot answer questions in the
meantime.

Run it detached and poll. `deploy.sh` in this skill's reference implementation
supports this directly:

```bash
./deploy.sh my-app --detach      # returns in under a second
./deploy.sh --status my-app      # progress, any time
```

`--status` exit codes are machine readable, so an agent can branch on them
without parsing text: **0** succeeded, **1** failed, **2** still running.

The mechanism is ordinary shell, so the same trick works for any long command:
re-exec under `nohup` writing to a log file, record the final exit status to a
`status` file from an `EXIT` trap, and read those two files to report progress.

**Agent guidance.** Launch the deploy detached, then poll roughly every 60–90
seconds, reporting each phase to the user as it changes (plan created → app
created → building → starting → healthy). Stop polling the moment `--status`
exits non-2, and report the public URL on success or the log tail on failure.
Do not hold the conversation open on a blocking call. If your harness offers a
background agent or a separate session, delegating the poll loop there is even
better — the point is that the user keeps an interactive assistant throughout.

**Polling must itself be non-blocking.** Detaching the deploy achieves nothing
if the agent then runs a 10-minute wait loop in the foreground. Each check
should be a single short command that reads the status file and returns
immediately. Never `sleep` for minutes inside a poll.

### App Service does NOT add `.python_packages` to the Python path

This is the one trap in shipping your own dependencies, and it is a nasty one
because **every command reports success**: the zip uploads, the deployment
completes, and only the container log shows the import error.

`.python_packages/lib/site-packages` is the Azure *Functions* convention. On App
Service, Oryx looks for a virtual environment named `antenv` or a package
directory named `__oryx_packages__`, finds neither, and the container dies
immediately with `No module named streamlit`. That is why Step 2 sets
`PYTHONPATH` explicitly. Both that and `SCM_DO_BUILD_DURING_DEPLOYMENT=false`
are required.

The other obstacle is architecture: a developer laptop is usually arm64 macOS
while App Service is x86_64 Linux, so a plain `pip install --target` produces
binaries the server cannot load. The `--platform` flags in Step 2 solve this by
resolving wheels for the *target* platform rather than the host. Details that
matter there:

- **`--only-binary=:all:` is mandatory** with `--platform`. Without it pip may
  build a package from source, which compiles for the wrong architecture and
  fails at import on the server.
- **Pass several `--platform` flags.** `manylinux2014` alone is too old for
  current pandas and numpy releases and resolution fails outright with
  `No matching distribution found`. Include `any` so pure-Python wheels resolve.
- **`--python-version` must match the App Service runtime**, since wheels are
  tagged per interpreter version (`cp314`).
- **Zip at the fastest compression level** (`-1`). A Streamlit app with pandas is
  roughly 340 MB, compressing to about 128 MB, most of it pyarrow. The time
  saved uploading smaller bytes does not pay for the extra compression.
- **It fails cleanly.** If any dependency has no prebuilt Linux wheel, pip errors
  before anything is uploaded rather than producing a broken deploy. Use the
  fallback below.

### Fallback — let Azure install the dependencies

Use this when a dependency has no prebuilt Linux wheel, or when your uplink is
slow enough that uploading a few hundred megabytes costs more than the ~8–14
minutes Azure spends on `pip install`.

Change three things in Step 2: turn the server-side build on, drop `PYTHONPATH`,
and skip the local install.

```bash
az webapp config appsettings set \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --settings SCM_DO_BUILD_DURING_DEPLOYMENT=true
```

Then zip only the source and deploy as before. Two behavioural differences:

- **Do not restart after deploying.** Oryx recycles the container itself once
  the build finishes; an early restart interrupts it.
- **An HTTP 504 from the upload is usually cosmetic here.** The gateway gives up
  but the server-side build carries on, so poll the health endpoint before
  concluding anything failed. This does *not* apply when you ship dependencies
  yourself — there, a failed upload means the payload never landed.

`deploy.sh` exposes this as `./deploy.sh my-app --remote-build --detach`.

### Never edit a shell script while it is running

Bash reads a script incrementally by byte offset as it executes. Editing the
file mid-run shifts the bytes underneath the running interpreter and it will
begin executing fragments of lines, producing baffling errors such as
`line 138: t: command not found`. If a fix is needed, let the run finish or kill
it first. A failure of this kind is an artifact of the edit, not a real bug —
do not "fix" the script in response to it.

This collides badly with detached deploys: a run lasts several minutes, which is
exactly long enough to want to improve the script while waiting. The fix is for
the parent to copy itself and exec the *copy*, so the child is immune to later
edits:

```bash
SNAPSHOT="${RUN_DIR}/deploy-snapshot.sh"
cp "$0" "$SNAPSHOT"
chmod +x "$SNAPSHOT"
_AZDEPLOY_CHILD=1 nohup "$SNAPSHOT" "$@" >> "$RUN_DIR/log" 2>&1 &
```

Any script that both detaches and runs for minutes should do this.

### A health check against a running app proves nothing after a redeploy

This one produced a completely false "success" and is worth internalising.

Deploying a *new* payload over an app that is already running and already
healthy means the health endpoint returns 200 the instant you ask it — from the
**old** code. If the upload silently failed, the sequence looks like this:

```
(upload returned non-zero; the remote build may still have succeeded)
Upload/deploy took 40s          <- far too fast for a 129 MB payload
Healthy after 0s.               <- the giveaway
TOTAL 73s
```

Every line says success. Nothing was deployed. The 200 came from the previous
deployment, which never stopped serving.

Three defences, all of which belong in any redeploy script:

1. **Do not discard the upload command's output.** Redirecting to
   `>/dev/null 2>&1` to keep the log tidy also throws away the only description
   of the failure. Send it to a file and print it when the command fails.
2. **Prove the old container is gone before timing anything.** This is harder
   than it looks. `az webapp restart` returns immediately and recycles
   asynchronously. `az webapp stop` also returns early. Worse, App Service
   deliberately keeps the previous worker answering requests while a
   replacement warms up — that is its zero-downtime behaviour — so the health
   endpoint can return an unbroken series of 200s straight through a redeploy.
   The only reliable proof is to **observe a non-200**: stop the site, poll
   until it stops answering, then start it and time the recovery. If it never
   stops answering, say the measurement is untrustworthy rather than reporting
   it.
3. **Treat a failed upload as fatal when there is no remote build to rescue
   it.** The "an HTTP 504 here is cosmetic" rule is true *only* for remote
   builds, where the gateway gives up but the server-side build continues. In
   the default path, where dependencies ship with the code, a failed upload
   means the payload never landed, full stop.

The general principle: a post-deploy check must be capable of *failing*. If the
check would have passed before you deployed anything, it is not a check.
`Healthy after 0s` is almost always a bug, not a fast deploy.

### Do not use `az webapp deploy` for Python

`az webapp deploy` (the OneDeploy endpoint) reports `Deployment successful` with
`Errors (0)` and yet never creates the `antenv` virtual environment, so nothing
in `requirements.txt` is installed. The container then crash-loops on
`No module named streamlit`, while the deployment log insists everything is
fine. This is the single most misleading failure in the whole process.

Use the classic ZipDeploy endpoint instead, which builds `antenv` correctly:

```bash
az webapp deployment source config-zip -n "$APP_NAME" -g "$RESOURCE_GROUP" --src "$ZIP"
```

A `504 GatewayTimeout` from this command is normal on a slow build and does not
mean failure — the gateway simply stopped waiting. Poll the health endpoint for
the real answer.

### Do not use `az webapp up`

It looks like the obvious one-shot command, and it is a trap here. It creates the
app and immediately blocks for ten minutes waiting for a healthy site — but it
writes no usable startup command for Streamlit or Gradio, so the container can
never become healthy and the command always fails. Create, configure, then deploy
as separate steps.

### If `az appservice plan create` fails on quota

A brand-new Visual Studio Enterprise subscription starts with **zero virtual
machine quota** in most regions:

```
Operation cannot be completed without additional quota.
Current Limit (Total VMs): 0
```

B1 and above are dedicated virtual machines, so they need that quota. The fix is
almost always to pick a different region rather than to file a quota request —
availability varies per region and per subscription. Probe them:

```bash
for LOC in centralus eastus westus westus3 eastus2; do
  echo "--- $LOC ---"
  az appservice plan create --name probe-$LOC --resource-group "$RESOURCE_GROUP" \
    --location $LOC --sku B1 --is-linux -o none 2>&1 | grep -q "additional quota" \
    && echo "  no quota" \
    || { echo "  *** works in $LOC ***"; \
         az appservice plan delete --name probe-$LOC -g "$RESOURCE_GROUP" --yes; break; }
done
```

As of the last run, `centralus` had quota while `westus2`, `eastus` and `westus`
did not. If every region is blocked, `--sku F1` (free) does not draw on virtual
machine quota, but it cannot enable Always On and imposes a 60 minute per day
processor quota — treat it as a fallback, not the recommendation.

### Startup command by framework

App Service routes external traffic to **port 8000** inside the container. No
Python framework defaults to that port, so the startup command must set it
explicitly. This is the single most common cause of a failed deployment.

| Framework | `--startup-file` value |
|---|---|
| Streamlit | `python -m streamlit run app.py --server.port 8000 --server.address 0.0.0.0 --server.headless true` |
| Gradio | `python app.py` with `demo.launch(server_name="0.0.0.0", server_port=8000)` in the code |
| FastAPI | `python -m uvicorn main:app --host 0.0.0.0 --port 8000` |
| Flask | `python -m gunicorn --bind 0.0.0.0:8000 app:app` (add `gunicorn` to `requirements.txt`) |

### Why `--web-sockets-enabled true`

App Service does **not** enable WebSockets by default. Streamlit and Gradio hold
a long-lived WebSocket open for every widget interaction. Without this flag the
page loads and looks fine but nothing reacts — a confusing failure that looks
like an application bug rather than a hosting setting. Flask and FastAPI apps
that only serve plain HTTP do not need it, but setting it is harmless.

### Why `--always-on true`

Without it App Service idles the app out after roughly 20 minutes and the next
visitor waits through a cold start. Always On requires the **B1** tier or above;
it is unavailable on the free F1 tier.

## Step 3 — verify it is genuinely public

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://${APP_NAME}.azurewebsites.net/"
```

For Streamlit there is a dedicated health endpoint that returns `ok`:

```bash
curl -s "https://${APP_NAME}.azurewebsites.net/_stcore/health"
```

The first request after a deploy can take one to two minutes while dependencies
install. Poll rather than concluding failure from a single attempt. Also open
the URL in a browser and interact with a widget — a 200 response only proves
HTTP works, not that the WebSocket does.

## Step 4 — debugging a failed start

```bash
az webapp log tail --name "$APP_NAME" --resource-group "$RESOURCE_GROUP"
```

| Symptom | Cause |
|---|---|
| Container did not respond on port 8000 | Startup command missing or wrong port |
| `No module named <framework>` **and** `Could not find virtual environment directory /home/site/wwwroot/antenv` | Deployed with `az webapp deploy` instead of `config-zip`. The build reports success but installs nothing. Redeploy with `az webapp deployment source config-zip`. |
| `No module named <framework>`, **both** `antenv` **and** `__oryx_packages__` reported missing, | `PYTHONPATH` was not set. App Service does not read `.python_packages` — that is the Azure Functions convention. Set `PYTHONPATH=/home/site/wwwroot/.python_packages/lib/site-packages`. Everything else reports success, so this is easy to misread as a slow build. |
| `ModuleNotFoundError` | `SCM_DO_BUILD_DURING_DEPLOYMENT` not set, or package missing from `requirements.txt` |
| Page renders but widgets do nothing | WebSockets not enabled |
| Works, then is slow after idling | Always On not enabled, or on the free F1 tier |
| `az webapp create` fails on the name | Name is not globally unique |
| `504 GatewayTimeout` during deploy | Normal on a slow build. The gateway stopped waiting; the build continues. Poll health instead. |
| Endpoint returns 503 forever, `az webapp show --query state` is `Stopped` | App Service gave up after repeated cold-start failures. The container is crashing — read the startup log, do not keep polling. |
| `line NNN: <fragment>: command not found` | The script was edited while running. Not a real bug. |

Two commands worth knowing when a container will not start:

```bash
# Definitive: did Azure give up on the site entirely?
az webapp show -n "$APP_NAME" -g "$RESOURCE_GROUP" --query state -o tsv

# The actual crash reason, including the Oryx/antenv diagnosis
az webapp log download -n "$APP_NAME" -g "$RESOURCE_GROUP" --log-file /tmp/logs.zip
unzip -o -q /tmp/logs.zip -d /tmp/logs && tail -40 /tmp/logs/LogFiles/StartupLogs/*_failure.log
```

The downloaded `*_failure.log` is far more useful than `az webapp log tail`,
which often attaches too late to catch the crash.

## Step 5 — secrets and configuration

Never commit secrets. App Service injects app settings as environment variables:

```bash
az webapp config appsettings set \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --settings MY_API_KEY="..." ANOTHER_SETTING="..."
```

Read them with `os.environ.get("MY_API_KEY")`. App Service also sets
`WEBSITE_SITE_NAME` and `REGION_NAME` on every instance, which is a reliable way
for code to detect it is running on Azure rather than locally.

**A `*.azurewebsites.net` app is open to the entire internet with no
authentication.** Put nothing sensitive in a demo. To add a login later, use App
Service's built-in authentication feature ("Easy Auth").

## Step 6 — cost control and teardown

**The plan is what costs money, not the app.** A B1 Linux plan is about $13 per
month and it bills continuously from the moment it is created — whether or not
an app is running on it, and whether or not anyone visits. Against a $150
monthly credit that is roughly 9% per plan.

The trap: the naive pattern of one resource group with one plan per app means
three experiments quietly cost ~$39 per month. An App Service plan is a rented
virtual machine that can host **many** apps, so for extra apps reuse the plan
instead of creating another:

```bash
# Reuse an existing plan for a second app — no additional cost
az webapp create --name "another-app" \
  --resource-group "$RESOURCE_GROUP" --plan "$PLAN_NAME" --runtime "$RUNTIME"
```

Keep one throwaway plan for experiments and put every test app on it. Note that
apps on one plan share its processor and memory, so keep real workloads separate.

```bash
# What exists and what is actually billing
az webapp list -o table
az appservice plan list --query "[].{name:name,sku:sku.name,apps:numberOfSites}" -o table

# Complete teardown — removes the app, the plan, and everything else
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

Because every resource lives in one resource group, that single command is a
guaranteed-complete cleanup.

**Delete a test deployment the moment it has proven its point.** Verification
apps created while debugging are the easiest thing to forget, and each one is a
recurring charge. Tearing down is a single non-blocking command, so there is
never a reason to leave one running.

## Alternative: Azure Container Apps

If the app should **scale to zero** and cost almost nothing while idle, or needs
to be a container for portability, use Azure Container Apps instead. It builds
remotely, so Docker is not needed locally:

```bash
az containerapp up --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" --source . --ingress external --target-port 8000
```

Trade-off: cheaper when idle and a more transferable skill, but adds cold starts
and more concepts. App Service is the better first stop for learning.

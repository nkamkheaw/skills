---
name: azure-python-deploy
description: Deploy a Python web application (Streamlit, Flask, FastAPI, or Gradio) to Azure App Service so it is publicly reachable on the internet over HTTPS. Use when the user says "deploy this to Azure", "put this app online", "host my Python app", "make this Streamlit app public", "azure app service", or asks how to spend their Visual Studio Enterprise Azure credit. Covers the Azure Command-Line Interface deploy sequence, the startup command and WebSocket settings App Service does not set by default, the silent failures that make a first deploy fail, running the deploy detached so a long build never blocks the conversation, debugging a container that will not start, and teardown. NOT for production services, which should not run on a personal Azure subscription.
---

# Deploy a Python web app to Azure App Service

Put a local Python web app on the public internet with a managed HTTPS URL,
using the Azure Command-Line Interface only (portal clicks cannot be replayed).

`deploy.sh` in this directory is a working implementation of everything below.

## Step 0 — prerequisites

```bash
az version || brew install azure-cli
az login                       # use the account that owns the subscription
az account show -o table       # confirm the right subscription is active
az account set --subscription "<NAME OR ID>"
```

A Visual Studio Enterprise subscription includes a **$150/month Azure credit**
for dev/test. To activate: create a personal Microsoft account, sign in to
`my.visualstudio.com` with your work account, add the personal address as an
alternate email, activate the Azure benefit, then sign in to `portal.azure.com`
with the **personal** account. A $0 spending limit is on by default and no
credit card is required, so exhausting the credit suspends rather than bills.

## Step 1 — run it locally first

Never debug a framework problem and a hosting problem at the same time.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m streamlit run app.py
```

`requirements.txt` must exist and pin versions, or the app crashes on first import.

## Step 2 — deploy

`APP_NAME` must be **globally unique**; it becomes
`https://<APP_NAME>.azurewebsites.net`. Keep everything in one resource group so
teardown is a single command.

```bash
APP_NAME="my-unique-app-name"
RESOURCE_GROUP="rg-${APP_NAME}"
LOCATION="centralus"
PLAN_NAME="plan-${APP_NAME}"

az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az appservice plan create --name "$PLAN_NAME" --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" --sku B1 --is-linux

az webapp create --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" --runtime "PYTHON:3.14"

# Install dependencies locally as x86_64 Linux wheels. --only-binary is
# mandatory with --platform: anything built from source targets this machine.
rm -rf .python_packages
pip install -r requirements.txt --target .python_packages/lib/site-packages \
  --platform manylinux_2_28_x86_64 --platform manylinux_2_17_x86_64 \
  --platform any --only-binary=:all: --python-version 3.14 --no-compile

# Both required: disable the server-side build, and put the shipped packages on
# the path — App Service does NOT add .python_packages by itself.
az webapp config appsettings set --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false \
             PYTHONPATH=/home/site/wwwroot/.python_packages/lib/site-packages

# Configure BEFORE deploying. With no startup command the container falls back
# to gunicorn auto-detection and never boots.
az webapp config set --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --web-sockets-enabled true --always-on true \
  --startup-file "<see table below>"

# -1 is fastest compression; on this payload compressing harder costs more time
# than the bytes save.
ZIP="$(mktemp -t deploy-XXXXXX).zip"
zip -r -q -1 "$ZIP" . -x '*.git*' -x '*.venv*' -x '*venv/*' -x '*__pycache__*' -x '*.pyc'

# config-zip, NOT `az webapp deploy` — see traps.
az webapp deployment source config-zip \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --src "$ZIP"
rm -f "$ZIP"
```

Then poll the health endpoint; expect `000`/`503` for a minute or two of cold start.

### Startup command by framework

App Service routes traffic to **port 8000** inside the container and no Python
framework defaults to it. A wrong or missing startup command is the single most
common cause of a failed deploy.

| Framework | `--startup-file` |
|---|---|
| Streamlit | `python -m streamlit run app.py --server.port 8000 --server.address 0.0.0.0 --server.headless true` |
| FastAPI | `python -m uvicorn main:app --host 0.0.0.0 --port 8000` |
| Flask | `python -m gunicorn --bind 0.0.0.0:8000 app:app` (add `gunicorn` to requirements) |
| Gradio | `python app.py`, with `demo.launch(server_name="0.0.0.0", server_port=8000)` |

`--web-sockets-enabled true` is off by default; Streamlit and Gradio need it for
every widget, and without it the page renders but nothing reacts.
`--always-on true` avoids a cold start after ~20 idle minutes and needs B1+.

## Traps

These all report success while doing nothing useful.

1. **`az webapp deploy` never builds the virtual environment for Python.** It
   prints `Deployment successful` and creates no `antenv`, so nothing installs.
   Use `az webapp deployment source config-zip`.
2. **`az webapp up` writes an empty startup command** and overwrites yours.
   Never use it.
3. **`.python_packages` is the Azure *Functions* convention, not App Service.**
   Shipping wheels there without setting `PYTHONPATH` yields
   `No module named ...` while every command reports success.
4. **A health check after a redeploy cannot fail.** App Service keeps the old
   worker serving while the replacement warms up, so health returns unbroken
   200s straight through. To verify a *new* payload, stop the site, poll until
   it returns non-200, then start it. And start any stopwatch **before**
   `az webapp start` — that call blocks until the site is running, so timing
   only what follows it reports `0s`.
5. **A 504 during `config-zip` is only cosmetic with a server-side build**,
   where the gateway gives up but the build continues. With dependencies shipped
   in the zip, a failed upload means the payload never landed.

### If `az appservice plan create` fails on quota

New Visual Studio Enterprise subscriptions have **zero virtual machine quota**
in most regions (`Current Limit (Total VMs): 0`). B1+ are dedicated virtual
machines, so they need it. Switching region is almost always faster than filing
a quota request — `centralus` had quota when `eastus`, `westus` and `westus2`
did not. `--sku F1` needs no quota but cannot enable Always On.

### Do not block the conversation while deploying

A deploy takes several minutes. Run it detached (`nohup` to a log file, final
exit status written to a `status` file from an `EXIT` trap), then poll with a
single short command that returns immediately. Never `sleep` for minutes in the
foreground — detaching achieves nothing if the poll loop blocks instead.
`deploy.sh --detach` and `deploy.sh --status <app>` do this; `--status` exits
0 success / 1 failed / 2 running so it is easy to branch on.

Also: **editing a shell script while it is running corrupts it**, because bash
reads by byte offset. Snapshot the script before launching a long run.

### Fallback — let Azure install the dependencies

If your uplink is slow or a dependency has no prebuilt Linux wheel, skip the
local `pip install`, set `SCM_DO_BUILD_DURING_DEPLOYMENT=true`, drop the
`PYTHONPATH` setting, and zip the source only. Azure then runs `pip install`
server-side. Simpler and a much smaller upload, but roughly twice as slow
end to end and you cannot watch the build.

## Step 3 — verify it is public

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://${APP_NAME}.azurewebsites.net/"
curl -s "https://${APP_NAME}.azurewebsites.net/_stcore/health"   # Streamlit
```

Also open it in a browser and click something: a 200 proves HTTP works, not the
WebSocket.

## Step 4 — debugging a failed start

```bash
# Did Azure give up on the site entirely?
az webapp show -n "$APP_NAME" -g "$RESOURCE_GROUP" --query state -o tsv

# The actual crash reason — better than `log tail`, which attaches too late
az webapp log download -n "$APP_NAME" -g "$RESOURCE_GROUP" --log-file /tmp/logs.zip
unzip -o -q /tmp/logs.zip -d /tmp/logs && tail -40 /tmp/logs/LogFiles/StartupLogs/*_failure.log
```

| Symptom | Cause |
|---|---|
| Container did not respond on port 8000 | Startup command missing or wrong port |
| `No module named X` + `Could not find virtual environment directory .../antenv` | Deployed with `az webapp deploy`; redeploy with `config-zip` |
| `No module named X`, both `antenv` and `__oryx_packages__` missing | `PYTHONPATH` not set |
| `ModuleNotFoundError` | Package missing from `requirements.txt` |
| Page renders but widgets do nothing | WebSockets not enabled |
| Slow after idling | Always On off, or on F1 |
| `az webapp create` fails on the name | Name not globally unique |
| 503 forever and `state` is `Stopped` | Azure gave up after repeated crash loops — read the log, stop polling |
| `line NNN: <fragment>: command not found` | The script was edited while running |

## Step 5 — secrets

```bash
az webapp config appsettings set --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --settings MY_API_KEY="..."
```

Read with `os.environ.get("MY_API_KEY")`. App Service also sets
`WEBSITE_SITE_NAME`, a reliable way to detect it is running on Azure.

**An `*.azurewebsites.net` app is open to the whole internet with no
authentication.** Put nothing sensitive in a demo; add App Service
authentication ("Easy Auth") if you need a login.

## Step 6 — cost and teardown

**The plan costs money, not the app.** A B1 Linux plan is ~$13/month and bills
from creation whether or not anything runs on it — about 9% of a $150 credit,
each. One plan can host many apps, so reuse it rather than creating another:

```bash
az webapp create --name "another-app" --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" --runtime "PYTHON:3.14"

# What is actually billing
az appservice plan list --query "[].{name:name,sku:sku.name,apps:numberOfSites}" -o table

# Complete teardown
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

Delete test deployments as soon as they have proven their point — they are the
easiest thing to forget and each one is a recurring charge.

**Alternative:** if the app should scale to zero and cost nothing while idle,
use `az containerapp up --source . --ingress external --target-port 8000`
instead. Cheaper idle, but adds cold starts and more concepts.

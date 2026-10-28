# Two hospitals and central, each its own MaHIS installation

This folder runs the sync prototype the way it would be deployed: Kamuzu
Central Hospital (KCH), Zomba Central Hospital (ZCH) and central are each an
independent MaHIS installation with its own database, API and, for the
hospitals, the MaHIS web app and a sync agent. Nobody runs scripts during
use: staff work in the MaHIS web app and sync happens in the background.

| What | Address |
|---|---|
| Central dashboard | <http://localhost:4200/api/v1/site_sync/admin/dashboard?token=demo-admin-token> |
| KCH, MaHIS web app | <http://localhost:8201> (its API: port 4201) |
| ZCH, MaHIS web app | <http://localhost:8202> (its API: port 4202) |

Log in to either hospital with your usual dev MaHIS username and password:
every server starts from a copy of your dev database, with all its users
moved to that hospital.

## Containers

| Container | Role |
|---|---|
| `central-db`, `central-redis`, `central-api` | Central: national copy, validation, dashboard |
| `central-agent` | Captures and publishes central's *own* data changes -- central is a facility-like server too, not only a hub (see `../README.md`'s "Choices worth knowing") |
| `kch-db`, `kch-redis`, `kch-api`, `kch-web`, `kch-agent` | KCH: its own MySQL, MaHIS API, web app, sync agent |
| `zch-…` | The same for ZCH |
| `*-init` | Run once at first start: sync tables, capture triggers, the first full copy to central, database accounts. Then they exit. |

Hospitals reach central only over the `wan` network. Each hospital's API
runs as the restricted `mahis_app` MySQL account, its agent as `mahis_sync`.
**Central's api is the exception and still runs as `root`** -- the
`mahis_app`/`mahis_sync` privilege split assumes the app account only ever
reads sync tables, which doesn't hold for central's own request-handling
code (see the design doc's "Choices worth knowing" for why).

## Start and stop

Needs Docker Desktop (with WSL integration) and two things built once:

```bash
# 1. The MaHIS data to start from (once; also used by the scripted demo)
cd ~/projects/MAHIS/MaHIS-Core && prototype/site_sync/bin/setup
# 2. The MaHIS web app
cd ~/projects/MAHIS/MAHIS && npx vite build --base=/

cd ~/projects/MAHIS/MaHIS-Core/prototype/site_sync/docker
docker compose up -d --build     # first start ~10 min: each database loads the MaHIS data
docker compose ps                # all running; the *-init containers "exited (0)"
docker compose down              # stop; data is kept
docker compose down -v           # stop and delete all data (next start is fresh)
```

Everything can also be started, stopped and watched from Docker Desktop's
Containers view (the `mahis-sync` group).

## Showing it

1. Open the dashboard and both hospitals side by side. Both show as active
   with their real names; each has sent its existing records to central.
2. At KCH, register a patient and record vitals. Within seconds the
   dashboard's counts rise; central has the patient.
3. Take ZCH offline and keep working there:
   `./network.sh ZCH off` (or, in Docker Desktop, pause `zch-agent`). The
   dashboard's "Unsent" for ZCH grows. Bring it back (`./network.sh ZCH on`)
   and the queue drains.
4. A patient from KCH walks into ZCH: ZCH fetches them from central (a
   referral). Edits at either hospital then reach the other.

The scripted fault scenes (power cut, tampering, corruption, restore) stay in
`prototype/site_sync/demo` and run against the non-Docker setup.

For a live audience, `tools/sync-flow-monitor.html` is a visual companion to
the steps above: open it as a local file (not linked to this repo's own
dashboard page) and it polls central's dashboard JSON directly from the
browser, animating each push, pull, correction and conflict as it happens.
It has its own legend mapping each test scenario to what to watch for.

## Mutual TLS (not on by default)

Sync requests are already authenticated with an HMAC signature from the
site's secret (`Client.signature`), which is enough to run safely today.
Mutual TLS adds a second, transport-level layer -- not wired into this
`docker-compose.yml` by default, since it changes the network topology
between the agents and central and this demo stack is otherwise working.
To turn it on:

1. Generate a CA and one client certificate per site:
   ```bash
   bin/rails runner -e development "nil" # ensure the app loads once first
   rake site_sync:tls:ca
   rake site_sync:tls:issue[KCH]
   rake site_sync:tls:issue[ZCH]
   ```
2. Put `nginx-mtls/central.conf` in front of `central-api` (a new compose
   service on the `central` and `wan` networks, with `ca.crt` + a server
   cert/key mounted at `/etc/nginx/tls/`), and remove `central-api` from the
   `wan` network so sites can only reach it through that proxy.
3. Point each site's `SITE_SYNC_CENTRAL_URL` at `https://central-tls:8443`
   instead of `http://central-api:3000`, and set `SITE_SYNC_TLS_CERT`,
   `SITE_SYNC_TLS_KEY` (that site's issued cert/key) and `SITE_SYNC_TLS_CA`
   (`ca.crt`) on its `*-agent` service.
4. Set `SITE_SYNC_MTLS_REQUIRED=1` on `central-api` so it refuses any sync
   request whose verified cert CN doesn't match the claimed site code.

## Settings

Defaults suit a demo; set them in a `.env` file next to `docker-compose.yml`:
`DB_ROOT_PASSWORD`, `KCH_SECRET`, `ZCH_SECRET`, `SITE_SYNC_ADMIN_TOKEN`,
`SITE_SYNC_SECRET_ENCRYPTION_KEY` (encrypts `sync_sites.secret` at rest --
must be the same value everywhere central-init and central-api run, see the
comment in `docker-compose.yml`), `KCH_LOCATION_ID` / `ZCH_LOCATION_ID`
(must match the real facility, used to derive each site's display name),
`SITE_SYNC_PUSH_EVERY` (default 5 s; production 30), `SITE_SYNC_PULL_EVERY`
(10 s; production 120), `SITE_SYNC_HEARTBEAT_EVERY` (15 s; production 300),
`SITE_SYNC_RECONCILE_EVERY` (60 s, so the demo actually shows a run without
waiting a day; production default is 24h), `SITE_SYNC_MAX_BACKOFF` (30 s cap
on retry backoff after a failed push/pull), `SITE_SYNC_PUBLISH_LOCAL_EVERY`
(5 s; how often `central-agent` checks for central's own new changes to
publish), `MAHIS_DUMP` (the starting data), `MAHIS_WEB_DIST` (the built web
app).

## Not a production template

This layout is for demos and local testing only. Before anything here is
pointed at a real site or server:

- **Central's api connects to its database as `root`**, not a restricted
  account like the sites' `mahis_app`/`mahis_sync` -- deliberately, for now:
  the sites' privilege model doesn't fit central's api (it writes sync
  bookkeeping tables directly as part of handling requests; see `../README.md`).
  Central needs its own scoped account with its own tailored grants, not a
  copy of the site one.
- **Default passwords and secrets are public in this file**
  (`DB_ROOT_PASSWORD` defaults to `root`; `mahis_app`/`mahis_sync` passwords
  are `app`/`sync` from `db-init/00-accounts.sql`; the site secrets and
  `SITE_SYNC_SECRET_ENCRYPTION_KEY` are `*-demo-secret-change-me-...`/
  `demo-secret-cipher-key-change-me-...`). All of these must be replaced.
- **Ports are bound to `127.0.0.1` only** so this demo isn't reachable from
  the rest of the network; a real deployment needs its own access control
  in front of these services, not just a different bind address.
- **Rails runs with `RAILS_ENV=development`** and a 64 MB InnoDB buffer pool,
  sized for three containers sharing one laptop, not a hospital server.
- **`site-init.sh` runs with `DEMO=1` by default**, which pins every
  bootstrap user to the site's one facility and gives the demo admin a
  fixed, long-lived token. Set `DEMO=0` for anything other than this demo;
  a real site seeds its own users properly instead.

# Two-way site ↔ central sync: prototype

A working prototype of the design in *MaHIS Two-Way Site–Central Synchronization*.
Two sites and central are full MaHIS-Core instances (same codebase, different
`MAHIS_SYNC_ROLE`); the demo drives them through the real MaHIS API and
checks the result on all three databases.

Scope: `person`, `patient`, `person_name`, `patient_identifier`, `encounter`,
`obs`, `visit`, `orders`, `patient_program`, `person_address`,
`person_attribute`, `relationship`. Reference data (concepts, users,
locations, programs, visit/order/relationship types) is seeded identically
on every node and not synced yet -- columns pointing at it travel as a uuid
and are matched by uuid on the receiving node (`reference_refs` in
`config/site_sync_tables.yml`).

Not yet in scope, found when the table list was last widened: `drug_order`
and `patient_state` have no direct `patient_id`/`person_id` of their own --
only a one-hop indirect path (`drug_order.order_id` -> `orders.patient_id`;
`patient_state.patient_program_id` -> `patient_program.patient_id`) that
`Codec.patient_uuid`/`patient_ref` doesn't currently resolve. Several other
candidate tables (`active_list*`, `pharmacy_obs`, `national_id`,
`merged_patients`, and others) have no `uuid` column at all, or one with no
unique index, which this uuid-keyed system depends on -- each needs its own
migration or keying approach before it can join.

## Run it

Needs WSL/Linux with MySQL 8 server binaries, Ruby (rbenv) and the app's gems.
Nothing touches your main MySQL: the prototype starts its own on port 3307,
with data under `tmp/site_sync_mysql/`.

```bash
cd MaHIS-Core
SOURCE_PASSWORD=... prototype/site_sync/bin/setup   # copies your dev DB into 3 databases (once)
prototype/site_sync/bin/start                       # central :3200, site A :3201, site B :3202, links, agents
bundle exec ruby prototype/site_sync/demo/run.rb    # all scenes; or name one: ... run.rb conflict
prototype/site_sync/bin/stop
```

Dashboard: <http://127.0.0.1:3200/api/v1/site_sync/admin/dashboard?token=demo-admin-token>

Link control while it runs: `bin/link A cut | restore | slow 256 | drop-acks`.

Demo scenes: `live`, `offline`, `power_cut`, `lost_ack`, `conflict`,
`quarantine`, `void`, `tamper`, `clock`, `reconcile`, `restore`, `measure`.

### Or: the Docker deployment

`prototype/site_sync/docker/` runs the same code as three full, independent
MaHIS installations (central, KCH, ZCH, each its own database, API and --
for the hospitals -- web app and sync agent), driven through the real MaHIS
web app rather than the API directly. This is what demos and stakeholder
walkthroughs actually use; see `docker/README.md`. A live visual companion
for a demo is `docker/tools/sync-flow-monitor.html` (open it as a local
file; it polls the dashboard JSON directly from the browser).

## Results (last full run, 14 Oct 2026, laptop under WSL)

**63 of 64 checks passed** (15 Oct 2026, after both code reviews). Every sync
scene behaved as designed; the one miss is the capture-overhead target (see
below).

| Scene | What was shown |
|---|---|
| live | Patient + visit saved through the MaHIS API reached central in 1.1 s; each change is tagged with its endpoint, request id and user |
| offline | Work continued with the link cut; the queue drained in order when it came back, no gaps, each batch applied once |
| power_cut | Central died after applying a batch but before COMMIT: nothing half-applied, sequence unchanged; the resend applied it exactly once |
| lost_ack | Central committed but the answer was lost; the resend got central's stored answer and nothing was applied twice |
| conflict | Two offline sites edited different fields of one name: both edits survived on all three nodes. A birth date changed at both went to review |
| quarantine | A visit dated in the future was quarantined with its observations (same request) while other data kept flowing; fixing the date at the site released all three |
| void | Patient registered and voided while offline: central has it voided, with reason and user |
| tamper | KCH's API runs as the restricted `mahis_app` account and its saves are still captured (triggers run as `mahis_sync`); that account cannot delete queued changes; a batch edited after sealing was refused with an alert; a replayed or altered signed request was refused |
| clock | KCH's clock jumped a year ahead: its changes were still accepted, capped at central's time with an alert, and later changes flowed normally |
| reconcile | Two rows corrupted behind the app's back were found by Merkle comparison (8 KB exchanged). The deleted row came back automatically; the changed row was held until a data officer approved the repair |
| restore | ZCH wiped and rebuilt from central: a first attempt was cut off part-way (logins refused meanwhile), the second resumed and finished; exact checksums verified, same local ids, new server generation; the old server stays locked out |

| Measurement | Value |
|---|---|
| KCH → central lag (demo push interval 2 s) | 0.6 s |
| Bytes per change, gzip (as sent) | 137 B (1 512 B uncompressed; foreign keys travel as uuids) |
| Changes per minute a 256 kbit/s link carries at the 50% cap | ~7 000 |
| Rollout snapshot, 2 sites × ~1 000 rows | 35 s |
| Reconciliation, 6 tables with 2 damaged rows | 1.2 s, 7.7 KB exchanged |
| Capture overhead, visit + 20 obs (committed) | **not settled**: 6.5% to 88% across runs |

**Capture overhead is not settled.** Runs on the same laptop measured anywhere
from 6.5% to 88% (28.7% in the latest): disk timing under WSL varies too much
(one configuration ranged from 44 ms to 301 ms per save). Measure it on a real
site server with `rake site_sync:benchmark` (stop the agent first).

## Known limits of the prototype

- **One lock at central.** Batches from all sites are applied one at a time so
  the downstream feed stays in commit order. A large catch-up from one site
  delays the others (seen during the rollout snapshot); production should use a
  committed-watermark instead.
- **Reference data is not synced.** Concepts, drugs, users, locations and
  programs must exist on every node. They are matched by uuid, so their integer
  ids may differ, but **their uuids must not**: central must own the concept
  dictionary and every site must be seeded from it. Installations seeded
  separately may carry different uuids (`bin/generate_concept_mapping.rb` had to
  match concepts by name); their changes would be quarantined as
  `unknown_reference_data`, which is visible and safe, but stops their data.
  Syncing reference data from central is the follow-up that guarantees this.
- **Out-of-scope columns** (`visit_id`, `order_id`, `form_id`, `value_group_id`)
  are kept in central's backup copy but not copied to other nodes.
- **HMAC signatures instead of mutual TLS**, and a demo API token instead of
  the login flow. Signatures cover the full URL, a timestamp and a one-time
  nonce; central refuses a repeated nonce (kept 90 days) and anything signed
  more than 89 days ago. There is deliberately no tight time window, because a
  site whose clock runs ahead must still be able to sync. The nonce table gets
  about 3 500 rows a day per site; production should partition it by day and
  drop old partitions.
- **Hard deletes.** `site_sync:check` flags three hard deletes in
  `DuplicateIdentifierCleanupTask`. They are still captured (as tombstones) but
  should become voids.
- **Restore speed on a real-sized site is not measured.** Restore writes each
  page of rows in one statement and resumes after an interruption, but the demo
  has only about 1 000 rows. Time it on a copy of a real site before quoting the
  8-hour target.
- **Few automated tests.** The demo checks run against live servers. Only the
  HLC and Merkle helpers have specs; central ingest and the site applier need
  them before the pilot.

## Choices worth knowing

- **Sequence numbers are given out when a batch is sealed, not inside the
  trigger.** No clinical save waits on a shared counter. Order stays correct:
  two changes to one row are ordered by MySQL's row lock, and a row cannot
  reference a parent that is not yet committed, so the parent is always sealed
  first.
- **Rows a site received from central travel back up**, marked `replica`.
  Central only stores them in its backup copy of the site, so a restore
  returns pulled patients with the site's own local ids. It costs extra
  upstream traffic for referred patients.
- **Quarantined rows still go into central's backup copy.** Quarantine keeps them
  out of the national data, not out of the site's backup, so reconciliation
  does not flag them every night.
- **Reconciliation never overwrites a row that differs on both sides on its
  own.** Missing rows are repaired automatically; a row that differs is held
  for a data officer, who settles each row:
  `rake site_sync:reconcile REPAIR_CENTRAL=<uuid>,<uuid> REPAIR_SITE=<uuid>`
  (central's copy is right / the site's copy is right), or all held rows at
  once with `REPAIR_DIFFERENT=central|site`.
- **A site clock that runs ahead is capped, not refused.** Central stamps such
  changes with its own current time (not time plus the allowed margin, which
  would let them beat genuine edits from other sites), raises an alert, and
  sends any conflict they cause to review. The site resets its stored clock
  from central's time.
- **Restore resumes.** Each page and the restore's progress commit together,
  so after a power cut the restore continues from the last page for the same
  server_generation; a table that fails its checksum is downloaded again from scratch. Once
  central accepts the restore the site leaves restoring mode at once, and the
  catch-up pull is an ordinary pull: if it fails, the agent's next pull catches up.
- **A site's pull cursor advancing is not the same as it receiving something.**
  `FeedController#changes` moves a site's cursor to the feed's current end
  whenever the page it returns is short, whether or not any of those rows
  were addressed to that site ("everything up to here has been seen,
  matching or not" -- `app/controllers/api/v1/site_sync/feed_controller.rb`).
  A site catches its cursor up to a completely unrelated change elsewhere.
  Anything that should fire only on a real delivery (an alert, an animation,
  a count) must use `Puller`'s separate `pulled_applied_total`, which only
  grows when `DownstreamApplier#apply` actually returns `:applied`.
- **Parked rows give up.** A change from central whose parent never arrives is
  retried after every pull, but after 100 attempts or 7 days it is marked
  orphaned and shown on central's dashboard for a data officer. Once the
  parent is available (for example released from quarantine),
  `rake site_sync:retry_orphans` retries them.
- **Three MySQL accounts per site**, as the demo runs them:
  - an administrator runs migrations, `site_sync:install` and `site_sync:grants`;
  - `mahis_app` (the MaHIS API) can read and write clinical tables but only
    read the sync tables, so it cannot edit or delete the queue;
  - `mahis_sync` (the agent) owns the capture triggers: a trigger runs with
    its definer's rights, so the triggers carry `DEFINER = 'mahis_sync'@'%'`
    (`SITE_SYNC_TRIGGER_DEFINER`) and keep working after the app account is
    restricted. `site_sync:check` fails if any trigger has another definer
    -- but only when run as an account with TRIGGER privilege (`mahis_sync`,
    or root); `information_schema.TRIGGERS` hides triggers from an account
    that lacks it, so running `check` as `mahis_app` always reports every
    trigger "missing" even when they're installed and firing correctly.

  `rake site_sync:grants` only touches rights on the MaHIS database (other
  databases and global rights are left alone, with a warning if a global right
  would override it), keeps the database-wide rights the app needs (temporary
  tables, routines, views), and **must be rerun whenever a table joins or
  leaves the synced list** -- not just after a migration -- since `mahis_sync`
  only gets `TRIGGER` on tables `Config.synced?` currently names; widening
  `config/site_sync_tables.yml` without rerunning grants leaves triggers
  present but unable to fire (`TRIGGER command denied`).
- **Central captures and publishes its own changes too**, the same way a
  site does -- same triggers, same `sync_change_log` -- since central is
  deployed as its own facility-like server and its data can be modified
  directly, not only through `CentralCorrection`'s admin-only path.
  There's nowhere to push a batch to, so `SiteSync::LocalPublisher`
  (`rake site_sync:publish_local`, running as `central-agent`) walks
  central's own outbox and calls `Central.publish(from_site: 'CENTRAL', ...)`
  directly -- the same call `CentralCorrection` already made. `CENTRAL` is
  a reserved site code; `admin_controller#register` refuses a real site
  trying to register under it.
  **Central's own api account is still `root`, deliberately** -- the
  `site_sync:grants` privilege model assumes the app account only ever
  *reads* sync tables (a site's triggers/agent do all its sync writes).
  Central's api is different: `BatchesController`, `FeedController`,
  `AdminController` and others write `sync_request_nonces`,
  `sync_central_feed`, `sync_alerts` and more directly as part of handling
  requests, with no separate process doing it for them. Giving it the same
  restricted account a site gets breaks sync outright (confirmed: `INSERT`
  denied on `sync_request_nonces`). This needs its own privilege model, not
  a copy of the site one.

## Where things are

| Piece | File |
|---|---|
| What is synced, ownership, lanes, protected fields | `config/site_sync_tables.yml` |
| Capture triggers (generated) | `lib/site_sync/trigger_generator.rb`, `rake site_sync:generate / install / check` |
| Request and job tagging | `ApplicationController#tag_sync_request`, `lib/site_sync/sidekiq_tagger.rb` |
| Seal + push, hash chain, acks | `app/services/site_sync/sender.rb` |
| Central validation, quarantine, field-level merge | `app/services/site_sync/central_ingest.rb` |
| Pull, on-demand patient fetch | `app/services/site_sync/puller.rb`, `downstream_applier.rb` |
| Central captures and publishes its own changes | `app/services/site_sync/local_publisher.rb`, `rake site_sync:publish_local` |
| Merkle reconciliation | `lib/site_sync/merkle.rb`, `app/services/site_sync/reconciler.rb` |
| Restore | `app/services/site_sync/restore.rb`, `Api::V1::SiteSync::RestoreController` |
| Dashboard, heartbeat | `app/services/site_sync/dashboard.rb`, `heartbeat.rb` |
| Endpoints | `app/controllers/api/v1/site_sync/`, routes under `/api/v1/site_sync` |
| Agent loop | `rake site_sync:agent` (or the Sidekiq jobs in `app/jobs/site_sync/`) |

Sync is off unless `MAHIS_SYNC_ROLE` is set, so existing deployments are unaffected.



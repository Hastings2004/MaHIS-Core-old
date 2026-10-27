#!/bin/bash
# One-time preparation of a hospital site's database, run by the site's
# "init" container before its API and sync agent start. Safe to rerun: a
# database this script has already set up for this exact site is left alone.
#
# Needs: DB_HOST, DB_ROOT_PASSWORD, MAHIS_SITE_LOCATION_ID, and the site's
# sync settings (MAHIS_SYNC_ROLE, MAHIS_SITE_CODE, SITE_SYNC_TRIGGER_DEFINER).
set -euo pipefail
cd /app
export MYSQL_PWD="$DB_ROOT_PASSWORD"
db() { mysql -h"$DB_HOST" -uroot "$@"; }

echo "[$MAHIS_SITE_CODE] waiting for the database (the first start loads the MaHIS data, a few minutes)..."
until db -e 'SELECT 1' mahis >/dev/null 2>&1; do sleep 3; done

# Whether this *site* has been through this script before is not the same
# question as whether the sync tables exist: the starting-data dump this
# loads from is itself built from a database that already has them, so a
# completely fresh deploy would always see them present. This site's own
# current_health_center_id is never set in that dump -- only by a real run
# of this script, for this exact site -- so it is the safe signal to exit
# early on. Table creation is guarded separately, since it is not safe to
# repeat (no "if not exists") if the dump already carries empty sync tables.
current_location=$(db -N -e "SELECT property_value FROM global_property WHERE property = 'current_health_center_id'" mahis 2>/dev/null || true)
if [ "$current_location" = "$MAHIS_SITE_LOCATION_ID" ]; then
  echo "[$MAHIS_SITE_CODE] already prepared"
  exit 0
fi

# As the database administrator.
export DATABASE_URL="mysql2://root:${DB_ROOT_PASSWORD}@${DB_HOST}:3306/mahis"

if db -N -e "SHOW TABLES LIKE 'sync_state'" mahis | grep -q sync_state; then
  echo "[$MAHIS_SITE_CODE] sync tables already present (from the starting data)"
else
  echo "[$MAHIS_SITE_CODE] creating the sync tables"
  bin/rails runner '
    require Rails.root.join("db/migrate/20261014000000_create_site_sync_tables.rb").to_s
    CreateSiteSyncTables.new.migrate(:up)
    ActiveRecord::Base.lease_connection.execute("INSERT IGNORE INTO schema_migrations (version) VALUES (\"20261014000000\")")'
fi

echo "[$MAHIS_SITE_CODE] setting the facility (location $MAHIS_SITE_LOCATION_ID)"
db mahis -e "
  DELETE FROM global_property WHERE property = 'current_health_center_id';
  INSERT INTO global_property (property, property_value, uuid)
  VALUES ('current_health_center_id', '$MAHIS_SITE_LOCATION_ID', UUID());"

# DEMO=1 (the default): every site starts from one shared copy of the MaHIS
# data, so this pins all its bootstrap users to the one facility and gives
# the demo admin a fixed, long-lived token to skip logging in by hand. A real
# deployment seeds each site's own users individually and must not run with
# DEMO=1 -- set DEMO=0 to skip this block.
if [ "${DEMO:-1}" = "1" ]; then
  echo "[$MAHIS_SITE_CODE] DEMO=1: pinning bootstrap users to this facility and setting a demo admin token"
  db mahis -e "
    UPDATE users SET location_id = $MAHIS_SITE_LOCATION_ID;
    UPDATE users SET authentication_token = 'demo-token', token_expiry_time = NOW() + INTERVAL 1 YEAR
    WHERE username = 'admin';"
fi

echo "[$MAHIS_SITE_CODE] installing capture triggers and queueing existing rows"
bin/rake site_sync:install
bin/rake site_sync:snapshot

echo "[$MAHIS_SITE_CODE] restricting the app and sync database accounts"
bin/rake "site_sync:grants[mahis_app,mahis_sync]" 2>/dev/null | grep -E '^(REVOKE|GRANT)' | db

echo "[$MAHIS_SITE_CODE] ready"

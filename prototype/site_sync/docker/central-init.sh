#!/bin/bash
# One-time preparation of central's database: sync tables and the two
# registered hospitals. Safe to rerun.
set -euo pipefail
cd /app
export MYSQL_PWD="$DB_ROOT_PASSWORD"
db() { mysql -h"$DB_HOST" -uroot "$@"; }

echo "[central] waiting for the database (the first start loads the MaHIS data, a few minutes)..."
until db -e 'SELECT 1' mahis >/dev/null 2>&1; do sleep 3; done

# Checking for the sync tables alone is not enough: the starting-data dump
# this loads from is itself built from a database that already has them (just
# empty), so that would always look "prepared" even on a fresh deploy. KCH and
# ZCH actually being registered is never true in that dump -- only after a
# real run of this script -- so it is the safe signal to exit early on. Table
# creation is guarded separately below, since repeating it is not safe (no
# "if not exists") if the dump already carries empty sync tables.
registered=$(db -N -e "SELECT COUNT(*) FROM sync_sites WHERE site_code IN ('KCH','ZCH')" mahis 2>/dev/null || echo 0)
if [ "$registered" = "2" ]; then
  echo "[central] already prepared"
  exit 0
fi

export DATABASE_URL="mysql2://root:${DB_ROOT_PASSWORD}@${DB_HOST}:3306/mahis"

if db -N -e "SHOW TABLES LIKE 'sync_sites'" mahis | grep -q sync_sites; then
  echo "[central] sync tables already present (from the starting data)"
else
  echo "[central] creating the sync tables"
  bin/rails runner '
    require Rails.root.join("db/migrate/20261014000000_create_site_sync_tables.rb").to_s
    CreateSiteSyncTables.new.migrate(:up)
    ActiveRecord::Base.lease_connection.execute("INSERT IGNORE INTO schema_migrations (version) VALUES (\"20261014000000\")")'
fi

echo "[central] registering the hospitals"
bin/rails runner '
  SiteSync::Central.register_site("KCH", name: "Kamuzu Central Hospital", secret: ENV.fetch("KCH_SECRET"),
                                   location_id: ENV.fetch("KCH_LOCATION_ID"))
  SiteSync::Central.register_site("ZCH", name: "Zomba Central Hospital", secret: ENV.fetch("ZCH_SECRET"),
                                   location_id: ENV.fetch("ZCH_LOCATION_ID"))'
echo "[central] ready"

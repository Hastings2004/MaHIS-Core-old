# frozen_string_literal: true

module SiteSync
  # Central's one-page view of every site: lag, backlog, clock, quarantine,
  # last reconciliation, plus recent alerts.
  class Dashboard
    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
    end

    def data
      {
        'generated_at' => Time.now.iso8601,
        'sites' => @conn.select_all(<<~SQL).to_a.map { |site| site_row(site) },
          SELECT *, TIMESTAMPDIFF(SECOND, last_heartbeat_at, NOW(6)) AS heartbeat_age_s_sql
          FROM sync_sites ORDER BY site_code
        SQL
        'feed_size' => @conn.select_value('SELECT COUNT(*) FROM sync_central_feed').to_i,
        'feed_max_seq' => @conn.select_value('SELECT COALESCE(MAX(global_seq), 0) FROM sync_central_feed').to_i,
        'open_conflicts' => @conn.select_value("SELECT COUNT(*) FROM sync_conflicts WHERE status = 'open'").to_i,
        'logged_conflicts' => @conn.select_value("SELECT COUNT(*) FROM sync_conflicts WHERE status = 'logged'").to_i,
        'duplicates' => @conn.select_all(<<~SQL).to_a,
          SELECT id, new_uuid, matched_uuid, match_strength, national_id, created_at
          FROM sync_duplicate_candidates WHERE status = 'open' ORDER BY id DESC LIMIT 10
        SQL
        'corrections' => @conn.select_all(<<~SQL).to_a,
          SELECT id, table_name, row_uuid, changes_json, reason, created_at
          FROM sync_central_corrections ORDER BY id DESC LIMIT 10
        SQL
        'quarantine' => @conn.select_all(<<~SQL).to_a,
          SELECT id, site_code, table_name, row_uuid, reason, details, status FROM sync_quarantine
          ORDER BY id DESC LIMIT 10
        SQL
        'alerts' => @conn.select_all(
          'SELECT site_code, alert_type, message, created_at FROM sync_alerts ORDER BY id DESC LIMIT 15'
        ).to_a
      }
    end

    def site_row(site)
      code = @conn.quote(site['site_code'])
      beat = site['heartbeat_json'] ? JSON.parse(site['heartbeat_json']) : {}
      last_run = @conn.select_one(
        "SELECT report_json, finished_at FROM sync_reconciliation_runs WHERE site_code = #{code} ORDER BY id DESC LIMIT 1"
      )
      run = last_run && JSON.parse(last_run['report_json'])
      # The registered facility's name (set once, by a central admin, at
      # registration) rather than whatever the site last reported about
      # itself: a site cannot rename itself on this dashboard.
      location_name = site['location_id'] && @conn.select_value(
        "SELECT name FROM location WHERE location_id = #{site['location_id'].to_i}"
      )
      {
        'site_code' => site['site_code'], 'name' => location_name || site['name'], 'location_id' => site['location_id'],
        'status' => site['status'], 'server_generation' => site['server_generation'].to_i,
        # Computed in SQL (not Time.now - site['last_heartbeat_at']): MySQL runs
        # in UTC while Rails is configured for Africa/Blantyre with
        # default_timezone = :local, so a Ruby-side subtraction is off by the
        # zone offset. Doing both sides of the diff in MySQL cancels it out.
        'heartbeat_age_s' => site['heartbeat_age_s_sql']&.to_i,
        'backlog' => beat['backlog'] || {}, 'oldest_unsent_s' => beat['oldest_unsent_seconds'],
        'clock_offset_s' => beat['clock_offset_s'], 'mode' => beat['mode'],
        'pull_cursor' => beat['pull_cursor'].to_i,
        'parked' => beat['pending_apply'].to_i, 'orphaned' => beat['orphaned'].to_i,
        'triggers' => beat['triggers_installed'] && "#{beat['triggers_installed']}/#{beat['triggers_expected']}",
        'last_batch_at' => @conn.select_value("SELECT MAX(received_at) FROM sync_received_batches WHERE site_code = #{code}"),
        'events_received' => @conn.select_value(
          "SELECT COALESCE(SUM(change_count), 0) FROM sync_received_batches WHERE site_code = #{code}"
        ).to_i,
        'backup_rows' => @conn.select_value(
          "SELECT COUNT(*) FROM sync_site_backup WHERE site_code = #{code} AND deleted = 0"
        ).to_i,
        'open_quarantine' => @conn.select_value(
          "SELECT COUNT(*) FROM sync_quarantine WHERE site_code = #{code} AND status = 'open'"
        ).to_i,
        'reconciliation' => run && {
          'status' => run['status'], 'at' => last_run['finished_at'],
          'differences' => (run['tables'] || {}).values.sum { |t| t['differences'].to_i },
          'bytes' => run['bytes_exchanged']
        }
      }
    end

    def self.html(data)
      esc = ->(value) { ERB::Util.html_escape(value.to_s) }
      sites = data['sites'].map do |s|
        backlog = s['backlog'].map { |priority, n| "#{priority}: #{n}" }.join(', ').presence || '0'
        rec = s['reconciliation']
        rec_text = rec ? "#{rec['status']}, #{rec['differences']} diff, #{rec['bytes']} B" : '—'
        status_class = s['status'] == 'active' ? 'ok' : 'warn'
        lag_class = s['oldest_unsent_s'].to_i > 300 ? 'warn' : 'ok'
        <<~ROW
          <tr>
            <td><b>#{esc[s['name']]}</b><br><small>#{esc[s['site_code']]}</small></td>
            <td>#{s['location_id'] || '—'}</td>
            <td class="#{status_class}">#{esc[s['status']]}</td>
            <td>#{esc[backlog]}</td>
            <td class="#{lag_class}">#{s['oldest_unsent_s'] || '—'} s</td>
            <td>#{s['events_received']}<br><small>last #{esc[s['last_batch_at']&.strftime('%H:%M:%S')]}</small></td>
            <td>#{s['backup_rows']}</td>
            <td class="#{s['open_quarantine'].positive? ? 'warn' : 'ok'}">#{s['open_quarantine']}</td>
            <td>#{esc[rec_text]}</td>
          </tr>
        ROW
      end.join
      quarantine = data['quarantine'].map do |q|
        "<tr><td>#{q['id']}</td><td>#{esc[q['site_code']]}</td><td>#{esc[q['table_name']]}</td>" \
          "<td><code>#{esc[q['row_uuid']]}</code></td><td>#{esc[q['reason']]}</td><td>#{esc[q['details']]}</td>" \
          "<td>#{esc[q['status']]}</td></tr>"
      end.join
      alerts = data['alerts'].map do |a|
        "<tr><td>#{esc[a['created_at']&.strftime('%H:%M:%S')]}</td><td>#{esc[a['site_code']]}</td>" \
          "<td>#{esc[a['alert_type']]}</td><td>#{esc[a['message']]}</td></tr>"
      end.join
      duplicates = data['duplicates'].map do |d|
        "<tr><td>#{d['id']}</td><td><code>#{esc[d['new_uuid']]}</code></td><td><code>#{esc[d['matched_uuid']]}</code></td>" \
          "<td>#{esc[d['match_strength']]}</td><td>#{esc[d['national_id']]}</td>" \
          "<td>#{esc[d['created_at']&.strftime('%H:%M:%S')]}</td></tr>"
      end.join
      corrections = data['corrections'].map do |c|
        "<tr><td>#{esc[c['created_at']&.strftime('%Y-%m-%d %H:%M:%S')]}</td><td>#{esc[c['table_name']]}</td>" \
          "<td><code>#{esc[c['row_uuid']]}</code></td><td>#{esc[c['changes_json']]}</td><td>#{esc[c['reason']]}</td></tr>"
      end.join

      <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>MaHIS Sync</title>
        <style>
          :root { --bg:#fafaf9; --fg:#1c1917; --muted:#78716c; --line:#e7e5e4; --ok:#15803d; --warn:#b45309; --card:#fff; }
          @media (prefers-color-scheme: dark) { :root { --bg:#1c1917; --fg:#f5f5f4; --muted:#a8a29e; --line:#44403c;
            --ok:#4ade80; --warn:#fbbf24; --card:#292524; } }
          body { font: 14px/1.4 system-ui, sans-serif; background: var(--bg); color: var(--fg); margin: 0; padding: 16px; }
          h1 { font-size: 20px; margin: 0 0 4px; } h2 { font-size: 15px; margin: 24px 0 8px; }
          .meta { color: var(--muted); margin-bottom: 16px; }
          .wrap { overflow-x: auto; background: var(--card); border: 1px solid var(--line); border-radius: 8px; }
          table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
          th { color: var(--muted); font-weight: 600; font-size: 12px; } small { color: var(--muted); }
          .ok { color: var(--ok); } .warn { color: var(--warn); font-weight: 600; } code { font-size: 12px; }
          form.register { display: flex; gap: 8px; flex-wrap: wrap; align-items: end; padding: 12px; }
          form.register label { display: flex; flex-direction: column; font-size: 12px; color: var(--muted); gap: 4px; }
          form.register input { font: inherit; padding: 6px 8px; border: 1px solid var(--line); border-radius: 4px;
            background: var(--bg); color: var(--fg); }
          form.register button { padding: 7px 14px; border: 0; border-radius: 4px; background: var(--ok); color: #fff;
            font-weight: 600; cursor: pointer; }
          #register-result { margin: 0 12px 12px; white-space: pre-wrap; font-size: 12px; }
          .combobox { position: relative; }
          .combobox-results { position: absolute; top: 100%; left: 0; right: 0; z-index: 10; max-height: 220px;
            overflow-y: auto; background: var(--card); border: 1px solid var(--line); border-radius: 4px;
            margin-top: 2px; display: none; }
          .combobox-results.open { display: block; }
          .combobox-results div { padding: 6px 8px; cursor: pointer; font-size: 13px; }
          .combobox-results div:hover, .combobox-results div.active { background: var(--bg); }
          .combobox-results small { display: block; color: var(--muted); }
        </style></head><body>
        <h1>MaHIS two-way sync</h1>
        <div class="meta" id="meta">Central feed: #{data['feed_size']} changes · conflicts: #{data['open_conflicts']} open for review,
          #{data['logged_conflicts']} auto-resolved · refreshed #{esc[data['generated_at']]}
          · <a href="#" onclick="location.reload(); return false">refresh now</a></div>
        <div class="wrap"><table>
          <tr>
            <th title="The site's name and its sync code">Site</th>
            <th title="This site's MaHIS location_id, as registered with central">Location</th>
            <th title="active, frozen (mid-restore), or disabled">Status</th>
            <th title="Changes this site has captured but not yet had acknowledged by central. Should trend to 0.">Unsent</th>
            <th title="Age of the oldest unacknowledged change -- how far behind this site is">Oldest unsent</th>
            <th title="Total changes central has received and applied from this site, lifetime count">Events received</th>
            <th title="Rows of this site's data central holds in its own backup copy, used to rebuild the site if needed">Backup rows</th>
            <th title="Changes central held back after failing a check. Most clear automatically once the site sends a corrected version; a data officer is only needed for the rest">Held for review</th>
            <th title="When the nightly checksum comparison between this site and central last ran">Last reconciliation</th>
          </tr>
          #{sites}
        </table></div>

        <h2>Register a site</h2>
        <div class="wrap">
          <form class="register" id="register-form">
            <label>Site code <input name="site_code" required maxlength="16" style="text-transform:uppercase" placeholder="e.g. MZUZU"></label>
            <label class="combobox">Facility
              <input id="location-search" autocomplete="off" required placeholder="Start typing a facility name...">
              <input type="hidden" name="location_uuid" id="location-uuid">
              <div class="combobox-results" id="location-results"></div>
            </label>
            <button type="submit">Register</button>
          </form>
          <p class="meta" style="margin:0 12px 12px">The site's name is taken from the facility you pick here, not
            typed separately -- so it can never drift from the facility it actually is.</p>
          <div id="register-result"></div>
        </div>
        <script>
          // Auto-refresh every 5s, cancelled for good the moment anyone
          // touches the register form -- typing, searching and picking a
          // facility all take longer than 5s, and a reload mid-way would
          // wipe whatever was typed (and, after submit, the one-time secret).
          var refreshTimer = setTimeout(function () { location.reload(); }, 5000);
          document.getElementById('register-form').addEventListener('focusin', function () {
            clearTimeout(refreshTimer);
          });
          var adminToken = new URLSearchParams(location.search).get('token') || '';

          // Facility search box: types a name, picks a result, the result's
          // uuid (never the sequential location_id) goes in the hidden field.
          var searchInput = document.getElementById('location-search');
          var uuidField = document.getElementById('location-uuid');
          var resultsBox = document.getElementById('location-results');
          var searchTimer = null;
          searchInput.addEventListener('input', function () {
            uuidField.value = '';
            var term = searchInput.value;
            clearTimeout(searchTimer);
            if (term.length < 2) { resultsBox.classList.remove('open'); resultsBox.innerHTML = ''; return; }
            searchTimer = setTimeout(function () {
              fetch('/api/v1/site_sync/admin/locations?q=' + encodeURIComponent(term), {
                headers: { 'X-Admin-Token': adminToken }
              }).then(function (res) { return res.json(); }).then(function (rows) {
                resultsBox.innerHTML = '';
                rows.forEach(function (loc) {
                  var item = document.createElement('div');
                  item.textContent = loc.name;
                  if (loc.city_village) {
                    var sub = document.createElement('small');
                    sub.textContent = loc.city_village;
                    item.appendChild(sub);
                  }
                  item.addEventListener('click', function () {
                    searchInput.value = loc.name;
                    uuidField.value = loc.uuid;
                    resultsBox.classList.remove('open');
                  });
                  resultsBox.appendChild(item);
                });
                resultsBox.classList.toggle('open', rows.length > 0);
              });
            }, 250);
          });
          document.addEventListener('click', function (e) {
            if (!resultsBox.contains(e.target) && e.target !== searchInput) resultsBox.classList.remove('open');
          });

          document.getElementById('register-form').addEventListener('submit', function (e) {
            e.preventDefault();
            if (!uuidField.value) {
              var el = document.getElementById('register-result');
              el.textContent = 'Pick a facility from the dropdown first -- typing a name alone is not enough.';
              el.className = 'warn';
              return;
            }
            clearTimeout(refreshTimer);
            var body = Object.fromEntries(new FormData(e.target));
            fetch('/api/v1/site_sync/admin/sites', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Admin-Token': adminToken },
              body: JSON.stringify(body)
            }).then(function (res) {
              return res.json().then(function (data) { return { ok: res.ok, data: data }; });
            }).then(function (result) {
              var el = document.getElementById('register-result');
              el.textContent = JSON.stringify(result.data, null, 2);
              el.className = result.ok ? 'ok' : 'warn';
              if (result.ok) {
                var note = document.createElement('div');
                note.className = 'meta';
                note.textContent = 'Copy the secret above now -- it will not be shown again. Reload when ready.';
                el.appendChild(note);
              }
            }).catch(function (err) {
              document.getElementById('register-result').textContent = 'Request failed: ' + err;
            });
          });
        </script>

        <h2>Possible duplicate patients</h2>
        <div class="wrap"><table><tr><th>#</th><th>New patient</th><th>May be the same as</th><th>Match</th><th>National ID</th><th>Found at</th></tr>
          #{duplicates.presence || '<tr><td colspan="6">None open</td></tr>'}</table></div>
        <h2>Central corrections (latest)</h2>
        <div class="wrap"><table><tr><th>When</th><th>Table</th><th>Row</th><th>Changed</th><th>Reason</th></tr>
          #{corrections.presence || '<tr><td colspan="5">None yet</td></tr>'}</table></div>
        <h2>Held for review (latest)</h2>
        <div class="wrap"><table><tr><th>#</th><th>Site</th><th>Table</th><th>Record</th><th>Reason</th><th>Details</th><th>Status</th></tr>
          #{quarantine.presence || '<tr><td colspan="7">Nothing held</td></tr>'}</table></div>
        <h2>Alerts</h2>
        <div class="wrap"><table><tr><th>Time</th><th>Site</th><th>Kind</th><th>Message</th></tr>
          #{alerts.presence || '<tr><td colspan="4">No alerts</td></tr>'}</table></div>
        </body></html>
      HTML
    end
  end
end

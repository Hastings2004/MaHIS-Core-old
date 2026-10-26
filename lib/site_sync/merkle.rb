# frozen_string_literal: true

module SiteSync
  # Digests for reconciliation. Rows are bucketed by uuid prefix; a bucket's
  # digest is "<row count>:<sum of the first 60 bits of each row hash>". Sums
  # do not depend on row order, so both sides can compute them with one
  # GROUP BY. Comparing 256 two-character buckets, then the 256 four-character
  # buckets under each differing one, then the rows themselves, finds a single
  # changed row among millions in three small round trips.
  module Merkle
    LEVELS = [2, 4].freeze

    module_function

    # Site side: digests of the live table.
    def site_digests(connection, table, prefix_len, within = nil)
      digests(connection, "(#{RowSql.hashed_rows(table)}) x", prefix_len, within)
    end

    # Central side: digests of the backup copy of one site.
    def mirror_digests(connection, site_code, table, prefix_len, within = nil)
      source = <<~SQL
        (SELECT row_uuid, row_hash FROM sync_site_backup
         WHERE site_code = #{connection.quote(site_code)} AND table_name = #{connection.quote(table)} AND deleted = 0) x
      SQL
      digests(connection, source, prefix_len, within)
    end

    def digests(connection, source, prefix_len, within)
      filter = if within.present?
                 "WHERE LEFT(x.row_uuid, #{within.first.length}) IN (#{within.map { |p| connection.quote(p) }.join(', ')})"
               else
                 ''
               end
      # CONV returns a string, and SUM over strings is floating point: it
      # loses digits and depends on row order. Summing integers gives an exact
      # DECIMAL, returned as a plain digit string.
      connection.select_rows(<<~SQL).to_h { |prefix, count, sum| [prefix, "#{count}:#{sum}"] }
        SELECT LEFT(x.row_uuid, #{prefix_len.to_i}) AS prefix, COUNT(*),
               CAST(SUM(CAST(CONV(LEFT(x.row_hash, 15), 16, 10) AS UNSIGNED)) AS CHAR)
        FROM #{source} #{filter}
        GROUP BY prefix
      SQL
    end

    def differing(ours, theirs)
      (ours.keys | theirs.keys).reject { |key| ours[key] == theirs[key] }.sort
    end

    # Whole-table digest, used as the restore manifest's checksum.
    def table_digest(digests)
      count = 0
      sum = 0
      digests.each_value do |value|
        c, s = value.split(':')
        # Integer() rather than to_i: a non-integer must fail loudly, not
        # silently turn "4.6e+21" into 4.
        count += Integer(c)
        sum += Integer(s)
      end
      "#{count}:#{sum}"
    end
  end
end

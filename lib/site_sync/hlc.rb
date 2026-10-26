# frozen_string_literal: true

module SiteSync
  # Hybrid logical clock, as one integer: microseconds since the Unix server_generation,
  # bumped by one whenever the wall clock has not moved past the last value.
  # Values only ever increase on a node, even if its clock is set back (for
  # example after a power cut resets it), because the last value is persisted
  # in sync_state together with the batch that used it.
  module Hlc
    module_function

    def from_time(time)
      (time.to_r * 1_000_000).to_i
    end

    def now_us
      from_time(Time.now)
    end

    # Next value after `last` for an event that happened at `wall_us`.
    def tick(last, wall_us)
      [last.to_i + 1, wall_us].max
    end

    # Received from another node: keep ours ahead of everything we have seen.
    def receive(last, remote, wall_us = now_us)
      [last.to_i + 1, remote.to_i, wall_us].max
    end

    def to_time(change_time)
      Time.at(Rational(change_time, 1_000_000))
    end
  end
end

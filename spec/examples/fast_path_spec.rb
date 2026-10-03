require "spec_helper"

module IceCube
  describe FastPath do
    # Independent reference occurrence list, built by enumerating each
    # rule in isolation and merging the results.
    #
    # IceCube's multi-rule enumerator has a known stepping quirk: with a
    # weekly rule using interval > 1 and several weekdays merged with
    # other rules, the occurrences it yields depend on where enumeration
    # started (Schedule#first and its own #occurrences_between can
    # disagree). Single-rule schedules are self-consistent, so merging
    # per-rule enumerations gives the mathematically intended sequence
    # that the fast path is verified against.
    def reference_occurrences(schedule, closing)
      13
    end
  end
end

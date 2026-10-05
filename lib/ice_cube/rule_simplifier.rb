require "date"

module IceCube
  class RuleSimplifier
    LIST_TYPES = %i[
      second_of_minute minute_of_hour hour_of_day
      month_of_year day day_of_month day_of_year by_set_pos
    ].freeze

    class Result
      include Enumerable

      attr_reader :original_rules, :rules, :steps

      def initialize(original_rules, rules, steps)
        @original_rules = Array(original_rules)
        @rules = rules
        @steps = steps
      end

      def each(&block)
        @rules.each(&block)
      end

      def first
        @rules.first
      end

      def last
        @rules.last
      end

      def [](index)
        @rules[index]
      end

      def size
        @rules.size
      end
      alias_method :length, :size

      def to_a
        @rules.dup
      end
      alias_method :to_ary, :to_a

      def unchanged?
        @rules.map(&:to_ical) == @original_rules.map(&:to_ical)
      end

      def to_h
        {rules: @rules, steps: @steps}
      end
    end

    def self.simplify(rule_or_rules, dtstart: nil)
      new.simplify(rule_or_rules, dtstart: dtstart)
    end

    def simplify(rule_or_rules, dtstart: nil)
      originals = Array(rule_or_rules)
      @dtstart = TimeUtil.ensure_time(dtstart) unless dtstart.nil?
      @steps = []

      entries = originals.each_with_index.map { |rule, index| canonicalize(rule, index) }
      entries.each { |entry| remove_provable_redundancies(entry) }
      rules = merge_equivalent_rules(entries)

      Result.new(originals, rules, @steps)
    ensure
      @dtstart = nil
    end

    private

    def canonicalize(rule, original_index)
      before_ical = rule.to_ical
      hash = deep_copy(rule.to_hash)
      original_validations = (hash[:validations] || {}).dup
      validations = hash[:validations]

      if validations
        validations.each do |type, value|
          validations[type] = canonical_value(type, value)
        end
        validations.reject! { |_type, value| value.nil? || value == [] || value == {} }
        if validations.empty?
          hash.delete(:validations)
        else
          hash[:validations] = validations
        end
      end

      rebuilt = Rule.from_hash(hash)
      after = rebuilt.to_ical
      rebuilt_validations = rebuilt.to_hash[:validations] || {}

      changed_types = original_validations.select do |type, value|
        value != rebuilt_validations[type]
      end.keys

      changed_types.each do |type|
        @steps << {
          action: :deduplicate,
          rule_index: original_index,
          before: before_ical,
          after: after,
          by_part: ical_part(type),
          basis: :duplicate_values_within_a_by_part_are_the_same_alternative
        }
      end

      {rule: rebuilt, hash: rebuilt.to_hash, source_indices: [original_index], ical: after}
    end

    def canonical_value(type, value)
      case type
      when :day_of_week
        value.each_with_object({}) do |(weekday, occurrences), normalized|
          normalized[weekday] = occurrences.uniq.sort
        end
      when *LIST_TYPES
        value.flatten.uniq
      else
        value
      end
    end

    def remove_provable_redundancies(entry)
      remove_year_day_implied_date_parts(entry)
    end

    # Provable subset:
    #
    # FREQ=YEARLY;BYYEARDAY=<single value> selects at most one date in each
    # year.  If a BYMONTH or BYMONTHDAY restriction accepts every date that
    # BYYEARDAY resolves to throughout the complete 400-year Gregorian cycle,
    # that restriction cannot filter or expand the selected set and is
    # redundant.  We do not infer anything from one year because positive
    # BYYEARDAY values shift at the leap-day boundary.
    #
    # COUNT and UNTIL only truncate the same recurring set, so they do not
    # block this proof. BYSETPOS changes candidate-set selection and is
    # therefore excluded. DTSTART supplies only smaller time components once
    # an explicit yearly date is selected.
    def remove_year_day_implied_date_parts(entry)
      hash = entry[:hash]
      validations = hash[:validations]
      return unless hash[:rule_type] == YearlyRule.name
      return unless validations
      return if validations.key?(:by_set_pos)

      year_days = validations[:day_of_year]
      return unless year_days && year_days.size == 1

      year_day = year_days.first
      dates = resolved_year_dates(year_day)
      return if dates.empty?

      if (months = validations[:month_of_year]) && dates.map(&:month).uniq.all? { |month| months.include?(month) }
        remove_validation(entry, :month_of_year, year_day_redundancy_basis("BYMONTH", dates))
        validations = entry[:hash][:validations]
      end

      if validations && (month_days = validations[:day_of_month]) && dates.all? { |date| month_days.include?(date.day) }
        remove_validation(entry, :day_of_month, year_day_redundancy_basis("BYMONTHDAY", dates))
      end
    end

    def resolved_year_dates(year_day)
      (2000...2400).map do |year|
        length = Date.gregorian_leap?(year) ? 366 : 365
        ordinal = year_day.positive? ? year_day : length + year_day + 1
        next unless ordinal.between?(1, length)

        Date.ordinal(year, ordinal)
      end.compact
    end

    def year_day_redundancy_basis(part, dates)
      leap_years = dates.select { |date| Date.gregorian_leap?(date.year) }.map(&:year)
      common_years = dates.reject { |date| Date.gregorian_leap?(date.year) }.map(&:year)

      "#{part} is satisfied by BYYEARDAY on every resolved date in the 2000-2399 Gregorian cycle " \
        "(including leap years such as #{leap_years.first} and common years such as #{common_years.first})"
    end

    def remove_validation(entry, type, basis)
      hash = deep_copy(entry[:hash])
      validations = hash[:validations]
      validations.delete(type)
      validations = nil if validations.empty?
      hash[:validations] = validations
      hash.compact!

      rebuilt = Rule.from_hash(hash)
      before = entry[:rule].to_ical
      after = rebuilt.to_ical

      @steps << {
        action: :remove_redundant,
        rule_index: entry[:source_indices].first,
        source_rule_indices: entry[:source_indices].dup,
        removed: ical_part(type),
        before: before,
        after: after,
        basis: basis
      }

      entry[:rule] = rebuilt
      entry[:hash] = rebuilt.to_hash
      entry[:ical] = after
    end

    # Rule branches in one schedule share its DTSTART. Identical canonical
    # forms therefore have identical expansion, COUNT consumption, and UNTIL
    # behavior. We require DTSTART for an array input so callers cannot merge
    # independently sourced rules whose implicit anchors happen to differ.
    def merge_equivalent_rules(entries)
      groups = []

      entries.each do |entry|
        unless @dtstart
          groups << entry
          next
        end

        group = groups.find { |candidate| equivalent_rules?(candidate, entry) }

        if group
          before = [group[:ical], entry[:ical]]
          group[:source_indices].concat(entry[:source_indices]).sort!

          @steps << {
            action: :merge_equivalent,
            rule_index: group[:source_indices].first,
            merged_rule_index: entry[:source_indices].first,
            source_rule_indices: group[:source_indices].dup,
            before: before,
            after: group[:ical],
            basis: @last_merge_basis
          }
        else
          groups << entry
        end
      end

      groups.map { |group| Rule.from_hash(deep_copy(group[:hash])) }
    end

    def equivalent_rules?(left, right)
      if left[:hash] == right[:hash]
        @last_merge_basis = :canonical_rule_forms_are_identical_under_shared_dtstart
        return true
      end

      left_signature = left[:semantic_signature] ||= semantic_signature(left)
      right_signature = right[:semantic_signature] ||= semantic_signature(right)

      return false if left_signature.nil? || right_signature.nil?
      return false unless left_signature == right_signature

      @last_merge_basis = :occurrence_sets_match_throughout_the_2000_2399_gregorian_cycle
      true
    end

    def semantic_signature(entry)
      hash = entry[:hash]
      validations = hash[:validations] || {}

      return unless hash[:interval] == 1
      return if hash.key?(:count) || hash.key?(:until)
      return if validations.key?(:by_set_pos)

      date_parts = validations.values_at(:day, :day_of_week, :day_of_month, :month_of_year, :day_of_year).any?
      return unless date_parts
      return unless @dtstart.year <= 2400

      schedule = Schedule.new(@dtstart)
      schedule.add_recurrence_rule(Rule.from_hash(deep_copy(hash)))
      closing_time = TimeUtil.build_in_zone([2399, 12, 31, 23, 59, 59], @dtstart)
      occurrences = schedule.occurrences(closing_time)

      {
        week_start: hash[:week_start],
        time_parts: validations.slice(:hour_of_day, :minute_of_hour, :second_of_minute),
        occurrences: occurrences.map { |time| [time.to_date, time.hour, time.min, time.sec] }
      }
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def ical_part(type)
      {
        second_of_minute: "BYSECOND",
        minute_of_hour: "BYMINUTE",
        hour_of_day: "BYHOUR",
        day_of_week: "BYDAY",
        day: "BYDAY",
        day_of_month: "BYMONTHDAY",
        month_of_year: "BYMONTH",
        day_of_year: "BYYEARDAY",
        by_set_pos: "BYSETPOS"
      }.fetch(type)
    end
  end
end

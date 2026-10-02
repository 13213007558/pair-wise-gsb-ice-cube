require "yaml"

module IceCube
  class Schedule
    extend Deprecated

    # Get the start time
    attr_reader :start_time
    deprecated_alias :start_date, :start_time

    # Get the end time
    attr_reader :end_time
    deprecated_alias :end_date, :end_time

    # Create a new schedule
    def initialize(start_time = nil, options = {})
      self.start_time = start_time || TimeUtil.now
      if options.key?(:duration)
        @duration = self.class.coerce_duration(options[:duration], options)
        @duration = nil if @duration == 0
        @end_time = @duration ? end_time_for(@start_time) : nil
      end
      self.end_time = options[:end_time] if options[:end_time]
      @all_recurrence_rules = []
      @all_exception_rules = []
      yield self if block_given?
    end

    # Set start_time
    def start_time=(start_time)
      @start_time = TimeUtil.ensure_time start_time
    end
    deprecated_alias :start_date=, :start_time=

    # Set end_time
    def end_time=(end_time)
      @end_time = TimeUtil.ensure_time end_time
      @duration = nil
    end
    deprecated_alias :end_date=, :end_time=

    def duration
      @duration || (end_time ? end_time - start_time : 0)
    end

    def duration=(value, options = {})
      @duration = self.class.coerce_duration(value, options)
      @duration = nil if @duration == 0
      @end_time = @duration ? end_time_for(start_time) : nil
      @duration
    end

    def end_time_for(time)
      case duration
      when CalendarDuration then duration.after(time)
      when Numeric then TimeUtil.add_exact_seconds(time, duration)
      else
        time
      end
    end

    def self.coerce_duration(value, options = {})
      return value if value.is_a?(CalendarDuration)
      return value if value.is_a?(Numeric)

      ambiguous = options[:ambiguous_time] || options[:ambiguous]
      nonexistent = options[:nonexistent_time] || options[:nonexistent]
      ambiguous = ambiguous.to_sym if ambiguous
      nonexistent = nonexistent.to_sym if nonexistent
      CalendarDuration.parse(value, ambiguous: ambiguous || :raise,
                                    nonexistent: nonexistent || :raise)
    end

    # Add a recurrence time to the schedule
    def add_recurrence_time(time)
      return if time.nil?
      rule = SingleOccurrenceRule.new(time)
      add_recurrence_rule rule
      time
    end
    alias_method :rtime, :add_recurrence_time
    deprecated_alias :rdate, :rtime
    deprecated_alias :add_recurrence_date, :add_recurrence_time

    # Add an exception time to the schedule
    def add_exception_time(time)
      return if time.nil?
      rule = SingleOccurrenceRule.new(time)
      add_exception_rule rule
      time
    end
    alias_method :extime, :add_exception_time
    deprecated_alias :exdate, :extime
    deprecated_alias :add_exception_date, :add_exception_time

    # Add a recurrence rule to the schedule
    def add_recurrence_rule(rule)
      return if rule.nil?
      @all_recurrence_rules << rule unless @all_recurrence_rules.include?(rule)
    end
    alias_method :rrule, :add_recurrence_rule

    # Remove a recurrence rule
    def remove_recurrence_rule(rule)
      res = @all_recurrence_rules.delete(rule)
      res.nil? ? [] : [res]
    end

    # Add an exception rule to the schedule
    def add_exception_rule(rule)
      return if rule.nil?
      @all_exception_rules << rule unless @all_exception_rules.include?(rule)
    end
    alias_method :exrule, :add_exception_rule

    # Remove an exception rule
    def remove_exception_rule(rule)
      res = @all_exception_rules.delete(rule)
      res.nil? ? [] : [res]
    end

    # Get the recurrence rules
    def recurrence_rules
      @all_recurrence_rules.reject { |r| r.is_a?(SingleOccurrenceRule) }
    end
    alias_method :rrules, :recurrence_rules

    # Get the exception rules
    def exception_rules
      @all_exception_rules.reject { |r| r.is_a?(SingleOccurrenceRule) }
    end
    alias_method :exrules, :exception_rules

    # Get the recurrence times that are on the schedule
    def recurrence_times
      @all_recurrence_rules.select { |r| r.is_a?(SingleOccurrenceRule) }.map(&:time)
    end
    alias_method :rtimes, :recurrence_times
    deprecated_alias :rdates, :rtimes
    deprecated_alias :recurrence_dates, :recurrence_times

    # Remove a recurrence time
    def remove_recurrence_time(time)
      found = false
      @all_recurrence_rules.delete_if do |rule|
        found = true if rule.is_a?(SingleOccurrenceRule) && rule.time == time
      end
      time if found
    end
    alias_method :remove_rtime, :remove_recurrence_time
    deprecated_alias :remove_recurrence_date, :remove_recurrence_time
    deprecated_alias :remove_rdate, :remove_rtime

    # Get the exception times that are on the schedule
    def exception_times
      @all_exception_rules.select { |r| r.is_a?(SingleOccurrenceRule) }.map(&:time)
    end
    alias_method :extimes, :exception_times
    deprecated_alias :exdates, :extimes
    deprecated_alias :exception_dates, :exception_times

    # Remove an exception time
    def remove_exception_time(time)
      found = false
      @all_exception_rules.delete_if do |rule|
        found = true if rule.is_a?(SingleOccurrenceRule) && rule.time == time
      end
      time if found
    end
    alias_method :remove_extime, :remove_exception_time
    deprecated_alias :remove_exception_date, :remove_exception_time
    deprecated_alias :remove_exdate, :remove_extime

    # Get all of the occurrences from the start_time up until a
    # given Time
    def occurrences(closing_time)
      enumerate_occurrences(start_time, closing_time).to_a
    end

    # All of the occurrences
    def all_occurrences
      require_terminating_rules
      enumerate_occurrences(start_time).to_a
    end

    # Emit an enumerator based on the start time
    def all_occurrences_enumerator
      enumerate_occurrences(start_time)
    end

    # Iterate forever
    def each_occurrence(&block)
      enumerate_occurrences(start_time, &block).to_a
      self
    end

    # The next n occurrences after now
    def next_occurrences(num, from = nil, options = {})
      from = TimeUtil.match_zone(from, start_time) || TimeUtil.now(start_time)
      enumerate_occurrences(from + 1, nil, options).take(num)
    end

    # The next occurrence after now (overridable)
    def next_occurrence(from = nil, options = {})
      from = TimeUtil.match_zone(from, start_time) || TimeUtil.now(start_time)
      enumerate_occurrences(from + 1, nil, options).next
    rescue StopIteration
      nil
    end

    # The previous occurrence from a given time
    def previous_occurrence(from)
      from = TimeUtil.match_zone(from, start_time) or raise ArgumentError, "Time required, got #{from.inspect}"
      return nil if from <= start_time
      enumerate_occurrences(start_time, from - 1).to_a.last
    end

    # The previous n occurrences before a given time
    def previous_occurrences(num, from)
      from = TimeUtil.match_zone(from, start_time) or raise ArgumentError, "Time required, got #{from.inspect}"
      return [] if from <= start_time
      a = enumerate_occurrences(start_time, from - 1).to_a
      (a.size > num) ? a[-1 * num, a.size] : a
    end

    # The remaining occurrences (same requirements as all_occurrences)
    def remaining_occurrences(from = nil, options = {})
      require_terminating_rules
      from ||= TimeUtil.now(@start_time)
      enumerate_occurrences(from, nil, options).to_a
    end

    # Returns an enumerator for all remaining occurrences
    def remaining_occurrences_enumerator(from = nil, options = {})
      from ||= TimeUtil.now(@start_time)
      enumerate_occurrences(from, nil, options)
    end

    # Occurrences between two times
    def occurrences_between(begin_time, closing_time, options = {})
      enumerate_occurrences(begin_time, closing_time, options).to_a
    end

    # Return a boolean indicating if an occurrence falls between two times
    def occurs_between?(begin_time, closing_time, options = {})
      enumerate_occurrences(begin_time, closing_time, options).next
      true
    rescue StopIteration
      false
    end

    # Return a boolean indicating if an occurrence is occurring between two
    # times, inclusive of its duration. This counts zero-length occurrences
    # that intersect the start of the range and within the range, but not
    # occurrences at the end of the range since none of their duration
    # intersects the range.
    def occurring_between?(opening_time, closing_time)
      occurs_between?(opening_time, closing_time, spans: true)
    end

    # Return a boolean indicating if an occurrence falls on a certain date
    def occurs_on?(date)
      date = TimeUtil.ensure_date(date)
      begin_time = TimeUtil.beginning_of_date(date, start_time)
      closing_time = TimeUtil.end_of_date(date, start_time)
      occurs_between?(begin_time, closing_time)
    end

    # Determine if the schedule is occurring at a given time
    def occurring_at?(time)
      time = TimeUtil.match_zone(time, start_time) or raise ArgumentError, "Time required, got #{time.inspect}"
      if !duration.zero?
        return false if exception_time?(time)
        occurrences_between(time - duration_span_lookback, time + duration_span_lookback, spans: true).any? do |occurrence|
          occurrence.start_time <= time && occurrence.end_time > time
        end
      else
        occurs_at?(time)
      end
    end

    # Determine if this schedule conflicts with another schedule
    # @param [IceCube::Schedule] other_schedule - The schedule to compare to
    # @param [Time] closing_time - the last time to consider
    # @return [Boolean] whether or not the schedules conflict at all
    def conflicts_with?(other_schedule, closing_time = nil)
      closing_time = TimeUtil.ensure_time(closing_time)
      unless terminating? || other_schedule.terminating? || closing_time
        raise ArgumentError, "One or both schedules must be terminating to use #conflicts_with?"
      end
      terminating_schedule = if terminating?
        self
      elsif other_schedule.terminating?
        other_schedule
      else
        self
      end
      comparison_schedule = terminating_schedule.equal?(self) ? other_schedule : self
      terminating_schedule.each_occurrence do |occurrence|
        break if closing_time && occurrence.start_time > closing_time

        comparison = comparison_schedule.occurrences_between(
          occurrence.start_time,
          occurrence.end_time,
          spans: true
        )
        return true if comparison.any? do |other_occurrence|
          occurrence.intersects?(other_occurrence) || occurrence.start_time == other_occurrence.start_time
        end
      end
      false
    end

    # Determine if the schedule occurs at a specific time
    def occurs_at?(time)
      occurs_between?(time, time)
    end

    # Get the first n occurrences, or the first occurrence if n is skipped
    def first(n = nil)
      occurrences = enumerate_occurrences(start_time).take(n || 1)
      n.nil? ? occurrences.first : occurrences
    end

    # Get the final n occurrences of a terminating schedule
    # or the final one if no n is given
    def last(n = nil)
      require_terminating_rules
      occurrences = enumerate_occurrences(start_time).to_a
      n.nil? ? occurrences.last : occurrences[-n..]
    end

    # String serialization
    def to_s
      pieces = []
      rd = recurrence_times_with_start_time - extimes
      pieces.concat rd.sort.map { |t| IceCube::I18n.l(t, format: IceCube.to_s_time_format) }
      pieces.concat rrules.map { |t| t.to_s }
      pieces.concat exrules.map { |t| IceCube::I18n.t("ice_cube.not", target: t.to_s) }
      pieces.concat extimes.sort.map { |t|
        target = IceCube::I18n.l(t, format: IceCube.to_s_time_format)
        IceCube::I18n.t("ice_cube.not_on", target: target)
      }
      pieces.join(IceCube::I18n.t("ice_cube.pieces_connector"))
    end

    # Serialize this schedule to_ical
    def to_ical(force_utc = false)
      pieces = []
      calendar_duration = @duration.is_a?(CalendarDuration)
      pieces << "DTSTART#{IcalBuilder.ical_format(start_time, force_utc, calendar_duration)}"
      pieces.concat recurrence_rules.map { |r| "RRULE:#{r.to_ical}" }
      pieces.concat exception_rules.map { |r| "EXRULE:#{r.to_ical}" }
      pieces.concat recurrence_times_without_start_time.map { |t| "RDATE#{IcalBuilder.ical_format(t, force_utc, calendar_duration)}" }
      pieces.concat exception_times.map { |t| "EXDATE#{IcalBuilder.ical_format(t, force_utc, calendar_duration)}" }
      if calendar_duration
        pieces << "DURATION:#{ical_duration}"
        if duration.ambiguous_policy != :raise
          pieces << "X-ICECUBE-AMBIGUOUS-TIME:#{duration.ambiguous_policy}"
        end
        if duration.nonexistent_policy != :raise
          pieces << "X-ICECUBE-NONEXISTENT-TIME:#{duration.nonexistent_policy}"
        end
      elsif end_time
        pieces << "DTEND#{IcalBuilder.ical_format(end_time, force_utc)}"
      end
      pieces.join("\n")
    end

    # Load the schedule from ical
    def self.from_ical(ical, options = {})
      IcalParser.schedule_from_ical(ical, options)
    end

    # Hook for YAML.dump, enables to_yaml
    def encode_with(coder)
      coder.represent_object nil, to_hash
    end

    # Load the schedule from yaml
    def self.from_yaml(yaml, options = {})
      YamlParser.new(yaml).to_schedule do |schedule|
        Deprecated.schedule_options(schedule, options)
        yield schedule if block_given?
      end
    end

    # Convert the schedule to a hash
    def to_hash
      data = {}
      data[:start_time] = TimeUtil.serialize_time(start_time)
      data[:start_date] = data[:start_time] if IceCube.compatibility <= 11
      data[:duration] = duration_for_serialization if @duration
      data[:ambiguous_time] = duration.ambiguous_policy.to_s if @duration.is_a?(CalendarDuration)
      data[:nonexistent_time] = duration.nonexistent_policy.to_s if @duration.is_a?(CalendarDuration)
      data[:end_time] = TimeUtil.serialize_time(end_time) if end_time && !@duration
      data[:rrules] = recurrence_rules.map(&:to_hash)
      data[:exrules] = exception_rules.map(&:to_hash) if exception_rules.any?
      data[:rtimes] = recurrence_times.map do |rt|
        TimeUtil.serialize_time(rt)
      end
      data[:extimes] = exception_times.map do |et|
        TimeUtil.serialize_time(et)
      end
      data
    end
    alias_method :to_h, :to_hash

    # Load the schedule from a hash
    def self.from_hash(original_hash, options = {})
      HashParser.new(original_hash).to_schedule do |schedule|
        Deprecated.schedule_options(schedule, options)
        yield schedule if block_given?
      end
    end

    # Determine if the schedule will end
    # @return [Boolean] true if ending, false if repeating forever
    def terminating?
      @all_recurrence_rules.all?(&:terminating?)
    end

    def hash
      [
        TimeUtil.hash(start_time), duration_for_equality,
        *@all_recurrence_rules.map(&:hash).sort!,
        *@all_exception_rules.map(&:hash).sort!
      ].hash
    end

    def eql?(other)
      hash == other.hash
    end
    alias_method :==, :eql?

    def self.dump(schedule)
      return schedule if schedule.nil? || schedule == ""
      schedule.to_yaml
    end

    def self.load(yaml)
      return yaml if yaml.nil? || yaml == ""
      from_yaml(yaml)
    end

    private

    def ical_duration
      duration.is_a?(CalendarDuration) ? duration.to_ical : IcalBuilder.ical_duration(duration)
    end

    def duration_for_serialization
      return duration.to_s if duration.is_a?(CalendarDuration)

      duration
    end

    def duration_for_equality
      if duration.is_a?(CalendarDuration)
        [duration.to_s, duration.ambiguous_policy, duration.nonexistent_policy]
      else
        duration
      end
    end

    # Reset all rules for another run
    def reset
      @all_recurrence_rules.each(&:reset)
      @all_exception_rules.each(&:reset)
    end

    # Find all of the occurrences for the schedule between opening_time
    # and closing_time
    # Iteration is unrolled in pairs to skip duplicate times in end of DST
    def enumerate_occurrences(opening_time, closing_time = nil, options = {})
      opening_time = TimeUtil.match_zone(opening_time, start_time)
      closing_time = TimeUtil.match_zone(closing_time, start_time)
      opening_time += TimeUtil.subsec(start_time) - TimeUtil.subsec(opening_time)
      opening_time = start_time if opening_time < start_time
      spans = options[:spans] == true && !duration.zero?
      point_query = closing_time == opening_time
      Enumerator.new do |yielder|
        reset
        t1 = full_required? ? start_time : opening_time
        t1 -= duration_span_lookback if spans
        t1 = start_time if t1 < start_time
        loop do
          break unless (t0 = next_time(t1, closing_time))
          break if closing_time && t0 > closing_time
          starts_before_closing = closing_time.nil? || t0.start_time <= closing_time
          within_point_boundary = !point_query || t0.start_time < closing_time
          if spans ? (t0.end_time > opening_time && starts_before_closing && within_point_boundary) : (t0 >= opening_time)
            yielder << (block_given? ? yield(t0) : t0)
          end
          t1 = t0 + 1
        end
      end
    end

    # Get the next time after (or including) a specific time
    def next_time(time, closing_time)
      loop do
        # Probe all rules without consuming counts so we can pick the earliest
        # candidate, then charge counts only to rules that emitted that time.
        min_time = nil
        candidates = []
        recurrence_rules_with_implicit_start_occurrence.each do |rule|
          candidate = rule.next_time(time, start_time, min_time || closing_time, increment: false)
          next unless candidate
          candidates << [rule, candidate]
          min_time = candidate if min_time.nil? || candidate < min_time
        rescue StopIteration
          next
        end
        break unless min_time
        candidates.each do |rule, candidate|
          rule.increment_uses if candidate == min_time && rule.respond_to?(:increment_uses)
        end
        next (time = min_time + 1) if exception_time?(min_time)
        break Occurrence.new(min_time, end_time_for(min_time))
      end
    end

    def nominal_duration
      duration.is_a?(CalendarDuration) ? duration.nominal_seconds : duration
    end

    def duration_span_lookback
      duration.is_a?(CalendarDuration) ? nominal_duration * 2 : nominal_duration
    end

    # Indicate if any rule needs to be run from the start of time
    # If we have rules with counts, we need to walk from the beginning of time
    def full_required?
      @all_recurrence_rules.any?(&:full_required?) ||
        @all_exception_rules.any?(&:full_required?)
    end

    # Return a boolean indicating whether or not a specific time
    # is excluded from the schedule
    def exception_time?(time)
      @all_exception_rules.any? do |rule|
        rule.on?(time, start_time)
      end
    end

    def require_terminating_rules
      return true if terminating?
      method_name = caller(1..1).first.split(" ").last
      raise ArgumentError, "All recurrence rules must specify .until or .count to use #{method_name}"
    end

    def implicit_start_occurrence_rule
      SingleOccurrenceRule.new(start_time)
    end

    def recurrence_times_without_start_time
      recurrence_times.reject { |t| t == start_time }
    end

    def recurrence_times_with_start_time
      if recurrence_rules.empty?
        [start_time].concat recurrence_times_without_start_time
      else
        recurrence_times
      end
    end

    def recurrence_rules_with_implicit_start_occurrence
      if recurrence_rules.empty?
        [implicit_start_occurrence_rule].concat @all_recurrence_rules
      else
        @all_recurrence_rules
      end
    end
  end
end

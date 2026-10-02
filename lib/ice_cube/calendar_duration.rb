module IceCube
  class CalendarDuration
    include Comparable

    PATTERN = /\AP(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/

    attr_reader :weeks, :days, :hours, :minutes, :seconds

    def self.parse(value, ambiguous: :raise, nonexistent: :raise)
      return value.dup if value.is_a?(CalendarDuration)

      match = PATTERN.match(value.to_s.strip)
      raise ArgumentError, "Invalid calendar duration: #{value.inspect}" unless match

      values = match.captures.map { |number| number.to_i }
      if values.first > 0 && values[1..].any? { |number| number > 0 }
        raise ArgumentError, "Week durations cannot be combined with other units"
      end

      new(weeks: values[0], days: values[1], hours: values[2],
          minutes: values[3], seconds: values[4],
          ambiguous: ambiguous, nonexistent: nonexistent)
    end

    def initialize(weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0,
                   ambiguous: :raise, nonexistent: :raise)
      @weeks = weeks
      @days = days
      @hours = hours
      @minutes = minutes
      @seconds = seconds
      @ambiguous = ambiguous
      @nonexistent = nonexistent
      freeze
    end

    def calendar_days
      weeks * 7 + days
    end

    def exact_seconds
      hours * ONE_HOUR + minutes * ONE_MINUTE + seconds
    end

    def nominal_seconds
      calendar_days * ONE_DAY + exact_seconds
    end
    alias_method :to_i, :nominal_seconds

    def zero?
      nominal_seconds.zero?
    end

    def ambiguous_policy
      @ambiguous
    end

    def nonexistent_policy
      @nonexistent
    end

    def after(time)
      apply(time, :after)
    end

    def before(time)
      apply(time, :before)
    end

    def to_s
      result = "P"
      result << "#{weeks}W" if weeks > 0
      result << "#{days}D" if days > 0
      time_part = ""
      time_part << "#{hours}H" if hours > 0
      time_part << "#{minutes}M" if minutes > 0
      time_part << "#{seconds}S" if seconds > 0
      result << "T#{time_part}" unless time_part.empty?
      result
    end
    alias_method :to_ical, :to_s

    def <=>(other)
      return unless other.is_a?(CalendarDuration)
      values <=> other.values
    end

    def hash
      [self.class, values].hash
    end

    def eql?(other)
      other.is_a?(CalendarDuration) &&
        values == other.values &&
        ambiguous_policy == other.ambiguous_policy &&
        nonexistent_policy == other.nonexistent_policy
    end
    alias_method :==, :eql?

    protected

    def values
      [weeks, days, hours, minutes, seconds, ambiguous_policy, nonexistent_policy]
    end

    private

    def apply(time, direction)
      sign = direction == :after ? 1 : -1
      return TimeUtil.add_exact_seconds(time, sign * nominal_seconds) if weeks.zero? && days.zero?

      day_target = advance_calendar_days(time, sign * calendar_days)
      resolved = TimeUtil.resolve_local(day_target, time,
                                       ambiguous: ambiguous_policy,
                                       nonexistent: nonexistent_policy)
      TimeUtil.add_exact_seconds(resolved, sign * exact_seconds)
    end

    def advance_calendar_days(time, amount)
      target = Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec)
      target + TimeUtil.subsec(time) + amount * ONE_DAY
    end
  end
end

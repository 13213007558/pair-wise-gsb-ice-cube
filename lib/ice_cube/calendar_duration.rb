require "strscan"

module IceCube
  # Raised when a calendar duration lands on a local time that does not
  # exist (spring-forward gap) or is repeated (fall-back overlap) and the
  # configured policy is :raise.
  class InvalidLocalTimeError < ArgumentError
    attr_reader :time, :reason

    def initialize(time, reason)
      @time = time
      @reason = reason
      super("#{time.strftime("%Y-%m-%d %H:%M:%S")} #{reason} in #{TimeUtil.zone_name(time)}")
    end
  end

  # A duration expressed in calendar units.
  #
  # Weeks and days advance the local clock: adding one day keeps the same
  # wall-clock hour even across a DST transition. Hours, minutes and seconds
  # are exact elapsed time.
  #
  #   IceCube::CalendarDuration.new(days: 1)   # P1D
  #   IceCube::CalendarDuration.new(hours: 24) # PT24H
  #
  # Policies for local times that do not exist or that occur twice:
  #
  # +nonexistent+ (spring-forward gap):
  #   - +:raise+ (default) raises InvalidLocalTimeError
  #   - +:forward+ moves to the first valid instant after the gap
  #   - +:backward+ moves to the last valid instant before the gap
  #
  # +ambiguous+ (fall-back overlap):
  #   - +:raise+ (default) raises InvalidLocalTimeError
  #   - +:earlier+ picks the first occurrence (daylight-saving offset)
  #   - +:later+ picks the second occurrence (standard offset)
  class CalendarDuration
    UNITS = %i[weeks days hours minutes seconds].freeze
    NONEXISTENT_POLICIES = %i[raise forward backward].freeze
    AMBIGUOUS_POLICIES = %i[raise earlier later].freeze

    # Matches the iCalendar / ISO 8601 duration grammar used by DURATION.
    def self.parse(string)
      scanner = StringScanner.new(string.to_s.strip.upcase)
      scanner.getch == "P" or raise ArgumentError, "invalid duration: #{string.inspect}"
      values = {weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0}
      date_units = {"W" => :weeks, "D" => :days}
      time_units = {"H" => :hours, "M" => :minutes, "S" => :seconds}
      until scanner.eos?
        break if scanner.match?(/T/)
        token = scanner.scan(/\d+[WD]/) or raise ArgumentError, "invalid duration: #{string.inspect}"
        values[date_units.fetch(token[-1])] += token[0..-2].to_i
      end
      if scanner.scan(/T/)
        until scanner.eos?
          token = scanner.scan(/\d+[HMS]/) or raise ArgumentError, "invalid duration: #{string.inspect}"
          values[time_units.fetch(token[-1])] += token[0..-2].to_i
        end
      end
      scanner.eos? or raise ArgumentError, "invalid duration: #{string.inspect}"
      new(**values)
    end

    class << self
      alias_method :from_ical, :parse
    end

    attr_reader(*UNITS)
    attr_reader :nonexistent, :ambiguous

    def initialize(weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0,
                   nonexistent: :raise, ambiguous: :raise)
      @weeks = weeks.to_i
      @days = days.to_i
      @hours = hours.to_i
      @minutes = minutes.to_i
      @seconds = seconds.to_i
      unless NONEXISTENT_POLICIES.include?(nonexistent)
        raise ArgumentError, "invalid nonexistent policy: #{nonexistent.inspect}"
      end
      unless AMBIGUOUS_POLICIES.include?(ambiguous)
        raise ArgumentError, "invalid ambiguous policy: #{ambiguous.inspect}"
      end
      @nonexistent = nonexistent
      @ambiguous = ambiguous
    end

    # Build one from an ActiveSupport::Duration (e.g. 1.day, 24.hours).
    def self.from_active_support(duration)
      parts = duration.parts
      unknown = parts.keys - UNITS
      if unknown.any?
        raise ArgumentError, "cannot use #{unknown.inspect} in a calendar duration"
      end
      new(**parts)
    end

    def calendar_units?
      weeks > 0 || days > 0
    end

    def zero?
      UNITS.all? { |unit| public_send(unit).zero? }
    end

    # Elapsed seconds of the clock-time portion. Calendar days and weeks are
    # not a fixed number of seconds across DST transitions.
    def clock_seconds
      hours * IceCube::ONE_HOUR + minutes * IceCube::ONE_MINUTE + seconds
    end

    # Elapsed seconds on days without a DST transition (7/24 hours per day).
    def to_i
      (weeks * 7 + days) * IceCube::ONE_DAY + clock_seconds
    end
    alias_method :to_seconds, :to_i

    # End time obtained by applying this duration to the given start time.
    def apply_to(time)
      if calendar_units?
        wall_components = [time.year, time.month, time.day + days + weeks * 7,
                           time.hour, time.min, time.sec]
        resolved = TimeUtil.resolve_local(wall_components, nonexistent, ambiguous, time)
      else
        resolved = time
      end
      resolved + clock_seconds + TimeUtil.subsec(time)
    end

    # iCalendar / ISO 8601 representation, e.g. P1D or PT24H.
    def to_ical
      return "PT0S" if zero?
      repr = "P"
      repr << "#{weeks}W" if weeks > 0
      repr << "#{days}D" if days > 0
      clock = +""
      clock << "#{hours}H" if hours > 0
      clock << "#{minutes}M" if minutes > 0
      clock << "#{seconds}S" if seconds > 0
      repr << "T#{clock}" unless clock.empty?
      repr
    end
    alias_method :to_s, :to_ical

    def to_hash
      data = {}
      UNITS.each { |unit| data[unit] = public_send(unit) }
      data[:nonexistent] = nonexistent unless nonexistent == :raise
      data[:ambiguous] = ambiguous unless ambiguous == :raise
      data
    end

    def self.from_hash(hash)
      data = hash.is_a?(FlexibleHash) ? hash : IceCube::FlexibleHash.new(hash)
      new(weeks: data[:weeks] || 0, days: data[:days] || 0,
          hours: data[:hours] || 0, minutes: data[:minutes] || 0,
          seconds: data[:seconds] || 0,
          nonexistent: data[:nonexistent]&.to_sym || :raise,
          ambiguous: data[:ambiguous]&.to_sym || :raise)
    end

    def ==(other)
      case other
      when CalendarDuration
        UNITS.all? { |unit| public_send(unit) == other.public_send(unit) } &&
          nonexistent == other.nonexistent && ambiguous == other.ambiguous
      when Numeric
        to_i == other
      else
        false
      end
    end
    alias_method :eql?, :==

    def hash
      [UNITS.map { |unit| public_send(unit) }, nonexistent, ambiguous].hash
    end

    def inspect
      "#<IceCube::CalendarDuration #{to_ical}>"
    end
  end
end

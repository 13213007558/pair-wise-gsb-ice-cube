require "date"
require "time"

module IceCube
  module TimeUtil
    extend Deprecated

    DAYS = {
      sunday: 0, monday: 1, tuesday: 2, wednesday: 3,
      thursday: 4, friday: 5, saturday: 6
    }

    ICAL_DAYS = {
      "SU" => :sunday, "MO" => :monday, "TU" => :tuesday, "WE" => :wednesday,
      "TH" => :thursday, "FR" => :friday, "SA" => :saturday
    }

    MONTHS = {
      january: 1, february: 2, march: 3, april: 4, may: 5,
      june: 6, july: 7, august: 8, september: 9, october: 10,
      november: 11, december: 12
    }

    CLOCK_VALUES = [:year, :month, :day, :hour, :min, :sec]

    # Provides a Time.now without the usec, in the reference zone or utc offset
    def self.now(reference = Time.now)
      match_zone(Time.at(Time.now.to_i), reference)
    end

    def self.build_in_zone(args, reference)
      if reference.respond_to?(:time_zone)
        reference.time_zone.local(*args)
      elsif reference.utc?
        Time.utc(*args)
      elsif reference.zone
        Time.local(*args)
      else
        Time.new(*args, reference.utc_offset)
      end
    end

    def self.match_zone(input_time, reference)
      return unless (time = ensure_time(input_time, reference))
      time = if reference.respond_to? :time_zone
        time.in_time_zone(reference.time_zone)
      elsif reference.utc?
        time.getgm
      elsif reference.zone
        time.getlocal
      else
        time.getlocal(reference.utc_offset)
      end
      (Date === input_time) ? beginning_of_date(time, reference) : time
    end

    # Ensure that this is either nil, or a time
    def self.ensure_time(time, reference = nil, date_eod = false)
      case time
      when DateTime
        warn "IceCube: DateTime support is deprecated (please use Time) at: #{caller(3..3).first}"
        Time.local(time.year, time.month, time.day, time.hour, time.min, time.sec)
      when Date
        if date_eod
          end_of_date(time, reference)
        elsif reference
          build_in_zone([time.year, time.month, time.day], reference)
        else
          time.to_time
        end
      else
        time
      end
    end

    # Ensure that this is either nil, or a date
    def self.ensure_date(date)
      case date
      when Date then date
      else
        Date.new(date.year, date.month, date.day)
      end
    end

    # Normalize a duration option: Numbers stay elapsed seconds, calendar
    # durations and ActiveSupport::Duration values become CalendarDuration.
    def self.coerce_duration(value)
      case value
      when nil, Numeric, IceCube::CalendarDuration
        value
      when String
        IceCube::CalendarDuration.parse(value)
      else
        if defined?(ActiveSupport::Duration) && value.is_a?(ActiveSupport::Duration)
          IceCube::CalendarDuration.from_active_support(value)
        else
          raise ArgumentError, "invalid duration: #{value.inspect}"
        end
      end
    end

    # Serialize a time appropriate for storing
    def self.serialize_time(time)
      case time
      when Time, Date
        if time.respond_to?(:time_zone)
          {time: time.utc, zone: time.time_zone.name}
        else
          time
        end
      when DateTime
        Time.local(time.year, time.month, time.day, time.hour, time.min, time.sec)
      else
        raise ArgumentError, "cannot serialize #{time.inspect}, expected a Time"
      end
    end

    # Deserialize a time serialized with serialize_time or in ISO8601 string format
    def self.deserialize_time(time_or_hash)
      case time_or_hash
      when Time, Date
        time_or_hash
      when DateTime
        Time.local(time.year, time.month, time.day, time.hour, time.min, time.sec)
      when Hash
        hash = FlexibleHash.new(time_or_hash)
        hash[:time].in_time_zone(hash[:zone])
      when String
        Time.parse(time_or_hash)
      end
    end

    # Get a more precise equality for time objects
    # Ruby provides a Time#hash method, but it fails to account for UTC
    # offset (so the current date may be different) or DST rules (so the
    # hour may be wrong for different schedule occurrences)
    def self.hash(time)
      [time, time.utc_offset, time.zone].hash
    end

    # Check the deserialized time offset string against actual local time
    # offset to try and preserve the original offset for plain Ruby Time. If
    # the offset is the same as local we can assume the same original zone and
    # keep it.  If it was serialized with a different offset than local TZ it
    # will lose the zone and not support DST.
    def self.restore_deserialized_offset(time, orig_offset_str)
      return time if time.respond_to?(:time_zone) ||
        time.getlocal(orig_offset_str).utc_offset == time.utc_offset
      warn "IceCube: parsed Time from nonlocal TZ. Use ActiveSupport to fix DST at: #{caller(1..1).first}"
      time.localtime(orig_offset_str)
    end

    # Get the beginning of a date
    def self.beginning_of_date(date, reference = Time.now)
      build_in_zone([date.year, date.month, date.day, 0, 0, 0], reference)
    end

    # Get the end of a date
    def self.end_of_date(date, reference = Time.now)
      build_in_zone([date.year, date.month, date.day, 23, 59, 59], reference)
    end

    # Convert a symbol to a numeric month
    def self.sym_to_month(sym)
      MONTHS.fetch(sym) do |k|
        MONTHS.values.detect { |i| i.to_s == k.to_s } or
          raise ArgumentError, "Expecting Integer or Symbol value for month. " \
                               "No such month: #{k.inspect}"
      end
    end
    deprecated_alias :symbol_to_month, :sym_to_month

    # Convert a symbol to a wday number
    def self.sym_to_wday(sym)
      DAYS.fetch(sym) do |k|
        DAYS.values.detect { |i| i.to_s == k.to_s } or
          raise ArgumentError, "Expecting Integer or Symbol value for weekday. " \
                               "No such weekday: #{k.inspect}"
      end
    end
    deprecated_alias :symbol_to_day, :sym_to_wday

    # Convert wday number to day symbol
    def self.wday_to_sym(wday)
      return wday if DAYS.key? wday
      DAYS.invert.fetch(wday) do |i|
        raise ArgumentError, "Expecting Integer value for weekday. " \
                             "No such wday number: #{i.inspect}"
      end
    end

    # Convert weekday from base sunday to the schedule's week start.
    def self.normalize_wday(wday, week_start)
      (wday - sym_to_wday(week_start)) % 7
    end
    deprecated_alias :normalize_weekday, :normalize_wday

    def self.ical_day_to_symbol(str)
      day = ICAL_DAYS[str]
      raise ArgumentError, "Invalid day: #{str}" if day.nil?
      day
    end

    # Return the count of the number of times wday appears in the month,
    # and which of those time falls on
    def self.which_occurrence_in_month(time, wday)
      first_occurrence = ((7 - Time.utc(time.year, time.month, 1).wday) + time.wday) % 7 + 1
      this_weekday_in_month_count = ((days_in_month(time) - first_occurrence + 1) / 7.0).ceil
      nth_occurrence_of_weekday = (time.mday - first_occurrence) / 7 + 1
      [nth_occurrence_of_weekday, this_weekday_in_month_count]
    end

    # Get the days in the month for +time
    def self.days_in_month(time)
      date = Date.new(time.year, time.month, 1)
      ((date >> 1) - date).to_i
    end

    # Get the days in the following month for +time
    def self.days_in_next_month(time)
      date = Date.new(time.year, time.month, 1) >> 1
      ((date >> 1) - date).to_i
    end

    # Count the number of days to the same day of the next month without
    # overflowing shorter months
    def self.days_to_next_month(time)
      date = Date.new(time.year, time.month, time.day)
      ((date >> 1) - date).to_i
    end

    # Get a day of the month in the month of a given time without overflowing
    # into the next month. Accepts days from positive (start of month forward) or
    # negative (from end of month)
    def self.day_of_month(value, date)
      if value.to_i > 0
        [value, days_in_month(date)].min
      else
        [1 + days_in_month(date) + value, 1].max
      end
    end

    # Number of days in a year
    def self.days_in_year(time)
      date = Date.new(time.year, 1, 1)
      ((date >> 12) - date).to_i
    end

    # Number of days to n years
    def self.days_in_n_years(time, year_distance)
      date = Date.new(time.year, time.month, time.day)
      ((date >> year_distance * 12) - date).to_i
    end

    # The number of days in n months
    def self.days_in_n_months(time, month_distance)
      date = Date.new(time.year, time.month, time.day)
      ((date >> month_distance) - date).to_i
    end

    def self.dst_change(time)
      one_hour_ago = time - ONE_HOUR
      if time.dst? ^ one_hour_ago.dst?
        (time.utc_offset - one_hour_ago.utc_offset) / ONE_HOUR
      end
    end

    # Handle discrepancies between various time types
    # - Time has subsec
    # - DateTime does not
    # - ActiveSupport::TimeWithZone can wrap either type, depending on version
    #   or if `parse` or `now`/`local` was used to build it.
    def self.subsec(time)
      if time.respond_to?(:subsec)
        time.subsec
      elsif time.respond_to?(:sec_fraction)
        time.sec_fraction
      else
        0.0
      end
    end

    # Human readable zone name for error messages
    def self.zone_name(time)
      if time.respond_to?(:time_zone)
        time.time_zone.name
      else
        time.zone || "UTC#{time.utc_offset}"
      end
    end

    # Resolve a wall-clock time that may not exist (spring-forward gap) or
    # exist twice (fall-back overlap) using the given policies. See
    # CalendarDuration for the available policies.
    #
    # +wall+ is either a wall-clock time built in the target zone, or an
    # array of [year, month, day, hour, min, sec] plus a reference time for
    # the zone.
    def self.resolve_local(wall, nonexistent_policy, ambiguous_policy, reference = nil)
      time, components =
        if wall.is_a?(Array)
          reference = build_in_zone(wall, reference) unless reference
          [reference, wall]
        else
          [wall, same_wall_args(wall)]
        end
      if time.respond_to?(:time_zone)
        resolve_in_time_zone(time, components, nonexistent_policy, ambiguous_policy)
      elsif time.zone.nil? || time.utc?
        time
      else
        resolve_plain_time(time, components, nonexistent_policy, ambiguous_policy)
      end
    end

    def self.resolve_in_time_zone(time, components, nonexistent_policy, ambiguous_policy)
      tzinfo = time.time_zone.tzinfo
      wall = Time.utc(*components)
      periods = tzinfo.periods_for_local(wall)
      return time if periods.length == 1
      if periods.empty?
        raise IceCube::InvalidLocalTimeError.new(time, :nonexistent) if nonexistent_policy == :raise
        after = tzinfo.period_for_utc(wall + 86_400)
        gap_end = after.start_transition.at.to_time.utc
        before = tzinfo.period_for_utc(wall - 1)
        gap_start = gap_end - (after.utc_total_offset - before.utc_total_offset)
        utc = nonexistent_policy == :forward ? gap_end : gap_start
        match_zone(utc, time)
      else
        raise IceCube::InvalidLocalTimeError.new(time, :ambiguous) if ambiguous_policy == :raise
        period = ambiguous_policy == :earlier ? periods.first : periods.last
        match_zone(wall - period.utc_total_offset, time)
      end
    end
    private_class_method :resolve_in_time_zone

    # Plain Ruby Time: Time.local silently shifts a nonexistent wall time
    # forward and picks the earlier side of an overlap. Rebuild the wall
    # clocks one hour on either side to detect the two situations.
    def self.resolve_plain_time(time, components, nonexistent_policy, ambiguous_policy)
      reference = build_in_zone(components, time)
      unless same_wall_args(reference) == components
        raise IceCube::InvalidLocalTimeError.new(time, :nonexistent) if nonexistent_policy == :raise
        gap_length = reference - Time.new(*components, reference.utc_offset)
        return reference if nonexistent_policy == :forward
        return reference - gap_length
      end
      overlap = local_overlap(reference, components)
      if overlap
        raise IceCube::InvalidLocalTimeError.new(time, :ambiguous) if ambiguous_policy == :raise
        earlier, later = [reference, overlap].minmax
        return ambiguous_policy == :earlier ? earlier : later
      end
      reference
    end
    private_class_method :resolve_plain_time

    # Detect an overlap for plain Ruby Time and return the other occurrence
    # (Time.local at a repeated wall clock silently picks one side). The
    # other occurrence is the same wall clock at a different UTC offset that
    # is genuinely observed there. To distinguish that from a nearby gap,
    # verify the wall clocks one delta on each side exist under the probed
    # offset. Minute deltas cover half-hour DST changes (Lord Howe).
    def self.local_overlap(reference, components)
      1.upto(60) do |minutes|
        delta = minutes * ONE_MINUTE
        [reference.utc_offset - delta, reference.utc_offset + delta].each do |offset|
          candidate = Time.new(*components, offset)
          next unless same_wall_args(candidate) == components
          next unless candidate != reference && (candidate - reference).abs == delta
          next unless local_offset_in_effect?(candidate)
          surrounding = [-delta, delta].all? do |shift|
            adjacent = candidate + shift
            built = build_in_zone(same_wall_args(adjacent), candidate)
            built.utc_offset == offset && same_wall_args(built) == same_wall_args(adjacent)
          end
          return candidate if surrounding
        end
      end
      nil
    end
    private_class_method :local_overlap

    # True when the candidate's fixed UTC offset is actually observed in the
    # system zone at its UTC instant
    def self.local_offset_in_effect?(candidate)
      observed = Time.at(candidate.to_i)
      observed.utc_offset == candidate.utc_offset &&
        same_wall_args(observed) == same_wall_args(candidate)
    end
    private_class_method :local_offset_in_effect?

    def self.same_wall_args(time)
      [time.year, time.month, time.day, time.hour, time.min, time.sec]
    end
    private_class_method :same_wall_args

    # A utility class for safely moving time around
    class TimeWrapper
      def initialize(time, dst_adjust = true)
        @dst_adjust = dst_adjust
        @base = time
        @time = if dst_adjust
          Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec + TimeUtil.subsec(time))
        else
          time
        end
      end

      # Get the wrapped time back in its original zone & format
      def to_time
        return @time unless @dst_adjust
        parts = @time.year, @time.month, @time.day, @time.hour, @time.min, @time.sec + @time.subsec
        TimeUtil.build_in_zone(parts, @base)
      end

      # DST-safely add an interval of time to the wrapped time
      def add(type, val)
        type = :day if type == :wday
        @time += case type
        when :year then TimeUtil.days_in_n_years(@time, val) * ONE_DAY
        when :month then TimeUtil.days_in_n_months(@time, val) * ONE_DAY
        when :day then val * ONE_DAY
        when :hour then val * ONE_HOUR
        when :min then val * ONE_MINUTE
        when :sec then val
        end
      end

      # Clear everything below a certain type
      CLEAR_ORDER = [:sec, :min, :hour, :day, :month, :year]
      def clear_below(type)
        type = :day if type == :wday
        CLEAR_ORDER.each do |ptype|
          break if ptype == type
          send :"clear_#{ptype}"
        end
      end

      def hour=(value)
        @time += (value * ONE_HOUR) - (@time.hour * ONE_HOUR)
      end

      def min=(value)
        @time += (value * ONE_MINUTE) - (@time.min * ONE_MINUTE)
      end

      def sec=(value)
        @time += value - @time.sec
      end

      def clear_sec
        (@time.sec > 0) ? @time -= @time.sec : @time
      end

      def clear_min
        (@time.min > 0) ? @time -= (@time.min * ONE_MINUTE) : @time
      end

      def clear_hour
        (@time.hour > 0) ? @time -= (@time.hour * ONE_HOUR) : @time
      end

      # Move to the first of the month, 0 hours
      def clear_day
        (@time.day > 1) ? @time -= (@time.day - 1) * ONE_DAY : @time
      end

      # Clear to january 1st
      def clear_month
        @time -= ONE_DAY
        until @time.month == 12
          @time -= TimeUtil.days_in_month(@time) * ONE_DAY
        end
        @time += ONE_DAY
      end
    end
  end
end

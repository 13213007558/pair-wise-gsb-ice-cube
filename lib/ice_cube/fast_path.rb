require "date"

require "ice_cube/fast_path/date_sets"

module IceCube
  # Fast, non-enumerating access to occurrences for a restricted (but
  # common) class of schedules. Instead of walking every occurrence from
  # the schedule start, each recurrence rule is modeled as a closed-form
  # set of dates, occurrences up to any instant are counted in O(1) per
  # rule (Gregorian irregularities such as leap days and missing month
  # days are absorbed into fixed 400-year-period tables), and the
  # occurrence at a given index is located by binary searching on that
  # count. The work needed to answer #occurrence_at therefore grows with
  # the logarithm of the time span, not with the number of skipped
  # occurrences, and no historical occurrences are ever cached.
  #
  # Indices always refer to the deduplicated, exception-filtered sequence
  # of actual occurrences (the same sequence Schedule#each_occurrence
  # yields). COUNT and UNTIL limits keep applying to the rule that
  # declared them, exactly as during enumeration.
  #
  # Supported schedules:
  #
  # * +start_time+ at a fixed UTC offset of zero (no DST), on a whole
  #   second.
  # * One or more of DailyRule, WeeklyRule, MonthlyRule, YearlyRule using
  #   only +interval+, weekday selection via +day+ (weekly rules),
  #   +day_of_month+, +month_of_year+ (yearly rules), +count+ and +until+.
  # * Any (finite) number of explicit exception times (extimes).
  #
  # Anything else - sub-daily rules, +day_of_week+ / +day_of_year+ /
  # +by_set_pos+ / +hour_of_day+ style expansions, recurrence times
  # (rtimes), exception rules (exrules), or more than MAX_RULES recurrence
  # rules - raises IceCube::UnsupportedScheduleError rather than silently
  # returning a plausible-looking but wrong answer.
  class FastPath
    # Months in one 400-year Gregorian cycle.
    GREGORIAN_CYCLE_MONTHS = 4800
    # Days in one 400-year Gregorian cycle.
    GREGORIAN_CYCLE_DAYS = 146_097
    # Julian day number of 1970-01-01.
    EPOCH_JD = 2_440_588
    # Inclusion-exclusion over recurrence rules is exponential in the
    # number of rules, so keep the supported rule count modest.
    MAX_RULES = 8
    # Safety cap for generated period tables.
    MAX_TABLE_MONTHS = 1_000_000
    # Safety cap for expanded residue lists when intersecting rules.
    MAX_RESIDUES = 100_000

    # Number of times the global "occurrences up to t" function has been
    # evaluated by this instance. Exposed so callers (and tests) can
    # demonstrate that locating an occurrence takes logarithmic, not
    # linear, work in the number of skipped occurrences.
    attr_reader :evaluation_count

    # True when the schedule is eligible for the fast path.
    def self.supported?(schedule)
      new(schedule)
      true
    rescue UnsupportedScheduleError
      false
    end

    def initialize(schedule)
      @schedule = schedule
      @start_time = schedule.start_time
      @evaluation_count = 0
      validate_schedule!
      @start_i = @start_time.to_i
      @start_jd = civil_jd(@start_time)
      @tod = tod_seconds(@start_time)
      @duration = schedule.duration
      @rule_sets = schedule.recurrence_rules.map { |rule| build_rule_set(rule) }
      @extimes = schedule.exception_times.map { |t| t.to_i }.uniq.sort
      @intersections = {}
    end

    # The occurrence at +index+ (0-based) in the deduplicated,
    # exception-filtered occurrence sequence, or nil when the schedule
    # terminates before producing that many occurrences.
    def occurrence_at(index)
      unless index.is_a?(Integer)
        raise ArgumentError, "index must be an Integer, got #{index.inspect}"
      end
      if index < 0
        raise ArgumentError, "negative index #{index}: the fast path only " +                             "resolves zero-based, non-negative indices"
      end
      second = locate_second(index)
      return nil unless second
      time = TimeUtil.match_zone(Time.at(second), @start_time)
      Occurrence.new(time, time + @duration)
    end

    # Number of actual occurrences in [opening_time, closing_time]
    # (inclusive of both ends), computed without enumerating them.
    def count_between(opening_time, closing_time)
      opening = TimeUtil.match_zone(opening_time, @start_time)
      closing = TimeUtil.match_zone(closing_time, @start_time)
      unless opening && closing
        raise ArgumentError, "Time required, got #{opening_time.inspect} and #{closing_time.inspect}"
      end
      return 0 if closing.to_i < opening.to_i
      # Occurrences land on whole seconds; an opening time with a subsecond
      # part excludes an occurrence falling on its own second.
      low = opening.to_i
      low -= 1 if TimeUtil.subsec(opening).zero?
      count_up_to(closing.to_i) - count_up_to(low)
    end

    # Shared Gregorian cycle tables: days in each month of a 400-year
    # cycle, and the Julian day offset of each month's first day.
    def self.gregorian_tables
      @gregorian_tables ||= begin
        base = Date.new(0, 1, 1, Date::GREGORIAN).jd
        dims = []
        offsets = []
        GREGORIAN_CYCLE_MONTHS.times do |mi|
          year, month = mi.divmod(12)
          dims << Date.new(year, month + 1, -1, Date::GREGORIAN).day
          offsets << Date.new(year, month + 1, 1, Date::GREGORIAN).jd - base
        end
        [dims.freeze, offsets.freeze, base]
      end
    end

    # Days in the month with (zero-based) month index +mi+.
    def self.dim_of_month(mi)
      gregorian_tables[0][mi % GREGORIAN_CYCLE_MONTHS]
    end

    # Julian day number of the first day of month index +mi+.
    def self.jd_of_month(mi)
      _, offsets, base = gregorian_tables
      cycles, rem = mi.divmod(GREGORIAN_CYCLE_MONTHS)
      base + cycles * GREGORIAN_CYCLE_DAYS + offsets[rem]
    end

    private

    # -- schedule validation -------------------------------------------------

    ALLOWED_VALIDATIONS = {
      daily: %i[interval count until base_hour base_min base_sec],
      weekly: %i[interval count until base_wday base_hour base_min base_sec day],
      monthly: %i[interval count until base_day base_hour base_min base_sec day_of_month],
      yearly: %i[interval count until base_month base_day base_hour base_min base_sec month_of_year day_of_month]
    }.freeze

    def validate_schedule!
      unless fixed_utc?(@start_time)
        raise UnsupportedScheduleError, "fast path requires the schedule " +                                        "start_time to be fixed UTC (utc_offset 0, no DST)"
      end
      unless TimeUtil.subsec(@start_time).zero?
        raise UnsupportedScheduleError, "fast path requires a whole-second start_time"
      end
      if @schedule.recurrence_rules.empty?
        raise UnsupportedScheduleError, "fast path requires at least one recurrence rule"
      end
      if @schedule.recurrence_rules.size > MAX_RULES
        raise UnsupportedScheduleError, "fast path supports at most #{MAX_RULES} recurrence rules"
      end
      if @schedule.recurrence_times.any?
        raise UnsupportedScheduleError, "fast path does not support recurrence times (rtimes)"
      end
      if @schedule.exception_rules.any?
        raise UnsupportedScheduleError, "fast path supports explicit exception " +                                        "times (extimes) only, not exception rules"
      end
    end

    def fixed_utc?(time)
      if time.respond_to?(:time_zone)
        %w[UTC Etc/UTC Etc/Universal Zulu].include?(time.time_zone.name)
      else
        time.utc_offset == 0
      end
    end

    # -- rule modeling -------------------------------------------------------

    def build_rule_set(rule)
      date_set =
        case rule
        when DailyRule then build_daily(rule)
        when WeeklyRule then build_weekly(rule)
        when MonthlyRule then build_monthly(rule)
        when YearlyRule then build_yearly(rule)
        else
          raise UnsupportedScheduleError, "#{rule.class} is not supported by " +                                          "the fast path (only daily, weekly, monthly and yearly rules)"
        end
      RuleSet.new(date_set, effective_end_i(rule, date_set), @tod)
    end

    def check_validations(rule, kind)
      allowed = ALLOWED_VALIDATIONS.fetch(kind)
      rule.validations.each_key do |key|
        next if allowed.include?(key)
        raise UnsupportedScheduleError, "#{rule.class} with a '#{key}' " +                                        "validation is not supported by the fast path"
      end
    end

    def build_daily(rule)
      check_validations(rule, :daily)
      interval = rule.base_interval_validation.interval
      APSet.new([@start_jd % interval], interval)
    end

    def build_weekly(rule)
      check_validations(rule, :weekly)
      interval = rule.base_interval_validation.interval
      week_start = rule.week_start
      day_validations = rule.validations[:day]
      wdays = day_validations ? day_validations.map(&:day) : [@start_time.wday]
      period = 7 * interval
      week_start_jd = @start_jd - TimeUtil.normalize_wday(@start_time.wday, week_start)
      residues = wdays.map { |wd|
        (week_start_jd + TimeUtil.normalize_wday(wd, week_start)) % period
      }.uniq.sort
      APSet.new(residues, period)
    end

    def build_monthly(rule)
      check_validations(rule, :monthly)
      interval = rule.base_interval_validation.interval
      month_index = @start_time.year * 12 + @start_time.month - 1
      constraint = MonthConstraint.new(
        m_mod: interval, m_res: month_index % interval,
        months: nil, y_mod: 1, y_res: 0,
        dayspec: dayspec_for(rule)
      )
      MonthSet.new(constraint)
    end

    def build_yearly(rule)
      check_validations(rule, :yearly)
      interval = rule.base_interval_validation.interval
      month_validations = rule.validations[:month_of_year]
      months = month_validations ? month_validations.map(&:month) : [@start_time.month]
      constraint = MonthConstraint.new(
        m_mod: 1, m_res: 0,
        months: months.map { |m| m - 1 }.uniq.sort,
        y_mod: interval, y_res: @start_time.year % interval,
        dayspec: dayspec_for(rule)
      )
      MonthSet.new(constraint)
    end

    def dayspec_for(rule)
      day_validations = rule.validations[:day_of_month]
      if day_validations
        days = day_validations.map(&:day)
        if days.any? { |d| d == 0 || d < -28 }
          raise UnsupportedScheduleError, "day_of_month values must be " +                                          "between -28 and 31 for the fast path (got #{days.inspect})"
        end
        ExplicitDaySpec.new(days)
      else
        LockedDaySpec.new(@start_time.day)
      end
    end

    # The last second at which the rule may still produce an occurrence,
    # combining its own COUNT and UNTIL limits. nil means unbounded.
    def effective_end_i(rule, date_set)
      ends = []
      if (until_time = rule.until_time)
        ends << TimeUtil.ensure_time(until_time, @start_time, true).to_i
      end
      if (count = rule.occurrence_count)
        if count <= 0
          ends << @start_i - 1
        else
          jd = date_set.nth_date(count - 1, @start_jd)
          ends << (jd ? jd_to_epoch(jd) : @start_i - 1)
        end
      end
      ends.empty? ? nil : ends.min
    end

    # -- counting ------------------------------------------------------------

    # Number of deduplicated, exception-filtered occurrences in
    # [start_time, second].
    def count_up_to(second)
      @evaluation_count += 1
      return 0 if second < @start_i
      date_hi = jd_of_epoch(second)
      date_hi -= 1 if second % ONE_DAY < @tod
      union_count(second, date_hi) - excluded_count(second)
    end

    # Inclusion-exclusion over the rules' date sets, each clipped to its
    # own effective end time.
    def union_count(second, date_hi)
      his = @rule_sets.map { |rs| rs.date_hi(second, date_hi) }
      total = 0
      (1...(1 << @rule_sets.size)).each do |mask|
        hi = date_hi
        bits = 0
        @rule_sets.each_with_index do |_, i|
          next unless mask[i] == 1
          bits += 1
          hi = his[i] if his[i] < hi
        end
        next if hi < @start_jd
        count = intersection(mask).count_dates(@start_jd, hi)
        total = bits.odd? ? total + count : total - count
      end
      total
    end

    def intersection(mask)
      @intersections[mask] ||= begin
        sets = []
        @rule_sets.each_with_index do |rs, i|
          sets << rs.date_set if mask[i] == 1
        end
        sets.reduce { |a, b| DateSet.intersect(a, b) }
      end
    end

    # Exception times that coincide with an occurrence of some rule.
    def excluded_count(second)
      count = 0
      @extimes.each do |extime|
        break if extime > second
        count += 1 if occurrence_second?(extime)
      end
      count
    end

    def occurrence_second?(second)
      return false if second < @start_i
      return false unless second % ONE_DAY == @tod
      jd = (second / ONE_DAY) + EPOCH_JD
      @rule_sets.any? { |rs| rs.occurs_on?(jd, second) }
    end

    # -- locating ------------------------------------------------------------

    # The smallest whole second whose occurrence count exceeds +index+;
    # that second is exactly the sought occurrence.
    def locate_second(index)
      hi = upper_bound_for(index)
      return nil unless hi
      return nil unless count_up_to(hi) > index
      lo = @start_i - 1
      while lo + 1 < hi
        mid = (lo + hi) / 2
        if count_up_to(mid) > index
          hi = mid
        else
          lo = mid
        end
      end
      hi
    end

    def upper_bound_for(index)
      ends = @rule_sets.map(&:end_i)
      return ends.max if ends.all?
      return nil if @rule_sets.all? { |rs| rs.date_set.empty? }
      # Unbounded schedule: bracket exponentially from a density estimate.
      span = (index + 1) * min_seconds_between
      span = ONE_DAY if span < ONE_DAY
      hi = @start_i + span
      hi = @start_i + (hi - @start_i) * 2 while count_up_to(hi) <= index
      hi
    end

    def min_seconds_between
      horizon_days = 4000
      @rule_sets.map { |rs|
        count = rs.date_set.count_dates(@start_jd, @start_jd + horizon_days)
        (horizon_days * ONE_DAY) / [count, 1].max
      }.min
    end

    # -- time helpers --------------------------------------------------------

    def civil_jd(time)
      Date.new(time.year, time.month, time.day, Date::GREGORIAN).jd
    end

    def tod_seconds(time)
      time.hour * 3600 + time.min * 60 + time.sec
    end

    def jd_of_epoch(second)
      (second / ONE_DAY) + EPOCH_JD
    end

    def jd_to_epoch(jd)
      (jd - EPOCH_JD) * ONE_DAY + @tod
    end
  end
end

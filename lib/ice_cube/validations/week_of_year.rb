module IceCube
  module Validations::WeekOfYear
    # Select occurrences by week number of the year (RFC 5545 BYWEEKNO).
    # Weeks are numbered per the rule's +week_start+ (WKST, default :monday);
    # week 1 is the first week with at least four days in the new year and may
    # begin in the previous calendar year. Negative week numbers count back
    # from the last week of the year that the week belongs to.
    def week_of_year(*weeks, week_start: nil)
      self.week_start = week_start if week_start
      weeks.flatten.each do |week|
        unless week.is_a?(Integer)
          raise ArgumentError, "expecting Integer value for week, got #{week.inspect}"
        end
        if week.zero? || week.abs > 53
          raise ArgumentError, "expecting value in [-53, -1] or [1, 53] for week, got #{week.inspect}"
        end
        validations_for(:week_of_year) << Validation.new(week, self)
      end
      clobber_base_validations(:month, :day, :wday)
      lock_weekday_to_start_time
      self
    end

    private

    # Without an explicit day selection (e.g. BYDAY), the weekday defaults to
    # the schedule start time's weekday, per RFC 5545. Any later day selection
    # clobbers this lock.
    def lock_weekday_to_start_time
      day_validations = [:day, :day_of_week, :day_of_month, :day_of_year]
      return if day_validations.any? { |key| validations.key?(key) }
      return if validations[:base_wday]&.any?
      validations_for(:base_wday) << Validations::ScheduleLock::Validation.new(:wday)
    end

    public

    class Validation
      attr_reader :week, :rule

      def initialize(week, rule)
        @week = week
        @rule = rule
      end

      def type
        :day
      end

      def dst_adjust?
        true
      end

      def validate(step_time, start_time)
        date = Date.new(step_time.year, step_time.month, step_time.day)
        week_start = rule.week_start
        start_of_week = TimeUtil.week_start_for(date, week_start)
        # A week belongs to the year holding at least four of its days.
        week_year = (start_of_week + 3).year
        first_week = TimeUtil.first_week_start(week_year, week_start)
        week_no = ((start_of_week - first_week) / 7).to_i + 1
        target = normalized_week(week_year, week_start)

        return if target && week_no == target

        # Move to the first day of the target week; weekday selection (BYDAY
        # or the start time's locked weekday) is re-applied from there.
        target_date = if target && week_no < target
          first_week + (target - 1) * 7
        else
          year = week_year + 1
          year += 1 until (target = normalized_week(year, week_start))
          TimeUtil.first_week_start(year, week_start) + (target - 1) * 7
        end
        (target_date - date).to_i
      end

      def build_s(builder)
        builder.piece(:week_of_year) << StringBuilder.nice_number(week)
      end

      def build_hash(builder)
        builder.validations_array(:week_of_year) << week
        builder[:week_start] = TimeUtil.sym_to_wday(rule.week_start)
      end

      def build_ical(builder)
        builder["BYWEEKNO"] << week
        unless rule.week_start == :monday # RFC 5545 default WKST
          wkst = IcalBuilder.fixnum_to_ical_day(TimeUtil.sym_to_wday(rule.week_start))
          builder["WKST"] << wkst unless builder["WKST"].include?(wkst)
        end
      end

      StringBuilder.register_formatter(:week_of_year) do |entries|
        str = StringBuilder.sentence(entries)
        sentence = IceCube::I18n.t("ice_cube.weeks_of_year", count: entries.size, segments: str)
        IceCube::I18n.t("ice_cube.on", sentence: sentence)
      end

      private

      # The week's position within +year+, normalized for negative values, or
      # nil when the year has no such week (e.g. week 53 in a 52-week year).
      def normalized_week(year, week_start)
        weeks = TimeUtil.weeks_in_year(year, week_start)
        number = (week > 0) ? week : weeks + week + 1
        number if (1..weeks).cover?(number)
      end
    end
  end
end

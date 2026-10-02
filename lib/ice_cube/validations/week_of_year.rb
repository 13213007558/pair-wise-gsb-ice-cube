module IceCube
  module Validations::WeekOfYear
    def self.first_week_start(year, week_start)
      first_day = Date.new(year, 1, 1)
      start = first_day - TimeUtil.normalize_wday(first_day.wday, week_start)
      start += 7 if (first_day - start).to_i > 3
      start
    end

    def self.weeks_in_year(year, week_start)
      ((first_week_start(year + 1, week_start) - first_week_start(year, week_start)).to_i / 7)
    end

    def self.week_year_for_interval(date, week_start)
      week_start_date = week_start_date(date, week_start)
      week_end_date = week_start_date + 6
      if week_end_date.month == 1 && week_end_date.day >= 4
        week_end_date.year
      else
        week_start_date.year
      end
    end

    def self.week_start_date(date, week_start)
      date - TimeUtil.normalize_wday(date.wday, week_start)
    end

    def week_of_year(*weeks, week_start: nil)
      week_start ||= @week_start || :monday
      week_start = TimeUtil.wday_to_sym(week_start)

      if validations[:day_of_year] || validations[:day_of_month] || validations[:day_of_week]
        raise ArgumentError, "BYWEEKNO cannot be combined with BYYEARDAY, BYMONTHDAY, or numbered BYDAY"
      end

      weeks.flatten.each do |week|
        unless week.is_a?(Integer) && week != 0 && week.abs.between?(1, 53)
          raise ArgumentError, "Expecting week number in [-53, -1] or [1, 53], got #{week.inspect}"
        end

        validations_for(:week_of_year) << Validation.new(week, week_start)
      end

      interval(@interval, week_start)
      clobber_base_validations(:month, :day, :wday)
      self
    end

    class Validation
      attr_reader :week, :week_start

      def initialize(week, week_start)
        @week = week
        @week_start = week_start
      end

      def type
        :day
      end

      def dst_adjust?
        true
      end

      def validate(step_time, start_time)
        date = step_time.to_date
        current_week_start = Validations::WeekOfYear.week_start_date(date, week_start)
        current_year, = week_number_for(current_week_start)
        current_target_start = week_start_for(current_year, week)
        return 0 if current_target_start == current_week_start

        target_year = current_year
        target_week = normalized_week(week, target_year)
        target_start = week_start_for(target_year, target_week)

        if (week.positive? && target_start <= current_week_start) ||
          (week.negative? && target_start < current_week_start)
          target_year += 1
          target_week = normalized_week(week, target_year)
          target_start = week_start_for(target_year, target_week)
        end

        (target_start - date).to_i
      end

      def build_s(builder)
        builder.piece(:week_of_year) << StringBuilder.nice_number(week)
      end

      def build_hash(builder)
        builder.validations_array(:week_of_year) << week
      end

      def build_ical(builder)
        builder["BYWEEKNO"] << week
      end

      StringBuilder.register_formatter(:week_of_year) do |entries|
        label = entries.size == 1 ? "week of the year" : "weeks of the year"
        "in #{StringBuilder.sentence(entries)} #{label}"
      end

      private

      def normalized_week(week, year)
        return week if week.positive?
        Validations::WeekOfYear.weeks_in_year(year, week_start) + week + 1
      end

      def week_number(week_start_date, year)
        ((week_start_date - Validations::WeekOfYear.first_week_start(year, week_start)).to_i / 7) + 1
      end

      def week_number_for(week_start_date)
        year = week_start_date.year
        number = week_number(week_start_date, year)
        return [year + 1, 1] if number > Validations::WeekOfYear.weeks_in_year(year, week_start)
        return [year - 1, normalized_week(-1, year - 1)] if number < 1
        [year, number]
      end

      def week_start_for(year, week_number)
        normalized = week_number.negative? ? normalized_week(week_number, year) : week_number
        Validations::WeekOfYear.first_week_start(year, week_start) + (normalized - 1) * 7
      end
    end
  end
end

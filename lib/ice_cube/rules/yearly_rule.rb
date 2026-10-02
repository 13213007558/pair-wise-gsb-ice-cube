module IceCube
  class YearlyRule < ValidatedRule
    # The week start (WKST) used to number weeks for week_of_year. Defaults
    # to :monday per RFC 5545.
    attr_reader :week_start

    include Validations::HourOfDay
    include Validations::MinuteOfHour
    include Validations::SecondOfMinute
    include Validations::DayOfMonth
    include Validations::DayOfWeek
    include Validations::Day
    include Validations::MonthOfYear
    include Validations::DayOfYear
    include Validations::WeekOfYear

    include Validations::YearlyInterval
    include Validations::YearlyBySetPos

    def initialize(interval = 1)
      @week_start = :monday
      super
      interval(interval)
      schedule_lock(:month, :day, :hour, :min, :sec)
      reset
    end

    def week_start=(value)
      @week_start = TimeUtil.wday_to_sym(value)
    end
  end
end

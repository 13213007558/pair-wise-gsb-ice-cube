module IceCube
  class YearlyRule < ValidatedRule
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

    attr_reader :week_start

    def initialize(interval = 1)
      super
      interval(interval)
      schedule_lock(:month, :day, :hour, :min, :sec)
      reset
    end

    private

    def validation_names
      names = super
      return names unless validations[:week_of_year]

      [:interval, :week_of_year] + (names - [:interval, :week_of_year])
    end
  end
end

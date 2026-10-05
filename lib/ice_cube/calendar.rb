require "date"
require "set"

module IceCube
  # A business calendar answers a single question for a given date: is it a
  # business day? Weekends are non-business days by default, but the caller
  # can provide a list of weekend make-up dates (e.g. a Sunday that is a
  # make-up workday) and holidays (weekdays that are taken off).
  #
  # A calendar is identified by a +version+, which is embedded in every
  # serialized rule. Deserialization looks the version up in the
  # IceCube.calendars registry and fails loudly when it is missing, so a rule
  # can never silently run against a different calendar than it was built
  # with.
  class BusinessCalendar
    attr_reader :version, :holidays, :working_weekends

    # +version+            - serializable identifier (typically a String)
    # +holidays+           - dates that are not business days
    # +working_weekends+   - weekend dates that are business days
    # +block+              - optional custom +business_day?(date)+ predicate
    def initialize(version:, holidays: [], working_weekends: [], &block)
      @version = version
      @holidays = holidays.map { |date| coerce_date(date) }.to_set
      @working_weekends = working_weekends.map { |date| coerce_date(date) }.to_set
      @predicate = block
    end

    # Business days are filtered first, then counted: holidays and regular
    # weekends are excluded, while make-up weekend days are included.
    def business_day?(date)
      date = coerce_date(date)
      return false if @holidays.include?(date)
      return true if @working_weekends.include?(date)
      if @predicate
        !!@predicate.call(date)
      else
        (1..5).cover?(date.wday)
      end
    end

    alias_method :working_day?, :business_day?

    private

    def coerce_date(value)
      case value
      when Date then value
      when Time, DateTime then value.to_date
      else Date.parse(value)
      end
    end
  end

  # Registry of calendars known to this process, keyed by their serializable
  # version identifier.
  module CalendarRegistry
    def register_calendar(calendar)
      version = calendar_version(calendar)
      @calendars ||= {}
      @calendars[version] = calendar
      calendar
    end

    def calendar_for_version(version)
      @calendars ||= {}
      @calendars.fetch(version) do
        raise CalendarVersionNotFound,
          "No IceCube business calendar is registered for version " \
          "#{version.inspect}. Register the caller-provided calendar with " \
          "IceCube.register_calendar before deserializing the rule."
      end
    end

    def registered_calendar?(calendar)
      version = calendar_version(calendar)
      @calendars ||= {}
      @calendars.key?(version)
    end

    def clear_calendars!
      @calendars = {}
    end

    private

    def calendar_version(calendar)
      unless calendar.respond_to?(:version)
        raise ArgumentError, "calendar must respond to #version"
      end
      version = calendar.version
      if version.nil? || (version.respond_to?(:empty?) && version.empty?)
        raise ArgumentError, "calendar version cannot be blank"
      end
      version
    end
  end

  extend CalendarRegistry
end

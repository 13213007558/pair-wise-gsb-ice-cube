require "set"

module IceCube
 # Raised when a serialized rule references a calendar version that has not
 # been registered with IceCube::BusinessCalendar.
 class UnknownCalendarVersion < StandardError; end

 # A BusinessCalendar answers whether a given date is a working day
 # ("business day"). Calendars are identified by a serializable +version+
 # string that travels with every rule, so a deserialized rule can always be
 # resolved against the exact calendar revision it was built with.
 #
 # Any object that responds to #business_day?(date) and #calendar_version may
 # be used in its place.
 module BusinessCalendar
 class << self
 # Register a calendar under its version identifier. Registered calendars
 # are used when rules are deserialized.
 def register(calendar)
 version = version_of(calendar)
 @calendars ||= {}
 @calendars[version] = calendar
 end

 # Look up a previously registered calendar by its version identifier.
 # Raises UnknownCalendarVersion when no calendar is registered for version.
    def find(version)
      @calendars ||= {}
      if version.nil? || !version.respond_to?(:to_s) || version.to_s.empty?
        raise ArgumentError, "a non-empty calendar version is required"
      end
      @calendars.fetch(version.to_s) do
 raise UnknownCalendarVersion,
 "No business calendar registered for version #{version.inspect}. " \
 "Register it with IceCube::BusinessCalendar.register(calendar) before " \
 "deserializing the rule."
 end
 end

 # Convenience helper for registering the built-in calendar in one call.
 def build(version:, holidays: [], working_weekends: [])
 calendar = SimpleCalendar.new(version, holidays, working_weekends)
 register(calendar)
 calendar
 end

 # Remove all registered calendars (mainly useful in tests).
 def reset!
 @calendars = {}
 end

 # Return the version identifier of a calendar, validating that it is
 # serializable.
 def version_of(calendar)
 unless calendar.respond_to?(:calendar_version)
 raise ArgumentError,
 "business calendar must respond to #calendar_version, got #{calendar.inspect}"
 end
 version = calendar.calendar_version
 if version.nil? || version.to_s.empty?
 raise ArgumentError, "business calendar version must be a non-empty string"
 end
 version.to_s
 end
 end

 # Built-in calendar implementation. Weekends are non-working days unless
 # listed in working_weekends (a make-up workday, e.g. a Sunday swapped in to
 # compensate for an extended holiday); holidays listed in holidays are
 # non-working days unless explicitly listed as a make-up workday.
 class SimpleCalendar
 attr_reader :calendar_version

 def initialize(version, holidays = [], working_weekends = [])
 @calendar_version = version.to_s
 raise ArgumentError, "business calendar version must be a non-empty string" if @calendar_version.empty?
 @holidays = normalize_dates(holidays)
 @working_weekends = normalize_dates(working_weekends)
 end

 def business_day?(date)
 date = to_date(date)
 return true if @working_weekends.include?(date)
 return false if @holidays.include?(date)
 !(date.saturday? || date.sunday?)
 end
 alias_method :working_day?, :business_day?

 private

 def normalize_dates(dates)
 Array(dates).map { |d| to_date(d) }.to_set
 end

 def to_date(value)
 value.respond_to?(:to_date) ? value.to_date : Date.new(value.year, value.month, value.day)
 end
 end
 end
end

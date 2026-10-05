module IceCube
  module Validations::BusinessDayOfMonth
    # Match the nth business day(s) of the month according to the caller
    # supplied calendar.
    #
    # Positive ordinals count business days from the start of the month
    # (1 = first business day), negative ordinals count from the end
    # (-1 = last business day, -2 = second to last, ...). Several ordinals
    # may be given in one call.
    #
    # Business days are determined by asking the calendar for every date in
    # the month (filtering) and are only numbered afterwards (counting), so
    # weekend make-up workdays are included and weekday holidays are
    # excluded. A month that does not contain enough business days for an
    # ordinal is skipped entirely; occurrences are never borrowed from the
    # following month.
    #
    # +calendar+ must respond to #business_day?(date) and expose a
    # serializable #version. Register it once via IceCube.register_calendar
    # so serialized rules can be deserialized in another process.
    def business_day_of_month(*ordinals, calendar:)
      ordinals.flatten.each do |ordinal|
        unless ordinal.is_a?(Integer) && !ordinal.zero?
          raise ArgumentError,
            "expecting a non-zero Integer ordinal, got #{ordinal.inspect}"
        end
      end
      validate_calendar(calendar)
      ordinals.flatten.each do |ordinal|
        validations_for(:business_day_of_month) << Validation.new(ordinal, calendar)
      end
      clobber_base_validations(:day, :wday)
      self
    end

    private

    def validate_calendar(calendar)
      unless calendar.respond_to?(:business_day?)
        raise ArgumentError, "calendar must respond to #business_day?"
      end
    end

    class Validation
      attr_reader :ordinal

      def initialize(ordinal, calendar)
        unless calendar.respond_to?(:business_day?)
          raise ArgumentError, "calendar must respond to #business_day?"
        end
        @ordinal = ordinal
        @calendar = calendar
      end

      def type
        :day
      end

      def dst_adjust?
        true
      end

      # Returns nil (offset 0) when +step_time+ is the requested business
      # day; otherwise the number of days to jump forward. Months with too
      # few business days are advanced past without borrowing a date from
      # the following month.
      def validate(step_time, _start_time)
        dates = business_dates_in_month(step_time.year, step_time.month)
        target = target_date(dates)
        step_date = Date.new(step_time.year, step_time.month, step_time.day)

        # The requested ordinal does not exist in this month (or already
        # passed): the whole month is skipped, nothing is borrowed from the
        # following one. The outer matching re-validates on the 1st.
        return days_until_next_month(step_date) if target.nil? || target < step_date

        offset = (target - step_date).to_i
        offset.zero? ? nil : offset
      end

      def build_s(builder)
        builder.piece(:business_day_of_month) << StringBuilder.nice_number(ordinal)
      end

      def build_hash(builder)
        arr = builder.validations_array(:business_day_of_month)
        arr << [ordinal, @calendar.version] unless arr.any? { |entry| entry[0] == ordinal }
      end

      def build_ical(_builder)
        raise ArgumentError,
          "business_day_of_month rules cannot be represented in iCalendar"
      end

      StringBuilder.register_formatter(:business_day_of_month) do |entries|
        sentence = StringBuilder.sentence(entries)
        str = IceCube::I18n.t(
          "ice_cube.business_days_of_month",
          count: entries.size,
          segments: sentence
        )
        IceCube::I18n.t("ice_cube.on", sentence: str)
      end

      private

      def business_dates_in_month(year, month)
        (1..TimeUtil.days_in_month(Date.new(year, month, 1))).map do |day|
          date = Date.new(year, month, day)
          date if @calendar.business_day?(date)
        end.compact
      end

      def target_date(dates)
        if ordinal > 0
          dates[ordinal - 1]
        elsif ordinal.abs <= dates.length
          dates[ordinal] # negative index counts from the end
        end
      end

      def days_until_next_month(date)
        first_of_next_month = Date.new(date.year, date.month, 1) >> 1
        (first_of_next_month - date).to_i
      end
    end
  end
end

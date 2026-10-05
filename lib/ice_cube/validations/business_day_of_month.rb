module IceCube
  module Validations::BusinessDayOfMonth
    # Match dates that are the nth working day of the month according to a
    # caller-supplied business calendar.
    #
    # Ordinals may be positive (1 = first business day of the month), negative
    # (-1 = last, -2 = second to last) or a mix of both. The calendar is
    # queried for every day of the month first (holidays removed, make-up
    # weekend days kept) and the remaining business days are then counted, so
    # the result is never computed by counting plain weekdays and filtering
    # holidays afterwards.
    #
    # Months that do not contain enough business days for a requested ordinal
    # are skipped entirely; occurrences never spill into the following month.
    def business_day_of_month(*args, calendar: nil)
      ordinals = args.flatten
      calendar = if calendar.respond_to?(:business_day?)
        calendar
      elsif (existing = validations_for(:business_day_of_month).first) && calendar.nil?
        existing.calendar
      else
        BusinessCalendar.find(calendar)
      end

      new_ordinals = ordinals.map do |ordinal|
        unless ordinal.is_a?(Integer) && !ordinal.zero?
          raise ArgumentError,
            "expecting non-zero Integer ordinal for business_day_of_month, got #{ordinal.inspect}"
        end
        ordinal
      end
      raise ArgumentError, "business_day_of_month requires at least one ordinal" if new_ordinals.empty?

      merged_ordinals = new_ordinals
      if existing
        if existing.calendar_version != BusinessCalendar.version_of(calendar)
          raise ArgumentError, "business_day_of_month was already defined with another calendar"
        end
        merged_ordinals = (existing.ordinals + new_ordinals).uniq
        calendar = existing.calendar
      end

      replace_validations_for(
        :business_day_of_month,
        [Validation.new(merged_ordinals.sort, calendar)]
      )
      clobber_base_validations(:day, :wday)
      self
    end

    class Validation
      attr_reader :ordinals, :calendar

      def initialize(ordinals, calendar)
        unless calendar.respond_to?(:business_day?)
          raise ArgumentError, "business calendar must respond to #business_day?"
        end
        @ordinals = ordinals
        @calendar = calendar
        @calendar_version = BusinessCalendar.version_of(calendar)
      end

      def calendar_version
        @calendar_version
      end

      def key
        :business_day_of_month
      end

      def type
        :day
      end

      def dst_adjust?
        true
      end

      # Day numbers (1-based) of every business day in the month containing
      # +time+, in chronological order. Calendar filtering happens before any
      # counting/positioning.
      def business_days(time)
        days_in_month = TimeUtil.days_in_month(time)
        (1..days_in_month).select do |mday|
          date = Date.new(time.year, time.month, mday)
          @calendar.business_day?(date)
        end
      end

      def target_days(time)
        days = business_days(time)
        count = days.length
        @ordinals.map do |ordinal|
          index = ordinal.positive? ? ordinal - 1 : count + ordinal
          next if index.negative? || index >= count
          days[index]
        end.compact
      end

      def validate(step_time, _start_time)
        days = target_days(step_time)
        remaining = TimeUtil.days_in_month(step_time) - step_time.day + 1
        return remaining if days.empty?
        return 0 if days.include?(step_time.day)
        future = days.select { |mday| mday > step_time.day }
        future.empty? ? remaining : future.min - step_time.day
      end

      def build_s(builder)
        entries = @ordinals.map { |ordinal| StringBuilder.nice_number(ordinal) }
        builder.piece(:business_day_of_month).concat(entries)
      end

      def build_hash(builder)
        validations = builder.validations
        validations[:business_day_of_month] ||= []
        validations[:business_day_of_month].concat(@ordinals)
        builder[:business_calendar_version] = @calendar_version
      end

      def build_ical(_builder)
        raise ArgumentError, "business_day_of_month rules cannot be serialized to iCalendar"
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
    end
  end
end

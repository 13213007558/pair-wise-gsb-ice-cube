module IceCube
  module Validations::YearlyInterval
    def interval(interval, week_start = nil)
      @interval = normalized_interval(interval)
      @week_start = if week_start
        TimeUtil.wday_to_sym(week_start)
      elsif instance_variable_defined?(:@week_start)
        @week_start
      else
        :monday
      end
      replace_validations_for(:interval, [Validation.new(@interval, @week_start, by_week_no?)])
      clobber_base_validations(:year)
      self
    end

    def by_week_no?
      !validations[:week_of_year].nil?
    end

    class Validation
      attr_reader :interval, :week_start

      def initialize(interval, week_start = :monday, week_numbered = false)
        @interval = interval
        @week_start = week_start
        @week_numbered = week_numbered
      end

      def type
        :year
      end

      def dst_adjust?
        true
      end

      def validate(step_time, start_time)
        years = step_time.year - start_time.year
        offset = (years % interval).nonzero?
        interval - offset if offset
      end

      def build_s(builder)
        builder.base = IceCube::I18n.t("ice_cube.each_year", count: interval)
      end

      def build_hash(builder)
        builder[:interval] = interval
        builder[:week_start] = TimeUtil.sym_to_wday(week_start) if @week_numbered
      end

      def build_ical(builder)
        builder["FREQ"] << "YEARLY"
        unless interval == 1
          builder["INTERVAL"] << interval
        end
        builder["WKST"] << week_start.to_s.upcase[0..1] if @week_numbered && week_start != :monday
      end
    end
  end
end

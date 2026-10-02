require "date"

module IceCube
  class ScheduleInference
    FREQUENCY_RANK = {
      IceCube::DailyRule => 1,
      IceCube::WeeklyRule => 2,
      IceCube::MonthlyRule => 3,
      IceCube::YearlyRule => 4
    }.freeze

    WEEKDAYS = (1..5).to_a.freeze
    WEEKEND_DAYS = [0, 6].freeze

    class Candidate
      attr_reader :rule, :complexity, :cost, :rdates, :exdates,
                  :unexplained_dates, :false_positive_dates, :search_key

      def initialize(rule:, complexity:, cost:, rdates:, exdates:,
                     unexplained_dates:, false_positive_dates:, search_key:,
                     schedule_builder:)
        @rule = rule
        @complexity = complexity
        @cost = cost
        @rdates = rdates
        @exdates = exdates
        @unexplained_dates = unexplained_dates
        @false_positive_dates = false_positive_dates
        @search_key = search_key
        @schedule_builder = schedule_builder
      end

      def schedule
        @schedule ||= @schedule_builder.call
      end

      def to_h
        {
          rule: rule&.to_hash,
          schedule: schedule.to_hash,
          complexity: complexity,
          cost: cost,
          rdates: rdates,
          exdates: exdates,
          unexplained_dates: unexplained_dates,
          false_positive_dates: false_positive_dates
        }
      end
    end

    Result = Struct.new(
      :best, :candidates, :window_start, :window_end,
      :observed_dates, :search_limit_reached
    ) do
      def to_h
        {
          window_start: window_start,
          window_end: window_end,
          observed_dates: observed_dates,
          best: best.to_h,
          candidates: candidates.map(&:to_h),
          search_limit_reached: search_limit_reached
        }
      end
    end

    def self.infer(observation_window, occurred_dates, options = {})
      new(observation_window, occurred_dates, options).call
    end

    def initialize(observation_window, occurred_dates, options)
      unless observation_window.is_a?(Range) && observation_window.first && observation_window.last
        raise ArgumentError, "observation_window must be a non-empty Range"
      end

      @window_start = TimeUtil.ensure_date(observation_window.first)
      @window_end = TimeUtil.ensure_date(observation_window.last)
      raise ArgumentError, "observation_window start must be before end" if @window_start > @window_end

      @times = Array(occurred_dates).map { |value| TimeUtil.ensure_time(value) }
      raise ArgumentError, "occurred_dates must contain at least one date" if @times.empty?

      @times.sort!
      reference_time = @times.first
      @times.map! { |time| TimeUtil.match_zone(time, reference_time) }
      @dates = @times.map { |time| TimeUtil.ensure_date(time) }

      unless @dates.uniq.length == @dates.length
        raise ArgumentError, "occurred_dates cannot contain more than one time on the same date"
      end
      unless @dates.all? { |date| date >= @window_start && date <= @window_end }
        raise ArgumentError, "all occurred_dates must be inside observation_window"
      end

      @rule_cost = options.fetch(:rule_cost, 1)
      @rdate_cost = options.fetch(:rdate_cost, 2)
      @exdate_cost = options.fetch(:exdate_cost, 2)
      @max_interval = positive_integer_option(options, :max_interval, 4)
      @max_candidates = positive_integer_option(options, :max_candidates, 256)
    end

    def call
      candidates = [baseline_candidate]
      enumerator = rule_candidates
      search_limit_reached = false

      while candidates.length < @max_candidates
        rule = begin
          enumerator.next
        rescue StopIteration
          nil
        end
        break if rule.nil?
        rule_key = candidate_rule_key(rule)
        next if seen_rules[rule_key]
        seen_rules[rule_key] = true
        candidates << evaluate(rule)
      end

      search_limit_reached = begin
        enumerator.peek
        true
      rescue StopIteration
        false
      end

      candidates.sort_by! do |candidate|
        [
          candidate.cost,
          candidate.rdates.length + candidate.exdates.length,
          candidate.complexity,
          frequency_rank(candidate.rule),
          validation_preference(candidate.rule),
          candidate.search_key
        ]
      end

      Result.new(
        candidates.first,
        candidates,
        @window_start,
        @window_end,
        @dates,
        search_limit_reached
      )
    end

    private

    def positive_integer_option(options, key, default)
      value = options.fetch(key, default)
      unless value.is_a?(Integer) && value > 0
        raise ArgumentError, "#{key} must be a positive Integer"
      end
      value
    end

    def seen_rules
      @seen_rules ||= {}
    end

    def candidate_rule_key(rule)
      rule.to_hash.inspect
    end

    def baseline_candidate
      build_candidate(
        rule: nil,
        rdates: @dates[1..],
        unexplained_dates: @dates,
        false_positive_dates: [],
        schedule_builder: -> {
          schedule = Schedule.new(@times.first)
          @times[1..].each { |time| schedule.add_recurrence_time(time) }
          schedule
        }
      )
    end

    def evaluate(rule)
      predicted_dates = predicted_dates_for(rule)
      schedule_start = @times.first

      unexplained_dates = @dates - predicted_dates
      false_positive_dates = predicted_dates - @dates
      unexplained_times = @times.select { |time| unexplained_dates.include?(time.to_date) }
      exception_times = false_positive_dates.map { |date| time_for_date(date) }

      build_candidate(
        rule: rule,
        rdates: unexplained_dates,
        exdates: false_positive_dates,
        unexplained_dates: unexplained_dates,
        false_positive_dates: false_positive_dates,
        schedule_builder: -> {
          schedule = Schedule.new(schedule_start)
          schedule.add_recurrence_rule(rule)
          unexplained_times.each { |time| schedule.add_recurrence_time(time) }
          exception_times.each { |time| schedule.add_exception_time(time) }
          schedule
        }
      )
    end

    def build_candidate(attributes)
      rule = attributes.fetch(:rule)
      rdates = attributes.fetch(:rdates)
      exdates = attributes.fetch(:exdates, [])
      unexplained_dates = attributes.fetch(:unexplained_dates)
      complexity = rule ? rule_complexity(rule) : 0
      cost = calculate_rule_cost(rule, complexity) +
             point_cost(@rdate_cost, rdates) +
             point_cost(@exdate_cost, exdates)

      Candidate.new(
        rule: rule,
        complexity: complexity,
        cost: cost,
        rdates: rdates,
        exdates: exdates,
        unexplained_dates: unexplained_dates,
        false_positive_dates: attributes.fetch(:false_positive_dates, exdates),
        search_key: rule ? rule.to_ical : "RDATE",
        schedule_builder: attributes.fetch(:schedule_builder)
      )
    end

    def calculate_rule_cost(rule, complexity)
      return 0 if rule.nil?
      if @rule_cost.respond_to?(:call)
        @rule_cost.call(rule, complexity)
      else
        complexity * @rule_cost
      end
    end

    def point_cost(cost, dates)
      return 0 if dates.empty?
      cost.respond_to?(:call) ? cost.call(dates) : dates.length * cost
    end

    def frequency_rank(rule)
      rule ? FREQUENCY_RANK.fetch(rule.class, 99) : 0
    end

    def rule_complexity(rule)
      hash = rule.to_hash
      validations = hash[:validations] || {}
      complexity = frequency_rank(rule) + (hash[:interval] || 1) - 1

      validations.each do |name, value|
        next if name == :by_set_pos && validations[:day] == WEEKDAYS
        complexity += validation_complexity(name, value)
      end

      complexity
    end

    def validation_complexity(name, value)
      case name
      when :day
        days = Array(value)
        return 1 if days == WEEKDAYS || days == WEEKEND_DAYS
        days.length
      when :day_of_month, :month_of_year, :day_of_year
        Array(value).length
      when :day_of_week
        value.values.map(&:length).reduce(0, :+)
      else
        1
      end
    end

    def validation_preference(rule)
      return 9 if rule.nil?
      validations = rule.to_hash[:validations] || {}
      return 0 if validations[:by_set_pos]
      return 1 if validations[:day_of_week]
      2
    end

    def rule_candidates
      Enumerator.new do |yielder|
        daily_candidates(yielder)
        weekly_candidates(yielder)
        monthly_candidates(yielder)
        yearly_candidates(yielder)
      end
    end

    def daily_candidates(yielder)
      (1..@max_interval).each { |interval| yielder << Rule.daily(interval) }
    end

    def weekly_candidates(yielder)
      (1..@max_interval).each do |interval|
        week_starts = interval == 1 ? [:sunday] : [:sunday, :monday]
        week_starts.each do |week_start|
          yielder << Rule.weekly(interval, week_start)
          yielder << Rule.weekly(interval, week_start).day(*observed_weekdays) unless observed_weekdays.empty?
        end
      end
    end

    def monthly_candidates(yielder)
      (1..@max_interval).each do |interval|
        yielder << Rule.monthly(interval)
        yielder << Rule.monthly(interval).day(*observed_weekdays) unless observed_weekdays.empty?
        yielder << Rule.monthly(interval).day_of_month(*positive_month_days)
        yielder << Rule.monthly(interval).day_of_month(*negative_month_days)
        yielder << Rule.monthly(interval).day_of_week(positive_weekday_occurrences)
        yielder << Rule.monthly(interval).day_of_week(negative_weekday_occurrences)
        yielder << Rule.monthly(interval).day_of_week(signed_weekday_occurrences)
        monthly_by_set_pos_candidates(yielder, interval)
      end
    end

    def monthly_by_set_pos_candidates(yielder, interval)
      monthly_byday_sets.each do |weekdays|
        positive_positions = @dates.map { |date| weekday_position(date, weekdays, true) }.uniq.sort
        negative_positions = @dates.map { |date| weekday_position(date, weekdays, false) }.uniq.sort

        yielder << Rule.monthly(interval).day(*weekdays).by_set_pos(positive_positions)
        yielder << Rule.monthly(interval).day(*weekdays).by_set_pos(negative_positions)
      end
    end

    def yearly_candidates(yielder)
      (1..@max_interval).each do |interval|
        yielder << Rule.yearly(interval)
        yielder << Rule.yearly(interval).month_of_year(*observed_months)
        yielder << Rule.yearly(interval).day_of_year(*positive_year_days)
        yielder << Rule.yearly(interval).day_of_year(*negative_year_days)
        yielder << Rule.yearly(interval).month_of_year(*observed_months).day_of_month(*positive_month_days)
        yielder << Rule.yearly(interval).month_of_year(*observed_months).day_of_month(*negative_month_days)
        yielder << Rule.yearly(interval).month_of_year(*observed_months).day_of_week(positive_weekday_occurrences)
        yielder << Rule.yearly(interval).month_of_year(*observed_months).day_of_week(negative_weekday_occurrences)
        yielder << Rule.yearly(interval).month_of_year(*observed_months).day_of_week(signed_weekday_occurrences)
      end
    end

    def observed_weekdays
      @observed_weekdays ||= @dates.map(&:wday).uniq.sort
    end

    def observed_months
      @observed_months ||= @dates.map(&:month).uniq.sort
    end

    def positive_month_days
      @positive_month_days ||= @dates.map(&:day).uniq.sort
    end

    def negative_month_days
      @negative_month_days ||= @dates.map do |date|
        date.day - days_in_month(date) - 1
      end.uniq.sort
    end

    def positive_year_days
      @positive_year_days ||= @dates.map(&:yday).uniq.sort
    end

    def negative_year_days
      @negative_year_days ||= @dates.map do |date|
        date.yday - Date.new(date.year, 12, 31).yday - 1
      end.uniq.sort
    end

    def positive_weekday_occurrences
      @positive_weekday_occurrences ||= weekday_occurrences(true)
    end

    def negative_weekday_occurrences
      @negative_weekday_occurrences ||= weekday_occurrences(false)
    end

    def weekday_occurrences(positive)
      @dates.each_with_object({}) do |date, occurrences|
        (occurrences[date.wday] ||= []) << weekday_occurrence(date, positive)
      end.transform_values(&:uniq).transform_values(&:sort)
    end

    def signed_weekday_occurrences
      @signed_weekday_occurrences ||= @dates.each_with_object({}) do |date, occurrences|
        positive_occurrence, occurrences_in_month = TimeUtil.which_occurrence_in_month(
          TimeUtil.beginning_of_date(date, @times.first), date.wday
        )
        occurrence = positive_occurrence <= occurrences_in_month - positive_occurrence + 1 ?
          positive_occurrence : positive_occurrence - occurrences_in_month - 1
        (occurrences[date.wday] ||= []) << occurrence
      end.transform_values(&:uniq).transform_values(&:sort)
    end

    def monthly_byday_sets
      sets = [observed_weekdays]
      sets << WEEKDAYS if @dates.all? { |date| (1..5).cover?(date.wday) }
      sets << WEEKEND_DAYS if @dates.all? { |date| [0, 6].include?(date.wday) }
      sets.uniq.reject(&:empty?)
    end

    def weekday_position(date, weekdays, positive)
      first_day = Date.new(date.year, date.month, 1)
      last_day = Date.new(date.year, date.month, -1)
      matching_days = (first_day..last_day).select { |candidate| weekdays.include?(candidate.wday) }
      index = matching_days.index(date)
      positive ? index + 1 : index - matching_days.length
    end

    def weekday_occurrence(date, positive)
      occurrence, _occurrences_in_month = TimeUtil.which_occurrence_in_month(
        TimeUtil.beginning_of_date(date, @times.first), date.wday
      )
      positive ? occurrence : occurrence - _occurrences_in_month - 1
    end

    def days_in_month(date)
      Date.new(date.year, date.month, -1).day
    end

    def time_for_date(date)
      reference = @times.first
      second = reference.sec + TimeUtil.subsec(reference)
      TimeUtil.build_in_zone(
        [date.year, date.month, date.day, reference.hour, reference.min, second],
        reference
      )
    end

    def predicted_dates_for(rule)
      hash = rule.to_hash
      interval = hash[:interval] || 1
      validations = hash[:validations] || {}

      case rule
      when IceCube::DailyRule
        select_dates { |date| (date - rule_anchor_date).to_i.modulo(interval).zero? }
      when IceCube::WeeklyRule
        week_start = hash[:week_start] || 0
        anchor_week_start = rule_anchor_date - ((rule_anchor_date.wday - week_start).modulo(7))
        weekdays = validations[:day]
        select_dates do |date|
          week_index = (week_start_date(date, week_start) - anchor_week_start).to_i / 7
          week_index.modulo(interval).zero? && (weekdays.nil? || weekdays.include?(date.wday))
        end
      when IceCube::MonthlyRule
        select_monthly_dates(interval, validations)
      when IceCube::YearlyRule
        select_yearly_dates(interval, validations)
      else
        []
      end
    end

    def week_start_date(date, week_start)
      date - ((date.wday - week_start).modulo(7))
    end

    def select_dates
      dates_in_window.select { |date| date >= rule_anchor_date && yield(date) }
    end

    def select_monthly_dates(interval, validations)
      aligned_months(rule_anchor_date, interval).select do |date|
        if validations[:day]
          next false unless validations[:day].include?(date.wday)
          if validations[:by_set_pos]
            matching_dates = month_dates(date).select { |candidate| validations[:day].include?(candidate.wday) }
            next matching_set_position?(matching_dates, date, validations[:by_set_pos].flatten)
          end
        elsif validations[:day_of_month]
          next false unless month_day_values(date, validations[:day_of_month]).include?(date.day)
        elsif validations[:day_of_week]
          next false unless ordinal_weekday_matches?(date, validations[:day_of_week])
        else
          next false unless date.day == rule_anchor_date.day
        end
        true
      end
    end

    def select_yearly_dates(interval, validations)
      dates_in_window.select do |date|
        next false unless (date.year - rule_anchor_date.year).modulo(interval).zero?
        if validations[:day_of_year]
          next year_day_values(date.year, validations[:day_of_year]).include?(date.yday)
        end
        if validations[:month_of_year]
          next false unless validations[:month_of_year].include?(date.month)
          if validations[:day_of_month]
            next month_day_values(date, validations[:day_of_month]).include?(date.day)
          elsif validations[:day_of_week]
            next ordinal_weekday_matches?(date, validations[:day_of_week])
          else
            next date.day == rule_anchor_date.day
          end
        end
        true
      end
    end

    def dates_in_window
      @dates_in_window ||= @window_start.upto(@window_end).to_a
    end

    def rule_anchor_date
      @rule_anchor_date ||= @dates.first
    end

    def aligned_months(month_anchor, interval)
      anchor_month = month_anchor.year * 12 + month_anchor.month - 1
      dates_in_window.select do |date|
        month = date.year * 12 + date.month - 1
        date >= month_anchor && (month - anchor_month).modulo(interval).zero?
      end
    end

    def month_dates(date)
      first_day = Date.new(date.year, date.month, 1)
      first_day.upto(Date.new(date.year, date.month, -1)).to_a
    end

    def matching_set_position?(dates, date, positions)
      index = dates.index(date)
      return false if index.nil?
      positions.include?(index + 1) || positions.include?(index - dates.length)
    end

    def month_day_values(date, values)
      values.map do |value|
        value.positive? ? value : days_in_month(date) + value + 1
      end
    end

    def ordinal_weekday_matches?(date, weekday_occurrences)
      weekday_occurrences.any? do |weekday, ordinal_values|
        next false unless date.wday == weekday
        occurrence_positions = weekday_positions_for(date)
        ordinal_values.any? do |ordinal|
          if ordinal.positive?
            occurrence_positions[:positive] == ordinal
          else
            occurrence_positions[:negative] == ordinal
          end
        end
      end
    end

    def weekday_positions_for(date)
      matching_dates = month_dates(date).select { |candidate| candidate.wday == date.wday }
      index = matching_dates.index(date)
      {
        positive: index + 1,
        negative: index - matching_dates.length
      }
    end

    def year_day_values(year, values)
      length = Date.new(year, 12, 31).yday
      values.map do |value|
        value.positive? ? value : length + value + 1
      end
    end
  end
end

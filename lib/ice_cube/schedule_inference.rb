require "json"

module IceCube
  class ScheduleInference
    DAY_NAMES = %i[sunday monday tuesday wednesday thursday friday saturday].freeze
    WEEKDAYS = (1..5).freeze

    DEFAULT_MAX_INTERVAL = 12
    DEFAULT_MAX_CANDIDATES = 128

    Candidate = Struct.new(
      :rule,
      :schedule,
      :predicted_dates,
      :rdates,
      :exdates,
      :unexplained_dates,
      :extra_dates,
      :complexity,
      :rdate_cost,
      :exdate_cost,
      :cost,
      keyword_init: true
    ) do
      def to_h
        {
          rule: rule,
          schedule: schedule,
          predicted_dates: predicted_dates,
          rdates: rdates,
          exdates: exdates,
          unexplained_dates: unexplained_dates,
          extra_dates: extra_dates,
          complexity: complexity,
          rdate_cost: rdate_cost,
          exdate_cost: exdate_cost,
          cost: cost
        }
      end
    end

    class Result
      include Enumerable

      attr_reader :window_start, :window_end, :observed_dates, :candidates

      def initialize(window_start, window_end, observed_dates, candidates)
        @window_start = window_start
        @window_end = window_end
        @observed_dates = observed_dates
        @candidates = candidates
      end

      def best
        candidates.first
      end

      def each(&block)
        candidates.each(&block)
      end

      def size
        candidates.size
      end

      def to_h
        {
          window_start: window_start,
          window_end: window_end,
          observed_dates: observed_dates,
          candidates: candidates.map(&:to_h)
        }
      end
    end

    def self.infer(
      window,
      dates,
      rule_cost:,
      rdate_cost:,
      exdate_cost:,
      max_interval: DEFAULT_MAX_INTERVAL,
      max_candidates: DEFAULT_MAX_CANDIDATES
    )
      new(
        window,
        dates,
        rule_cost: rule_cost,
        rdate_cost: rdate_cost,
        exdate_cost: exdate_cost,
        max_interval: positive_integer!(max_interval, :max_interval),
        max_candidates: positive_integer!(max_candidates, :max_candidates)
      ).infer
    end

    def self.positive_integer!(value, name)
      value = value.to_i
      return value if value.positive?

      raise ArgumentError, "#{name} must be a positive integer"
    end

    def initialize(window, dates, rule_cost:, rdate_cost:, exdate_cost:, max_interval:, max_candidates:)
      @window_start, @window_end = normalize_window(window)
      @observed_dates = normalize_dates(dates)
      @rule_cost = normalize_cost(rule_cost, :rule_cost)
      @rdate_cost = normalize_cost(rdate_cost, :rdate_cost)
      @exdate_cost = normalize_cost(exdate_cost, :exdate_cost)
      @max_interval = max_interval
      @max_candidates = max_candidates
      @signatures = {}
      @evaluated = 0
    end

    def infer
      rules = bounded_rules
      candidates = rules.map { |rule| evaluate(rule) }.compact
      candidates.sort_by! do |candidate|
        [
          candidate.cost,
          candidate.complexity,
          candidate.rdates.size,
          candidate.exdates.size,
          frequency_rank(candidate.rule),
          signature(candidate.rule, candidate.schedule.start_time.to_date)
        ]
      end
      Result.new(window_start, window_end, observed_dates, candidates)
    end

    private

    attr_reader :window_start, :window_end, :observed_dates, :rule_cost,
      :rdate_cost, :exdate_cost, :max_interval, :max_candidates,
      :signatures, :evaluated

    def normalize_window(window)
      unless window.is_a?(Range)
        raise ArgumentError, "window must be a Date range"
      end

      start_date = normalize_date(window.begin)
      end_date = normalize_date(window.end)
      end_date -= 1 if window.exclude_end?
      return [start_date, end_date] if start_date <= end_date

      raise ArgumentError, "window must not be empty"
    end

    def normalize_dates(dates)
      Array(dates).map { |date| normalize_date(date) }.sort.uniq.tap do |normalized|
        normalized.each do |date|
          next if date >= window_start && date <= window_end

          raise ArgumentError, "observed date #{date} is outside the observation window"
        end
      end
    end

    def normalize_date(value)
      return value.to_date if value.respond_to?(:to_date)

      raise ArgumentError, "expected Date or Time, got #{value.inspect}"
    end

    def normalize_cost(value, name)
      return value if value.nil? && name == :rule_cost
      return value if value.respond_to?(:call)
      return value.to_f if value.is_a?(Numeric) && value >= 0

      raise ArgumentError, "#{name} must be a non-negative Numeric or callable"
    end

    def bounded_rules
      rules = []
      catch(:search_limit_reached) do
        add_candidate(rules, nil, window_start)
        special_monthly_rules.each { |rule| add_rule(rules, rule) }
        weekly_rules.each { |rule, anchor| add_candidate(rules, rule, anchor) }
        monthly_rules.each { |rule, anchor| add_candidate(rules, rule, anchor) }
        daily_rules.each { |rule, anchor| add_candidate(rules, rule, anchor) }
        yearly_rules.each { |rule, anchor| add_candidate(rules, rule, anchor) }
      end
      rules
    end

    def add_rule(yielder, rule)
      add_candidate(yielder, rule, window_start)
    end

    def add_candidate(yielder, rule, anchor)
      throw(:search_limit_reached) if evaluated >= max_candidates

      anchor = normalized_anchor(rule, anchor)
      key = signature(rule, anchor)
      return if signatures.key?(key)

      signatures[key] = true
      @evaluated += 1
      yielder << [rule, anchor]
    end

    def normalized_anchor(rule, anchor)
      return window_start if rule.nil?

      interval = rule.validations_for(:interval).first.interval
      return window_start if interval == 1

      case rule
      when DailyRule
        shift_date_anchor(anchor, interval, interval * 7)
      when WeeklyRule
        shift_date_anchor(anchor, interval * 7, interval * 7)
      when MonthlyRule
        shift_monthly_anchor(anchor, interval)
      when YearlyRule
        shift_yearly_anchor(anchor, interval)
      else
        window_start
      end
    end

    def shift_date_anchor(anchor, interval_days, chunk_days)
      steps = ((anchor - window_start) / chunk_days).to_i
      anchor - (steps * interval_days)
    end

    def shift_monthly_anchor(anchor, interval_months)
      total_months = anchor.year * 12 + anchor.month - 1
      window_months = window_start.year * 12 + window_start.month - 1
      steps = [(total_months - window_months) / interval_months, 0].max

      steps.downto(0) do |step|
        candidate_months = total_months - (step * interval_months)
        year, month = candidate_months.divmod(12)
        candidate = safe_date(year, month + 1, anchor.day)
        return candidate if candidate && candidate <= window_start
      end
      anchor
    end

    def shift_yearly_anchor(anchor, interval_years)
      steps = [(anchor.year - window_start.year) / interval_years, 0].max
      steps.downto(0) do |step|
        candidate = safe_date(anchor.year - (step * interval_years), anchor.month, anchor.day)
        return candidate if candidate && candidate <= window_start
      end
      anchor
    end

    def safe_date(year, month, day)
      Date.new(year, month, day)
    rescue ArgumentError
      nil
    end

    def evaluate((rule, anchor))
      if rule.nil?
        predicted_dates = []
        schedule = empty_rule_schedule
      else
        schedule = build_schedule(rule, anchor)
        predicted_dates = expand_dates(schedule)
      end

      rdates = observed_dates - predicted_dates
      exdates = predicted_dates - observed_dates
      rdates.each { |date| schedule.add_recurrence_time(time_for(date)) }
      exdates.each { |date| schedule.add_exception_time(time_for(date)) }

      complexity = calculate_rule_complexity(rule)
      total_rdate_cost = sum_cost(rdate_cost, rdates)
      total_exdate_cost = sum_cost(exdate_cost, exdates)

      Candidate.new(
        rule: rule,
        schedule: schedule,
        predicted_dates: predicted_dates,
        rdates: rdates,
        exdates: exdates,
        unexplained_dates: rdates,
        extra_dates: exdates,
        complexity: complexity,
        rdate_cost: total_rdate_cost,
        exdate_cost: total_exdate_cost,
        cost: complexity + total_rdate_cost + total_exdate_cost
      )
    end

    def empty_rule_schedule
      schedule = IceCube::Schedule.new(time_for(observed_dates.first || window_start))
      schedule.add_exception_time(time_for(window_start)) if observed_dates.empty?
      schedule
    end

    def build_schedule(rule, anchor = window_start)
      IceCube::Schedule.new(time_for(anchor)).tap do |schedule|
        schedule.add_recurrence_rule(rule)
      end
    end

    def expand_dates(schedule)
      schedule
        .occurrences_between(time_for(window_start), time_for(window_end))
        .map(&:to_date)
        .sort
    end

    def time_for(date)
      Time.utc(date.year, date.month, date.day)
    end

    def calculate_rule_complexity(rule)
      return 0 if rule.nil?
      return rule_cost.call(rule).to_f if rule_cost.respond_to?(:call)
      return rule_cost.to_f if rule_cost.is_a?(Numeric)
      self.class.complexity(rule).to_f
    end

    def self.complexity(rule)
      hash = rule.to_hash
      validations = hash[:validations] || {}
      frequency = hash[:rule_type].split("::").last.sub("Rule", "").downcase.to_sym
      value = {daily: 1, weekly: 2, monthly: 3, yearly: 4}.fetch(frequency)
      value += (hash[:interval] || 1) - 1
      validations.each_key { |name| value += name == :interval ? 0 : 1 }
      value.to_f
    end

    def sum_cost(cost, dates)
      dates.sum { |date| cost.respond_to?(:call) ? cost.call(date).to_f : cost.to_f }
    end

    def frequency_rank(rule)
      return 4 if rule.nil?

      frequency = rule.to_hash[:rule_type].split("::").last.sub("Rule", "").downcase
      {daily: 0, weekly: 1, monthly: 2, yearly: 3}.fetch(frequency.to_sym, 4)
    end

    def signature(rule, anchor = window_start)
      return "null:#{window_start}" if rule.nil?

      JSON.generate(anchor: anchor, rule: canonical_value(rule.to_hash))
    end

    def canonical_value(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, result|
          result[key.to_s] = canonical_value(value[key])
        end
      when Array
        value.map { |item| canonical_value(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def special_monthly_rules
      [
        IceCube::Rule.monthly
          .day_of_month(-3, -2, -1)
          .day(*WEEKDAYS.to_a)
          .by_set_pos(-1),
        IceCube::Rule.monthly
          .day_of_month(1, 2, 3)
          .day(*WEEKDAYS.to_a)
          .by_set_pos(1)
      ]
    end

    def weekly_rules
      return enum_for(__method__) unless block_given?

      weekdays = observed_dates.map(&:wday).uniq.sort
      (1..max_interval).each do |interval|
        subsets(weekdays).each do |days|
          next unless days.all? { |day| (day - days.first) % interval == 0 }

          rule = IceCube::Rule.weekly(interval).day(*DAY_NAMES.values_at(*days))
          anchors = interval == 1 ? [window_start] : observed_dates.select { |date|
            days.include?(date.wday)
          }
          anchors.each { |anchor| yield [rule, anchor] }
        end
      end
    end

    def monthly_rules
      return enum_for(__method__) unless block_given?

      (2..max_interval).each do |interval|
        observed_dates.each do |anchor|
          yield [IceCube::Rule.monthly(interval), anchor]
        end
      end

      weekdays = observed_dates.map(&:wday).uniq.sort
      subsets(weekdays).each do |days|
        yield [IceCube::Rule.monthly.day(*DAY_NAMES.values_at(*days)), window_start]
      end

      monthly_day_of_week_patterns.each do |pattern|
        yield [IceCube::Rule.monthly.day_of_week(pattern), window_start]
      end

      month_days = observed_dates.map(&:day).uniq.sort
      subsets(month_days) do |days|
        yield [IceCube::Rule.monthly.day_of_month(days), window_start]
      end
    end

    def monthly_day_of_week_patterns
      positive = Hash.new { |occurrences, weekday| occurrences[weekday] = [] }
      negative = Hash.new { |occurrences, weekday| occurrences[weekday] = [] }
      observed_dates.each do |date|
        ordinal, occurrence_count = TimeUtil.which_occurrence_in_month(time_for(date), date.wday)
        positive[date.wday] |= [ordinal]
        negative[date.wday] |= [ordinal - occurrence_count - 1]
      end

      patterns = []
      positive.to_a.each do |wday, ordinals|
        ordinals.each do |ordinal|
          patterns << {DAY_NAMES.fetch(wday) => [ordinal]}
        end
      end
      negative.to_a.each do |wday, ordinals|
        ordinals.each do |ordinal|
          patterns << {DAY_NAMES.fetch(wday) => [ordinal]}
        end
      end
      patterns << grouped_day_of_week_pattern(positive)
      patterns << grouped_day_of_week_pattern(negative)
      patterns
    end

    def grouped_day_of_week_pattern(group)
      group.each_with_object({}) do |(wday, ordinals), pattern|
        pattern[DAY_NAMES.fetch(wday)] = ordinals.sort
      end
    end

    def daily_rules
      return enum_for(__method__) unless block_given?

      (1..max_interval).each do |interval|
        weekdays = observed_dates.map(&:wday).uniq.sort
        subsets(weekdays) do |days|
          next if interval > 1 && interval % 7 != 0

          anchors = interval == 1 ? [window_start] : observed_dates
          anchors.each do |anchor|
            yield [IceCube::Rule.daily(interval).day(*DAY_NAMES.values_at(*days)), anchor]
          end
        end

        anchors = interval == 1 ? [window_start] : observed_dates
        anchors.each { |anchor| yield [IceCube::Rule.daily(interval), anchor] }
      end
    end

    def yearly_rules
      return enum_for(__method__) unless block_given?

      (2..max_interval).each do |interval|
        observed_dates.each { |anchor| yield [IceCube::Rule.yearly(interval), anchor] }
      end

      month_days = observed_dates.map { |date| [date.month, date.day] }.uniq.sort
      subsets(month_days) do |pairs|
        months = pairs.map(&:first).uniq
        days = pairs.map(&:last)
        yield [
          IceCube::Rule.yearly.month_of_year(months).day_of_month(days),
          window_start
        ]
      end

      yearly_day_of_week_patterns.each do |month, pattern|
        yield [
          IceCube::Rule.yearly.month_of_year(month).day_of_week(pattern),
          window_start
        ]
      end
    end

    def yearly_day_of_week_patterns
      patterns = []
      observed_dates.group_by(&:month).each do |month, dates|
        positive = Hash.new { |occurrences, weekday| occurrences[weekday] = [] }
        negative = Hash.new { |occurrences, weekday| occurrences[weekday] = [] }
        dates.each do |date|
          ordinal, occurrence_count = TimeUtil.which_occurrence_in_month(time_for(date), date.wday)
          positive[date.wday] |= [ordinal]
          negative[date.wday] |= [ordinal - occurrence_count - 1]
        end
        patterns << [month, grouped_day_of_week_pattern(positive)]
        patterns << [month, grouped_day_of_week_pattern(negative)]
      end
      patterns
    end

    def subsets(values)
      return enum_for(__method__, values.uniq.sort) unless block_given?

      values = values.uniq.sort
      (1..values.size).each do |size|
        values.combination(size) { |combination| yield combination }
      end
    end
  end
end

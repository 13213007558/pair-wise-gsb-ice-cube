module IceCube
  class FastOccurrencePlanner
    Expression = Struct.new(
      :kind, :time_of_day, :anchor_date, :interval, :days,
      :months, :exact_date, :end_date, :clamp, :daily_all, keyword_init: true
    ) do
      def frozen?
        kind == :empty
      end

      def key
        if kind == :single
          [:single, exact_date, time_of_day]
        else
          [kind, anchor_date, interval, days, months, time_of_day]
        end
      end
    end

    attr_reader :schedule

    def initialize(schedule)
      @schedule = schedule
      @start = utc_time(schedule.start_time)
      @sources = []
      @exceptions = Hash.new { |hash, key| hash[key] = [] }
      build
    end

    def occurrence_at(index)
      unless index.is_a?(Integer) && index >= 0
        raise ArgumentError, "occurrence_at expects a non-negative Integer index, got #{index.inspect}"
      end

      return nil if finite? && index >= count_through(maximum_date)

      low = @start.to_date
      high = low
      if finite?
        return nil if count_through(maximum_date) <= index
        high = maximum_date
      else
        span = 1
        while count_through(high) <= index
          high += span
          span *= 2
        end
      end

      date = bsearch_date(low, high) { |candidate| count_through(candidate) > index }
      time = times_on(date).sort[index - count_through(date - 1)]
      return nil if time.nil?
      Occurrence.new(time, time + @schedule.duration)
    end

    def count_between(begin_time, closing_time)
      opening = utc_time(begin_time)
      closing = utc_time(closing_time)
      return 0 if closing < opening

      count = count_through(closing.to_date)
      count -= count_before(opening)
      count
    end

    private

    def build
      recurrence_sources.each do |rule|
        add_source(rule)
      end

      schedule.exception_rules.each do |rule|
        unsupported "exception rules"
      end

      schedule.exception_times.each do |time|
        time = utc_time(time)
        next if time < @start
        @exceptions[time_of_day(time)] << time
      end
      @exceptions.each_value(&:sort!)
    end

    def recurrence_sources
      rules = schedule.rrules
      if rules.empty?
        schedule.instance_variable_get(:@all_recurrence_rules)
      else
        schedule.instance_variable_get(:@all_recurrence_rules)
      end
    end

    def add_source(rule)
      if rule.is_a?(SingleOccurrenceRule) || rule.is_a?(Time)
        time = utc_time(rule.is_a?(Time) ? rule : rule.time)
        return if time < @start
        @sources << single_expression(time)
        return
      end

      expression = periodic_expression(rule)
      count = rule.occurrence_count
      until_time = rule.until_time && utc_time(rule.until_time)

      if count
        raise ArgumentError, "count must be positive, got #{count}" if count <= 0
        expression.end_date = raw_nth_date(expression, count - 1)
      elsif until_time
        expression.end_date = until_date(until_time, expression)
      end

      @sources << expression
    end

    def periodic_expression(rule)
      validations = rule.validations
      allowed = case rule
      when DailyRule then %i[interval base_hour base_min base_sec day count until]
      when WeeklyRule then %i[interval base_wday base_hour base_min base_sec day count until]
      when MonthlyRule then %i[interval base_day base_hour base_min base_sec day_of_month count until]
      when YearlyRule then %i[interval base_month base_day base_hour base_min base_sec day_of_month month_of_year count until]
      else unsupported_rule(rule)
      end

      unexpected = validations.keys - allowed
      unsupported_rule(rule, unexpected.join(", ")) unless unexpected.empty?

      if validations[:base_hour] || validations[:base_min] || validations[:base_sec]
        unless rule.realign(@start, @start) == @start
          unsupported_rule(rule, "a time component that differs from the schedule start time")
        end
      end

      interval = rule.base_interval_validation.interval
      days = Array(validations[:day]).map(&:day).uniq.sort
      day_values = Array(validations[:day_of_month]).map(&:day).uniq.sort
      if day_values.any? { |day| day == 0 || day.abs > 31 }
        unsupported_rule(rule, "day_of_month values outside -31..31")
      end

      case rule
      when DailyRule
        explicit_weekdays = days
        effective_interval = interval
        if explicit_weekdays.any? && interval != 1 && !((interval % 7).zero? && days == [@start.wday])
          unsupported_rule(rule, "daily interval with multiple weekday restrictions")
        end
        expression = periodic(rule, :daily, effective_interval, days, nil)
        expression.daily_all = explicit_weekdays.empty?
        expression.days = [0, 1, 2, 3, 4, 5, 6] if explicit_weekdays.empty?
        expression
      when WeeklyRule
        days = [@start.wday] if days.empty?
        periodic(rule, :weekly, interval, days, nil)
      when MonthlyRule
        clamp = day_values.empty?
        days = day_values.empty? ? [@start.day] : day_values
        periodic(rule, :monthly, interval, days, nil, clamp)
      else
        months = Array(validations[:month_of_year]).map(&:month).uniq.sort
        months = [@start.month] if months.empty?
        clamp = day_values.empty?
        days = day_values.empty? ? [@start.day] : day_values
        periodic(rule, :yearly, interval, days, months, clamp)
      end
    end

    def periodic(rule, kind, interval, days, months, clamp = false)
      Expression.new(
        kind: kind,
        time_of_day: time_of_day(@start),
        anchor_date: @start.to_date,
        interval: interval,
        days: days,
        months: months,
        clamp: clamp,
        daily_all: false
      )
    end

    def single_expression(time)
      Expression.new(
        kind: :single,
        time_of_day: time_of_day(time),
        anchor_date: time.to_date,
        exact_date: time.to_date,
        end_date: time.to_date
      )
    end

    def finite?
      @sources.all? { |expression| expression.end_date }
    end

    def maximum_date
      @sources.map(&:end_date).compact.max
    end

    def count_through(date)
      sources_by_time = @sources.group_by(&:time_of_day)
      sources_by_time.sum do |time_of_day, expressions|
        count_union_through(expressions, date) - count_covered_exceptions(expressions, date, time_of_day)
      end
    end

    def count_on_date_before(date, time)
      @sources.group_by(&:time_of_day).sum do |time_of_day, expressions|
        occurrence_time = time_on_date(date, time_of_day)
        next 0 if occurrence_time >= time
        next 0 unless expressions.any? { |expression| matches?(expression, date) }
        next 0 if @exceptions.fetch(time_of_day, []).include?(occurrence_time)
        1
      end
    end

    def count_union_through(expressions, date)
      active = expressions.select { |expression| expression.anchor_date <= date }
      count_raw_union(active, date)
    end

    def count_raw_union(expressions, date)
      (1..expressions.size).sum do |size|
        expressions.combination(size).sum do |combination|
          sign = size.odd? ? 1 : -1
          sign * count_expression_through(combine(combination), date)
        end
      end
    end

    def count_covered_exceptions(expressions, date, time_of_day)
      exception_times = @exceptions.fetch(time_of_day, []).select { |time| time.to_date <= date }
      exception_times.count { |time| expressions.any? { |expression| matches?(expression, time.to_date) } }
    end

    def times_on(date)
      times = []
      @sources.group_by(&:time_of_day).each do |time_of_day, expressions|
        union_matches = expressions.any? { |expression| matches?(expression, date) }
        next unless union_matches
        time = time_on_date(date, time_of_day)
        next if time < @start
        next if @exceptions.fetch(time_of_day, []).include?(time)
        times << time
      end
      times
    end

    def matches?(expression, date)
      date >= expression.anchor_date &&
        (!expression.end_date || date <= expression.end_date) &&
        matches_without_end?(expression, date)
    end

    def matches_without_end?(expression, date)
      case expression.kind
      when :single then expression.exact_date == date
      when :daily then daily_match?(expression, date)
      when :weekly then weekly_match?(expression, date)
      when :monthly then monthly_match?(expression, date)
      when :yearly then yearly_match?(expression, date)
      when :my then expression.members.all? { |member| my_member_match?(member, date) }
      else false
      end
    end

    def count_expression_through(expression, date)
      return 0 if date < @start.to_date || date < expression.anchor_date
      ending = [date, expression.end_date || date].min
      case expression.kind
      when :empty then 0
      when :single then expression.exact_date <= ending ? 1 : 0
      when :daily then count_daily(expression, ending)
      when :weekly then count_weekly(expression, ending)
      when :monthly then count_monthly(expression, ending)
      when :yearly then count_yearly(expression, ending)
      else unsupported "unknown fast occurrence expression"
      end
    end

    def combine(expressions)
      expressions = expressions.reject(&:frozen?)
      return empty_expression if expressions.empty?
      return with_combined_end(expressions.first, expressions) if expressions.size == 1
      unless expressions.map(&:time_of_day).uniq.size == 1
        return empty_expression
      end
      if expressions.any? { |expression| expression.kind == :single }
        single = expressions.find { |expression| expression.kind == :single }
        if expressions.all? { |expression| matches?(expression, single.exact_date) }
          return with_combined_end(single, expressions)
        end
        return empty_expression
      end
      if expressions.map(&:kind).all? { |kind| %i[monthly yearly].include?(kind) }
        combine_my(expressions)
      elsif expressions.map(&:kind).all? { |kind| %i[daily weekly].include?(kind) }
        combine_periodic(expressions)
      else
        unsupported "overlapping daily/weekly and monthly/yearly rules"
      end
    end

    def empty_expression
      Expression.new(kind: :empty, anchor_date: @start.to_date, time_of_day: 0)
    end

    def with_combined_end(expression, expressions)
      combined = expression.dup
      combined.end_date = expressions.map(&:end_date).compact.min
      combined
    end

    def daily_match?(expression, date)
      return date >= expression.anchor_date && ((date - expression.anchor_date).to_i % expression.interval).zero? if expression.daily_all
      tracks_for(expression, date).any? { |track| (date - track[:first]).to_i >= 0 &&
        ((date - track[:first]).to_i % track[:period]).zero? }
    end

    def weekly_match?(expression, date)
      difference = date - expression.anchor_date
      week = ((difference + expression.anchor_date.wday) / 7).to_i
      if week.zero?
        return date >= expression.anchor_date && expression.days.include?(date.wday)
      end
      (week % expression.interval).zero? && expression.days.include?(date.wday)
    end

    def monthly_match?(expression, date)
      offset = (date.year - expression.anchor_date.year) * 12 + date.month - expression.anchor_date.month
      return false if offset.negative? || !(offset % expression.interval).zero?
      month_days(expression.days, date, expression.clamp).include?(date.day)
    end

    def yearly_match?(expression, date)
      return false if (date.year - expression.anchor_date.year) % expression.interval != 0
      expression.months.include?(date.month) &&
        month_days(expression.days, date, expression.clamp).include?(date.day)
    end

    def count_daily(expression, date)
      return 0 if date < expression.anchor_date
      return ((date - expression.anchor_date).to_i / expression.interval) + 1 if expression.daily_all
      tracks_for(expression, date).sum do |track|
        next 0 if date < track[:first]
        ((date - track[:first]).to_i / track[:period]) + 1
      end
    end

    def count_weekly(expression, date)
      return 0 if date < expression.anchor_date
      difference = date - expression.anchor_date
      week = ((difference + expression.anchor_date.wday) / 7).to_i
      if week.zero?
        return expression.days.count { |wday| wday >= expression.anchor_date.wday && wday <= date.wday }
      end

      includes_anchor = expression.days.include?(expression.anchor_date.wday)
      if (week % expression.interval).zero?
        completed = if includes_anchor
          ((week - 1) / expression.interval) * expression.days.size
        else
          ((week / expression.interval) - 1) * expression.days.size
        end
        completed + expression.days.count { |wday| wday <= date.wday } + (includes_anchor ? 1 : 0)
      else
        if includes_anchor
          1 + ((week - 1) / expression.interval) * expression.days.size
        else
          (week / expression.interval) * expression.days.size
        end
      end
    end
    def count_monthly(expression, date)
      count_periodic_months(
        expression.anchor_date, date, expression.interval,
        expression.days, expression.clamp
      )
    end

    def count_yearly(expression, date)
      expression.months.sum do |month|
        year = expression.anchor_date.year
        first = first_month(year, month)
        effective_first = first >= expression.anchor_date ? first : expression.anchor_date
        next 0 if effective_first > date
        count_periodic_months(
          effective_first, date, 12,
          expression.days, expression.clamp, :yearly, expression.interval, expression.months
        )
      end
    end

    def count_periodic_months(anchor, date, month_interval, days, clamp = false, frequency = :monthly, yearly_step = 1, valid_months = nil)
      return 0 if date < anchor
      first_days = month_days(days, anchor, clamp)
      first_days = first_days.select { |day| day >= anchor.day }
      return 0 if first_days.empty? && date.year == anchor.year && date.month == anchor.month

      first_month = Date.new(anchor.year, anchor.month, 1)
      last_month = Date.new(date.year, date.month, 1)
      if first_month == last_month
        return first_days.count { |day| day <= date.day }
      end

      count = first_days.size
      step_months = frequency == :yearly ? yearly_step * 12 : month_interval
      following = anchor >> step_months
      if following <= last_month
        months_before_last = ((last_month.year - following.year) * 12 + last_month.month - following.month) / step_months + 1
        sample_month = Date.new(following.year, following.month, 1)
        full_count = months_before_last - 1
        count += complete_months_weight(
          days, sample_month, step_months, full_count, clamp,
          frequency, yearly_step, valid_months
        )
        final_month = sample_month >> (full_count * step_months)
        count += if final_month.year == date.year && final_month.month == date.month
          month_days(days, date, clamp).count { |day| day <= date.day }
        else
          month_weight(days, final_month, clamp)
        end
      end
      count
    end

    def complete_months_weight(days, first_month, interval, count, clamp, frequency, yearly_step, valid_months = nil)
      return 0 if count <= 0
      if frequency == :yearly
        full_yearly_months_weight(days, first_month, yearly_step, count, clamp, valid_months)
      else
        period_months = 4800
        (0...period_months).sum do |offset|
          next 0 unless (offset % interval).zero? && offset < count * interval
          repeats = (count * interval - 1 - offset) / period_months + 1
          repeats * month_weight(days, first_month >> offset, clamp)
        end
      end
    end

    def full_yearly_months_weight(days, first_month, step_years, count, clamp, valid_months)
      return 0 if count <= 0
      month = first_month.month
      return count * month_days(days, first_month, clamp).size unless month == 2
      leap_count = leap_occurrences_in_hits(first_month.year, step_years, count)
      ordinary_size = month_days(days, Date.new(2019, 2, 1), clamp).size
      leap_size = month_days(days, Date.new(2020, 2, 1), clamp).size
      leap_count * leap_size + (count - leap_count) * ordinary_size
    end

    def leap_occurrences_in_hits(first_year, step_years, occurrences)
      return 0 if occurrences <= 0
      count_divisible_years(first_year, step_years, occurrences, 4) -
        count_divisible_years(first_year, step_years, occurrences, 100) +
        count_divisible_years(first_year, step_years, occurrences, 400)
    end

    def count_divisible_years(first_year, step_years, occurrences, modulus)
      divisor = step_years.gcd(modulus)
      target = (-first_year) % modulus
      return 0 unless (target % divisor).zero?

      reduced_step = step_years / divisor
      reduced_modulus = modulus / divisor
      target /= divisor
      first_hit = (target * modular_inverse(reduced_step, reduced_modulus)) % reduced_modulus
      return 0 unless first_hit < occurrences
      (occurrences - 1 - first_hit) / reduced_modulus + 1
    end

    def modular_inverse(value, modulus)
      return 0 if modulus == 1
      [extended_gcd(value, modulus).first % modulus].max
    end

    def extended_gcd(left, right)
      return [1, 0] if right.zero?
      quotient, remainder = left.divmod(right)
      coefficient, next_coefficient = extended_gcd(right, remainder)
      [next_coefficient, coefficient - quotient * next_coefficient]
    end

    def month_weight(days, month, clamp = false)
      month_days(days, month, clamp).size
    end

    def month_days(days, date, clamp = false)
      length = TimeUtil.days_in_month(date)
      days.each_with_object([]) do |day, result|
        resolved = if clamp
          [day, length].min
        elsif day.negative?
          length + day + 1
        else
          day
        end
        next if resolved > length
        result << resolved
      end.uniq.sort
    end

    def tracks_for(expression, date)
      expression.days.map do |weekday|
        first = expression.anchor_date + ((weekday - expression.anchor_date.wday) % 7)
        period = expression.kind == :daily ? [expression.interval, 7].max :
          expression.interval * 7
        {first: first, period: period}
      end
    end

    def combine_periodic(expressions)
      expressions = expressions.sort_by { |expression| [expression.kind == :weekly ? 0 : 1, expression.anchor_date] }
      combined = expressions.first.dup
      combined.members = nil
      combined.anchor_date = expressions.map(&:anchor_date).max
      combined.days = expressions.flat_map { |expression| periodic_days(expression) }.uniq.sort

      expressions.each do |expression|
        period = periodic_period(expression)
        next if period == combined.interval
        combined.interval = lcm(combined.interval, period)
      end

      combined.days = combined.days.select do |weekday|
        expressions.all? { |expression| periodic_period(expression) == 1 || (weekday - expression.anchor_date.wday).abs % periodic_period(expression) == 0 }
      end
      combined.days = combined.days & all_weekdays_within_period(combined, expressions)
      combined.kind = :daily
      combined.interval = 1 if combined.days.size == 7
      combined.end_date = expressions.map(&:end_date).compact.min
      combined
    end

    def periodic_days(expression)
      expression.days
    end

    def periodic_period(expression)
      expression.kind == :daily ? [expression.interval, 7].max : expression.interval * 7
    end

    def all_weekdays_within_period(combined, expressions)
      first = combined.anchor_date
      (0...combined.interval).map { |offset| (first + offset).wday }.uniq.sort
    end

    def combine_my(expressions)
      return expressions.first.dup if expressions.map(&:key).uniq.size == 1

      all_monthly = expressions.all? { |expression| expression.kind == :monthly }
      if all_monthly
        reference = expressions.first
        return empty_expression if expressions.any? do |expression|
          expression.interval == reference.interval &&
            (month_days(expression.days, reference.anchor_date, expression.clamp) &
              month_days(reference.days, reference.anchor_date, reference.clamp)).empty?
        end
      end

      if expressions.map(&:kind).uniq.sort == %i[monthly yearly]
        yearly = expressions.find { |expression| expression.kind == :yearly }
        monthly = expressions.find { |expression| expression.kind == :monthly }
        return empty_expression if monthly.days.include?(31) && yearly.months == [2]
      end

      unsupported "overlapping monthly/yearly rule combinations with different dates"
    end

    def first_month(year, month)
      Date.new(year, month, 1)
    end

    def lcm(left, right)
      left * right / left.gcd(right)
    end

    def bsearch_date(low, high)
      while low < high
        middle = low + ((high - low).to_i / 2)
        if yield(middle)
          high = middle
        else
          low = middle + 1
        end
      end
      low
    end

    def raw_nth_date(expression, index)
      low = expression.anchor_date
      high = low
      span = 1
      while count_raw_expression_through(expression, high) <= index
        high += span
        span *= 2
      end
      bsearch_date(low, high) { |date| count_raw_expression_through(expression, date) > index }
    end

    def count_raw_expression_through(expression, date)
      saved = expression.end_date
      expression.end_date = nil
      count_expression_through(expression, date)
    ensure
      expression.end_date = saved
    end

    def until_date(time, expression)
      date = time.to_date
      date if time >= time_on_date(date, expression.time_of_day)
    end

    def time_on_date(date, time_of_day)
      hour = (time_of_day / 3600).to_i
      minute = ((time_of_day % 3600) / 60).to_i
      second = (time_of_day % 60).to_i
      subsecond = time_of_day - time_of_day.to_i
      Time.utc(date.year, date.month, date.day, hour, minute, second + subsecond)
    end

    def time_of_day(time)
      time.hour * 3600 + time.min * 60 + time.sec + TimeUtil.subsec(time)
    end

    def utc_time(time)
      if time.is_a?(Date) && !time.is_a?(Time)
        Time.utc(time.year, time.month, time.day)
      else
        converted = TimeUtil.ensure_time(time)
        unsupported "non-UTC times" unless converted.utc?
        converted
      end
    end

    def unsupported_rule(rule, reason = nil)
      details = reason ? ": #{reason}" : ""
      unsupported "#{rule.class}#{details}"
    end

    def unsupported(reason)
      raise UnsupportedFastOccurrence,
        "occurrence_at/count_between fast path only supports fixed-UTC schedules using " \
        "day, week, month and year rules and finite explicit exception times; unsupported: #{reason}"
    end

  end
end
    def count_before(time)
      date = time.to_date
      day_time = time_on_date(date, time_of_day(time))
      count = count_through(date - 1)
      if day_time < time && times_on(date).include?(day_time)
        count + 1
      else
        count
      end
    end

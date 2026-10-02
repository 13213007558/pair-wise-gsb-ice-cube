require "ice_cube"

def report(title, result)
  puts "\n#{title}"
  puts "=" * title.length
  puts "best: #{result.best.rule&.to_ical || "RDATE-only"} cost=#{result.best.cost}"
  puts "  unexplained: #{result.best.unexplained_dates.map(&:iso8601).join(', ')}"
  puts "  exceptions:  #{result.best.exdates.map(&:iso8601).join(', ')}"

  restored = IceCube::Schedule.from_hash(result.best.schedule.to_hash)
  window_start = Time.local(result.window_start.year, result.window_start.month, result.window_start.day)
  window_end = Time.local(
    result.window_end.year, result.window_end.month, result.window_end.day, 23, 59, 59
  )
  dates = restored.occurrences_between(window_start, window_end).map { |time| time.to_date.iso8601 }
  puts "  expanded:    #{dates.join(', ')}"
  puts "  candidates:  #{result.candidates.length}"
end

last_weekday_window = Date.new(2024, 1, 1)..Date.new(2024, 4, 30)
last_weekday_schedule = IceCube::Schedule.new(Time.local(2024, 1, 1))
last_weekday_schedule.add_recurrence_rule(
  IceCube::Rule.monthly
    .day(:monday, :tuesday, :wednesday, :thursday, :friday)
    .by_set_pos(-1)
)
last_weekday_dates = last_weekday_schedule
  .occurrences_between(Time.local(2024, 1, 1), Time.local(2024, 4, 30, 23, 59, 59))
  .map(&:to_date)
report(
  "Last weekday of every month",
  IceCube::Schedule.infer(last_weekday_window, last_weekday_dates, max_interval: 3, max_candidates: 128)
)

biweekly_window = Date.new(2024, 1, 1)..Date.new(2024, 3, 31)
biweekly_schedule = IceCube::Schedule.new(Time.local(2024, 1, 1))
biweekly_schedule.add_recurrence_rule(IceCube::Rule.weekly(2, :monday).day(:monday))
biweekly_dates = biweekly_schedule
  .occurrences_between(Time.local(2024, 1, 1), Time.local(2024, 3, 31, 23, 59, 59))
  .map(&:to_date)
biweekly_dates << Date.new(2024, 1, 8)
biweekly_dates.delete(Date.new(2024, 2, 12))
report(
  "Biweekly Monday with one addition and one cancellation",
  IceCube::Schedule.infer(
    biweekly_window,
    biweekly_dates,
    rule_cost: 1,
    rdate_cost: 2,
    exdate_cost: 2,
    max_interval: 4,
    max_candidates: 128
  )
)

ambiguous_window = Date.new(2025, 1, 1)..Date.new(2025, 2, 28)
ambiguous_dates = [Date.new(2025, 1, 31), Date.new(2025, 2, 28)]
ambiguous_result = IceCube::Schedule.infer(
  ambiguous_window,
  ambiguous_dates,
  rule_cost: 0,
  rdate_cost: 1,
  exdate_cost: 1,
  max_interval: 3,
  max_candidates: 128
)
report("Short, ambiguous sample", ambiguous_result)
puts "  equally fitting explanations:"
ambiguous_result.candidates
  .select { |candidate| candidate.rule && candidate.rdates.empty? && candidate.exdates.empty? }
  .each { |candidate| puts "    - #{candidate.rule.to_ical}" }

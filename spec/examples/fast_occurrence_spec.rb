require "spec_helper"

describe IceCube::Schedule, :fast_occurrence do
  let(:start_time) { Time.utc(2020, 1, 31, 12) }

  def clone_schedule(schedule)
    IceCube::Schedule.from_hash(schedule.to_hash)
  end

  describe :count_between do
    it "counts daily, weekly, monthly and yearly rules like the enumerator" do
      ending = Time.utc(2024, 3, 1, 12)
      rules = [
        IceCube::Rule.daily(3),
        IceCube::Rule.weekly(2).day(:monday, :friday),
        IceCube::Rule.monthly,
        IceCube::Rule.monthly.day_of_month(1, 15, 31, -1),
        IceCube::Rule.yearly.month_of_year(2, 3).day_of_month(29, 31, -1)
      ]

      rules.each do |rule|
        fast_schedule = IceCube::Schedule.new(start_time) { |s| s.add_recurrence_rule(IceCube::Rule.from_hash(rule.to_hash)) }
        slow_schedule = IceCube::Schedule.new(start_time) { |s| s.add_recurrence_rule(IceCube::Rule.from_hash(rule.to_hash)) }

        expect(fast_schedule.count_between(start_time, ending)).to eq(
          slow_schedule.occurrences_between(start_time, ending).size
        )
      end
    end

    it "deduplicates overlapping rules before subtracting explicit exception times" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule(IceCube::Rule.daily)
        s.add_recurrence_rule(IceCube::Rule.daily)
        s.add_exception_time(start_time + IceCube::ONE_DAY)
      end

      expect(schedule.count_between(start_time, start_time + 3 * IceCube::ONE_DAY)).to eq(3)
    end

    it "keeps COUNT and UNTIL local to each original rule" do
      counted = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule(IceCube::Rule.monthly.day_of_month(1).count(12))
        s.add_recurrence_rule(IceCube::Rule.monthly.day_of_month(15).count(12))
      end
      until_limited = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule(IceCube::Rule.daily.until(start_time + 2 * IceCube::ONE_DAY))
      end

      expect(counted.count_between(start_time, Time.utc(2022, 1, 1))).to eq(24)
      expect(until_limited.count_between(start_time, start_time + 10 * IceCube::ONE_DAY)).to eq(3)
    end
  end

  describe :occurrence_at do
    it "returns the zero-based occurrence after deduplication and exclusions" do
      schedule = IceCube::Schedule.new(Time.utc(2020, 3, 1, 12)) do |s|
        s.add_recurrence_rule(IceCube::Rule.monthly.day_of_month(1))
        s.add_recurrence_rule(IceCube::Rule.monthly.day_of_month(15))
        s.add_exception_time(Time.utc(2020, 3, 1, 12))
      end

      expect(schedule.occurrence_at(0)).to eq(Time.utc(2020, 3, 15, 12))
      expect(schedule.occurrence_at(1)).to eq(Time.utc(2020, 4, 1, 12))
    end

    it "rejects negative indexes" do
      schedule = IceCube::Schedule.new(start_time) { |s| s.add_recurrence_rule(IceCube::Rule.daily) }

      expect { schedule.occurrence_at(-1) }.to raise_error(ArgumentError, /non-negative Integer/)
    end

    it "returns nil beyond a terminating schedule" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule(IceCube::Rule.daily.count(2))
      end

      expect(schedule.occurrence_at(2)).to be_nil
    end

    it "locates far leap-day and missing-month-day occurrences without linear expansion" do
      schedule = IceCube::Schedule.new(Time.utc(2000, 1, 31, 12)) do |s|
        s.add_recurrence_rule(IceCube::Rule.monthly.day_of_month(31))
        s.add_recurrence_rule(IceCube::Rule.yearly.month_of_year(2).day_of_month(29))
        s.add_exception_time(Time.utc(2004, 2, 29, 12))
      end
      planner = IceCube::FastOccurrencePlanner.new(schedule)

      expect(planner.occurrence_at(100)).to eq(Time.utc(2013, 12, 31, 12))
      expect(planner.occurrence_at(10_000)).to eq(Time.utc(3380, 10, 31, 12))
      expect(planner.occurrence_at(100_000)).to eq(Time.utc(15807, 8, 31, 12))
    end
  end

  describe :unsupported do
    it "raises a clear error instead of returning an unsupported result" do
      schedules = [
        IceCube::Schedule.new(Time.local(2020, 1, 1, 12)) { |s| s.add_recurrence_rule(IceCube::Rule.daily) },
        IceCube::Schedule.new(start_time) { |s| s.add_recurrence_rule(IceCube::Rule.hourly) },
        IceCube::Schedule.new(start_time) { |s| s.add_recurrence_rule(IceCube::Rule.daily.hour_of_day(9)) },
        IceCube::Schedule.new(start_time) { |s| s.add_recurrence_rule(IceCube::Rule.monthly.day_of_week(monday: [1])) }
      ]

      schedules.each do |schedule|
        expect { schedule.occurrence_at(0) }.to raise_error(IceCube::UnsupportedFastOccurrence)
      end
    end
  end
end

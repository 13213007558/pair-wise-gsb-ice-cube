require File.dirname(__FILE__) + "/../spec_helper"
require "date"

module IceCube
  describe "business_day_of_month" do
    # Short calendar for May 2024 that contains a Sunday make-up workday and
    # a weekday holiday:
    #   * Wed May 1 is a holiday (not a business day)
    #   * Sun May 5 is a make-up workday (a business day)
    # Every other weekday is a business day, every other weekend is not.
    let(:calendar) do
      BusinessCalendar.new(
        version: "short-cn-2024.05",
        holidays: [Date.new(2024, 5, 1)],
        working_weekends: [Date.new(2024, 5, 5)]
      )
    end

    before { IceCube.clear_calendars! }
    after { IceCube.clear_calendars! }

    before { IceCube.register_calendar(calendar) }

    def occurrences(ordinals, cal, start, finish)
      schedule = Schedule.new(Time.utc(start.year, start.month, start.day))
      schedule.add_recurrence_rule(
        Rule.monthly.business_day_of_month(*Array(ordinals), calendar: cal)
      )
      schedule.occurrences(Time.utc(finish.year, finish.month, finish.day))
    end

    describe "filter then count ordering" do
      it "implements the second-to-last-business-day agreement with make-up days" do
        dates = occurrences(-2, calendar, Date.new(2024, 4, 1), Date.new(2024, 5, 31))
        # April (plain weekdays) second to last is Apr 29; May (with the
        # Sunday make-up) has 23 business days, second to last is May 30.
        expect(dates.map { |time| [time.month, time.day] }).to eq([[4, 29], [5, 30]])
      end

      it "counts the Sunday make-up day and excludes the weekday holiday" do
        # May business days in order start with Thu 2, Fri 3, Sun 5, Mon 6.
        dates = occurrences([1, 3, 4], calendar, Date.new(2024, 5, 1), Date.new(2024, 6, 1))
        expect(dates.map { |time| [time.day, time.wday] }).to eq([
          [2, 4], # 1st business day (Thu; May 1 holiday is filtered)
          [5, 0], # 3rd business day (Sunday make-up is filtered IN)
          [6, 1]  # 4th business day (Mon)
        ])
      end

      it "does not expand weekdays first and only then drop holidays" do
        # A naive "weekdays, then exclude holidays" rule sees the make-up
        # Sunday as a weekend and would start counting at Mon 6 as #3.
        # Filtering before counting makes Fri 3 the 2nd business day.
        dates = occurrences(2, calendar, Date.new(2024, 5, 1), Date.new(2024, 6, 1))
        expect(dates.first.then { |time| [time.day, time.wday] }).to eq([3, 5])
      end

      it "counts make-up days from the end for negative ordinals" do
        dates = occurrences([-1, -2], calendar, Date.new(2024, 5, 1), Date.new(2024, 5, 31))
        expect(dates.map { |time| [time.day, time.wday] }).to eq([
          [30, 4], # second to last business day: Thu May 30
          [31, 5]  # last business day: Fri May 31
        ])
      end

      it "uses the caller calendar for every month, not just the first" do
        dates = occurrences(1, calendar, Date.new(2024, 4, 1), Date.new(2024, 6, 30))
        expect(dates.map(&:day)).to eq([1, 2, 3]) # Apr 1, May 2 (holiday), Jun 3 (Mon)
      end
    end

    describe "skipping months without enough business days" do
      let(:plain) { BusinessCalendar.new(version: "plain-weekdays-1") }

      it "skips months that cannot satisfy a positive ordinal" do
        # Business day counts: Jan 23, Feb 21, Mar 21, Apr 22, May 23, Jun 20
        dates = occurrences(22, plain, Date.new(2024, 1, 1), Date.new(2024, 7, 1))
        expect(dates.map { |time| [time.month, time.day] }).to eq([
          [1, 30], # 22nd of Jan
          [4, 30], # Feb (21) and Mar (21) skipped
          [5, 30]  # Jun (20) skipped
        ])
      end

      it "never borrows an occurrence from the following month" do
        # 23 business days exist in Jan and May; Feb/Mar/Apr (21/21/22) skip
        # rather than borrowing a date from the following month.
        dates = occurrences(23, plain, Date.new(2024, 1, 1), Date.new(2024, 4, 30))
        expect(dates.map(&:month)).to eq([1])
      end

      it "skips months that cannot satisfy a negative ordinal" do
        dates = occurrences(-22, plain, Date.new(2024, 1, 1), Date.new(2024, 7, 1))
        expect(dates.map { |time| [time.month, time.day] }).to eq([
          [1, 2],  # -22 == 2nd in Jan (23 business days)
          [4, 1],  # Feb/Mar (21) skipped; -22 == 1st in Apr (22)
          [5, 2]   # 2nd in May (22); Jun (20) skipped
        ])
      end

      it "skips the month rather than clamping a negative ordinal" do
        # -22 in a 21-business-day month must not become -1 (the last day).
        dates = occurrences([-22, -1], plain, Date.new(2024, 2, 1), Date.new(2024, 3, 1))
        expect(dates.map(&:day)).to eq([29]) # only Feb -1; -22 skipped
      end
    end

    describe "multiple ordinals" do
      it "emits one occurrence per ordinal within a month" do
        dates = occurrences([1, -1], BusinessCalendar.new(version: "multi"),
                            Date.new(2024, 2, 1), Date.new(2024, 2, 29))
        expect(dates.map(&:day)).to eq([1, 29])
      end

      it "accepts flattened arrays" do
        dates = occurrences([[1, 2]], BusinessCalendar.new(version: "flatten"),
                            Date.new(2024, 2, 1), Date.new(2024, 2, 29))
        expect(dates.map(&:day)).to eq([1, 2])
      end
    end

    describe "with other rule parts" do
      let(:plain) { BusinessCalendar.new(version: "combo-plain") }

      it "preserves the schedule start time of day" do
        schedule = Schedule.new(Time.utc(2024, 1, 15, 9, 30))
        schedule.rrule Rule.monthly.business_day_of_month(-2, calendar: plain)
        expect(schedule.first(3).map { |time| [time.day, time.hour, time.min] })
          .to eq([[30, 9, 30], [28, 9, 30], [28, 9, 30]])
      end

      it "combines with month_of_year on yearly rules" do
        schedule = Schedule.new(Time.utc(2024, 1, 1))
        schedule.rrule(
          Rule.yearly.month_of_year(:february).business_day_of_month(1, calendar: plain)
        )
        dates = schedule.occurrences(Time.utc(2026, 12, 31))
        expect(dates.map { |time| [time.year, time.month, time.day] })
          .to eq([[2024, 2, 1], [2025, 2, 3], [2026, 2, 2]])
      end

      it "respects count termination" do
        schedule = Schedule.new(Time.utc(2024, 2, 1, 9))
        schedule.rrule Rule.monthly.business_day_of_month(1, calendar: plain).count(3)
        expect(schedule.all_occurrences.map { |time| [time.month, time.day] })
          .to eq([[2, 1], [3, 1], [4, 1]])
      end

      it "accepts any object responding to business_day? and version" do
        custom = Object.new
        def custom.version; "odd-days"; end
        def custom.business_day?(date); date.day.odd?; end
        IceCube.register_calendar(custom)
        schedule = Schedule.new(Time.utc(2024, 5, 1))
        schedule.rrule Rule.monthly.business_day_of_month(2, calendar: custom)
        expect(schedule.occurrences(Time.utc(2024, 5, 31)).map(&:day)).to eq([3])
      end
    end

    describe "argument validation" do
      it "requires a calendar" do
        expect { Rule.monthly.business_day_of_month(1) }
          .to raise_error(ArgumentError)
      end

      it "rejects zero and non-integer ordinals" do
        cal = BusinessCalendar.new(version: "args")
        expect { Rule.monthly.business_day_of_month(0, calendar: cal) }
          .to raise_error(ArgumentError, /non-zero Integer/)
        expect { Rule.monthly.business_day_of_month("1", calendar: cal) }
          .to raise_error(ArgumentError, /non-zero Integer/)
      end

      it "rejects calendars that cannot answer business_day?" do
        expect { Rule.monthly.business_day_of_month(1, calendar: Object.new) }
          .to raise_error(ArgumentError, /business_day\?/)
      end
    end

    describe "serialization" do
      it "binds the calendar version into the serialized rule" do
        rule = Rule.monthly.business_day_of_month(1, -2, calendar: calendar)
        expect(rule.to_hash[:validations][:business_day_of_month]).to eq(
          [[1, "short-cn-2024.05"], [-2, "short-cn-2024.05"]]
        )
      end

      it "round-trips through YAML when the calendar version is registered" do
        rule = Rule.monthly.business_day_of_month(-2, calendar: calendar)
        IceCube.register_calendar(calendar)
        restored = Rule.from_yaml(rule.to_yaml)
        expect(restored).to eq(rule)
        original_schedule = Schedule.new(Time.utc(2024, 5, 1)) { |s| s.rrule(rule) }
        restored_schedule = Schedule.new(Time.utc(2024, 5, 1)) { |s| s.rrule(restored) }
        expect(restored_schedule.first(3)).to eq(original_schedule.first(3))
      end

      it "round-trips through a Schedule and keeps the make-up Sunday" do
        schedule = Schedule.new(Time.utc(2024, 4, 1))
        schedule.rrule Rule.monthly.business_day_of_month(1, calendar: calendar)
        IceCube.register_calendar(calendar)
        restored = Schedule.from_yaml(schedule.to_yaml)
        expect(restored.occurrences(Time.utc(2024, 5, 31)).map(&:day)).to eq([1, 2])
      end

      it "raises on deserialization when the version is unknown" do
        yaml = Rule.monthly.business_day_of_month(1, calendar: calendar).to_yaml
        IceCube.clear_calendars!
        expect { Rule.from_yaml(yaml) }
          .to raise_error(CalendarVersionNotFound, /short-cn-2024\.05/)
      end

      it "cannot be rendered to iCalendar" do
        rule = Rule.monthly.business_day_of_month(1, calendar: calendar)
        expect { rule.to_ical }.to raise_error(ArgumentError, /iCalendar/)
      end
    end

    it "describes positive and negative ordinals" do
      rule = Rule.monthly.business_day_of_month(
        1, -2, calendar: BusinessCalendar.new(version: "desc")
      )
      expect(rule.to_s).to eq(
        "Monthly on the 1st and 2nd to last business days of the month"
      )
    end
  end
end

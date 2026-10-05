require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
 describe "business_day_of_month" do
 # Short calendar covering March 2024:
 # * Fri 2024-03-08 is a public holiday (non-working weekday)
 # * Sun 2024-03-31 is a make-up workday (working weekend)
 # * every other day follows its weekday/weekend status
 let(:calendar) {
 BusinessCalendar.build(
 version: "short-2024-03-v1",
 holidays: [Date.new(2024, 3, 8)],
 working_weekends: [Date.new(2024, 3, 31)]
 )
 }

 # Business days of March 2024 under this calendar, in order:
 let(:march_business_days) {
 [1, 4, 5, 6, 7, 11, 12, 13, 14, 15,
 18, 19, 20, 21, 22, 25, 26, 27, 28, 29, 31]
 }

 describe "filtering before counting" do
 it "excludes holidays before computing ordinals" do
 validation = Rule.monthly
 .business_day_of_month(6, calendar: calendar)
 .validations_for(:business_day_of_month).first

 expect(validation.business_days(Time.utc(2024, 3, 1))).to eq(march_business_days)

 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule Rule.monthly.business_day_of_month(6, calendar: calendar)

 # 6th weekday would be Fri the 8th, which is a holiday; the 6th *business*
 # day after holiday filtering is Mon the 11th.
 expect(schedule.first(1)).to eq([Time.utc(2024, 3, 11)])
 end

 it "counts Sunday make-up workdays and lets negative ordinals land on them" do
 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule Rule.monthly.business_day_of_month(-1, calendar: calendar)

 # Last plain weekday is Fri the 29th; counting the Sunday make-up day the
 # last business day is Sun the 31st, and -2 is Fri the 29th.
 expect(schedule.occurrences(Time.utc(2024, 5, 1)).map(&:day)).to eq([31, 30])

 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule Rule.monthly.business_day_of_month(-2, calendar: calendar)
 expect(schedule.occurrences(Time.utc(2024, 5, 1)).map(&:day)).to eq([29, 29])
 end

 it "does not fall back to plain weekday matching when a holiday intervenes" do
 # -3 must be computed after removing the holiday and adding the make-up
 # Sunday: ...Thu 28, Fri 29, Sun 31, so -3 == Thu 28 (a plain-weekday
 # "last Thursday" rule would also give 28, so check -4 == Wed 27 and a
 # mixed calendar in which ordering matters): without the Sunday make-up
 # day, -1 would be Fri 29.
 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule Rule.monthly.business_day_of_month(1, -1, calendar: calendar)

 expect(
 schedule.occurrences_between(Time.utc(2024, 3, 1), Time.utc(2024, 3, 31, 23, 59, 59)).map(&:day)
 ).to eq([1, 31])
 expect(Time.utc(2024, 3, 31).sunday?).to eq(true)
 end
 end

 describe "ordinals" do
    it "supports positive, negative and multiple ordinals in one rule" do
      schedule = Schedule.new(Time.utc(2024, 3, 1))
      schedule.add_recurrence_rule Rule.monthly
        .business_day_of_month(1, 15, -2, -1, calendar: calendar)

      days = schedule.occurrences_between(Time.utc(2024, 3, 1), Time.utc(2024, 3, 31, 23, 59, 59)).map(&:day)
      # Business-day position 15 falls on Fri the 22nd because Fri the 8th is
      # filtered out first; the Sunday make-up day shifts the tail so -2 is
      # Fri the 29th and -1 is Sun the 31st.
      expect(days).to eq([1, 22, 29, 31])
    end

 it "accepts arrays of ordinals" do
 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule Rule.monthly
 .business_day_of_month([1, -1], calendar: calendar)

 expect(
 schedule.occurrences_between(Time.utc(2024, 3, 1), Time.utc(2024, 3, 31, 23, 59, 59)).map(&:day)
 ).to eq([1, 31])
 end

 it "rejects zero and non-integer ordinals" do
 expect {
 Rule.monthly.business_day_of_month(0, calendar: calendar)
 }.to raise_error(ArgumentError, /non-zero Integer/)
 expect {
 Rule.monthly.business_day_of_month("1", calendar: calendar)
 }.to raise_error(ArgumentError, /non-zero Integer/)
 end
 end

 describe "short months" do
 it "skips a month without enough business days instead of spilling over" do
 # March 2024 has 21 business days under the short calendar.
 schedule = Schedule.new(Time.utc(2024, 2, 1))
 schedule.add_recurrence_rule Rule.monthly
 .business_day_of_month(22, calendar: calendar)

 occurrences = schedule.occurrences(Time.utc(2024, 7, 1))
 # February (21 weekdays) and March (21 business days) are skipped;
 # April (22 weekdays) contributes Tue Apr 30; nothing lands in March from
 # an April target or vice versa.
 expect(occurrences.map { |t| [t.month, t.day] }).to include([4, 30])
 expect(occurrences.map(&:month)).not_to include(3)
 end

 it "emits no occurrence for a month missing only a negative ordinal" do
 # A calendar where March has exactly one business day: the 1st. -2 cannot
 # resolve inside March, so March is skipped even though other months match.
 sparse = BusinessCalendar.build(
 version: "sparse-2024-03-v1",
 holidays: (1..31).map { |d| Date.new(2024, 3, d) } - [Date.new(2024, 3, 1)]
 )
 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule Rule.monthly
 .business_day_of_month(-2, calendar: sparse)

 expect(schedule.occurrences(Time.utc(2024, 5, 1)).map(&:month)).not_to include(3)
 end
 end

 describe "calendar binding" do
    it "requires a calendar" do
      expect {
        Rule.monthly.business_day_of_month(1)
      }.to raise_error(ArgumentError, /version is required/)
      expect {
        Rule.monthly.business_day_of_month(1, calendar: "not-a-calendar")
      }.to raise_error(IceCube::UnknownCalendarVersion)
 end

 it "accepts any object responding to business_day? and calendar_version" do
 custom = Object.new
 def custom.calendar_version
 "custom-v1"
 end
 def custom.business_day?(date)
 date.wday.between?(1, 5)
 end

 rule = Rule.monthly.business_day_of_month(-1, calendar: custom)
 schedule = Schedule.new(Time.utc(2024, 3, 1))
 schedule.add_recurrence_rule rule
 expect(schedule.first(1)).to eq([Time.utc(2024, 3, 29)])
 end

 it "refuses a calendar without a serializable version" do
 custom = Object.new
 def custom.business_day?(_date)
 true
 end

 expect {
 Rule.monthly.business_day_of_month(1, calendar: custom)
 }.to raise_error(ArgumentError, /calendar_version/)
 end
 end

 describe "serialization" do
 let(:rule) {
 Rule.monthly.business_day_of_month(1, -2, -1, calendar: calendar)
 }

 it "stores the calendar version in the hash" do
 expect(rule.to_hash[:business_calendar_version]).to eq("short-2024-03-v1")
 expect(rule.to_hash[:validations][:business_day_of_month]).to eq([-2, -1, 1])
 end

 it "round-trips through Rule.from_hash" do
 restored = Rule.from_hash(rule.to_hash)
 expect(restored).to eq(rule)
 expect(restored.to_s).to eq(rule.to_s)
 restored_schedule = Schedule.new(Time.utc(2024, 3, 1))
 restored_schedule.add_recurrence_rule restored
 expect(
 restored_schedule.occurrences_between(Time.utc(2024, 3, 1), Time.utc(2024, 3, 31, 23, 59, 59)).map(&:day)
 ).to eq([1, 29, 31])
 end

    it "round-trips through YAML" do
      restored = Rule.from_yaml(rule.to_yaml)
      expect(restored).to eq(rule)

      schedule = Schedule.new(Time.utc(2024, 3, 1))
      schedule.add_recurrence_rule rule
      restored_schedule = Schedule.from_yaml(schedule.to_yaml)
      expect(restored_schedule.first(3)).to eq(schedule.first(3))
    end

    it "round-trips through Schedule.from_hash" do
      schedule = Schedule.new(Time.utc(2024, 3, 1))
      schedule.add_recurrence_rule rule
      restored_schedule = Schedule.from_hash(schedule.to_hash)
      expect(
        restored_schedule.occurrences_between(Time.utc(2024, 3, 1), Time.utc(2024, 3, 31, 23, 59, 59)).map(&:day)
      ).to eq([1, 29, 31])
    end

    it "raises when no calendar version is stored in the hash" do
      payload = rule.to_hash
      payload.delete(:business_calendar_version)
      expect {
        Rule.from_hash(payload)
      }.to raise_error(ArgumentError, /business_calendar_version/)
    end

 it "raises when the serialized calendar version is not registered" do
 payload = rule.to_hash
 BusinessCalendar.reset!
 expect {
 Rule.from_hash(payload)
 }.to raise_error(UnknownCalendarVersion, /short-2024-03-v1/)
 end

 it "does not serialize to iCalendar" do
 expect { rule.to_ical }.to raise_error(ArgumentError, /iCalendar/)
 end
 end

 describe "string output" do
 it "describes positive and negative ordinals" do
 rule = Rule.monthly.business_day_of_month(1, -1, calendar: calendar)
 expect(rule.to_s)
 .to eq("Monthly on the last and 1st business days of the month")
 end
 end
 end
end

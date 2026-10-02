require "active_support"
require "active_support/time"
require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
  describe CalendarDuration, "with calendar and exact durations" do
    before { Time.zone = "America/New_York" }
    def daily_schedule(duration, **options)
      Schedule.new(Time.zone.local(2020, 3, 7, 9), duration: duration, **options) do |schedule|
        schedule.add_recurrence_rule Rule.daily
      end
    end

    it "calculates P1D on the local calendar and PT24H from elapsed seconds" do
      occurrences = daily_schedule("P1D", nonexistent_time: :forward).first(2)

      expect(occurrences.map { |occurrence| [occurrence.start_time, occurrence.end_time] }).to eq([
        [Time.zone.local(2020, 3, 7, 9), Time.zone.local(2020, 3, 8, 9)],
        [Time.zone.local(2020, 3, 8, 9), Time.zone.local(2020, 3, 9, 9)]
      ])
      expect(occurrences.map(&:duration)).to eq([23 * ONE_HOUR, 24 * ONE_HOUR])

      exact_occurrences = daily_schedule(ONE_DAY).first(2)
      expect(exact_occurrences.map(&:end_time)).to eq([
        Time.zone.local(2020, 3, 8, 10),
        Time.zone.local(2020, 3, 9, 9)
      ])
      expect(exact_occurrences.map(&:duration)).to eq([ONE_DAY, ONE_DAY])
    end

    it "keeps cross-midnight occurrences on their own local end time" do
      schedule = Schedule.new(Time.zone.local(2020, 3, 6, 22), duration: "PT6H")
      first = schedule.first

      expect(first.start_time).to eq(Time.zone.local(2020, 3, 6, 22))
      expect(first.end_time).to eq(Time.zone.local(2020, 3, 7, 4))
      expect(first.overnight?).to be(true)
      expect(schedule.occurring_at?(Time.zone.local(2020, 3, 7, 3, 59, 59))).to be(true)
      expect(schedule.occurring_at?(Time.zone.local(2020, 3, 7, 4))).to be(false)
    end

    it "applies selected policy when P1D ends in the autumn repeated hour" do
      start_time = Time.zone.local(2020, 10, 31, 1, 30)

      first = Schedule.new(start_time, duration: "P1D", ambiguous_time: :first).first
      last = Schedule.new(start_time, duration: "P1D", ambiguous_time: :last).first
      exact = Schedule.new(start_time, duration: ONE_DAY).first

      expect(first.end_time.iso8601).to eq("2020-11-01T01:30:00-04:00")
      expect(last.end_time.iso8601).to eq("2020-11-01T01:30:00-05:00")
      expect(exact.end_time.iso8601).to eq("2020-11-01T01:30:00-04:00")
      expect(first.duration).to eq(ONE_DAY)
      expect(last.duration).to eq(25 * ONE_HOUR)
      expect(exact.duration).to eq(ONE_DAY)
    end

    it "applies selected policies when a calendar day lands in a spring gap" do
      start_time = Time.zone.local(2020, 3, 7, 2, 30)

      forward = Schedule.new(start_time, duration: "P1D", nonexistent_time: :forward).first
      backward = Schedule.new(start_time, duration: "P1D", nonexistent_time: :backward).first

      expect(forward.end_time.iso8601).to eq("2020-03-08T03:30:00-04:00")
      expect(backward.end_time.iso8601).to eq("2020-03-08T01:30:00-05:00")
    end

    it "uses each occurrence end point for spanning interval queries" do
      calendar_schedule = daily_schedule("P1D", nonexistent_time: :forward)
      exact_schedule = daily_schedule("PT24H")

      calendar_queried = calendar_schedule.occurrences_between(
        Time.zone.local(2020, 3, 8, 9),
        Time.zone.local(2020, 3, 8, 10, 30),
        spans: true
      )
      exact_queried = exact_schedule.occurrences_between(
        Time.zone.local(2020, 3, 8, 9),
        Time.zone.local(2020, 3, 8, 10, 30),
        spans: true
      )

      expect(calendar_queried.map(&:start_time)).to eq([Time.zone.local(2020, 3, 8, 9)])
      expect(exact_queried.map(&:start_time)).to eq([
        Time.zone.local(2020, 3, 7, 9),
        Time.zone.local(2020, 3, 8, 9)
      ])
      expect(exact_schedule.occurring_between?(
        Time.zone.local(2020, 3, 8, 9),
        Time.zone.local(2020, 3, 8, 10, 30)
      )).to be(true)
    end

    it "uses actual occurrence end points for conflicts_with?" do
      day_schedule = Schedule.new(Time.zone.local(2020, 3, 7, 9), duration: "P1D", nonexistent_time: :forward)
      boundary = Schedule.new(Time.zone.local(2020, 3, 8, 9), duration: ONE_MINUTE)
      overlapping = Schedule.new(Time.zone.local(2020, 3, 8, 8, 59), duration: ONE_MINUTE)

      expect(day_schedule.conflicts_with?(boundary, Time.zone.local(2020, 3, 10))).to be(false)
      expect(day_schedule.conflicts_with?(overlapping, Time.zone.local(2020, 3, 10))).to be(true)
    end

    it "round-trips the P1D versus PT24H distinction through iCalendar" do
      calendar_schedule = daily_schedule("P1D", ambiguous_time: :first, nonexistent_time: :forward)
      exact_schedule = daily_schedule("PT24H")

      expect(calendar_schedule.to_ical).to include("DURATION:P1D")
      expect(calendar_schedule.to_ical).to include("X-ICECUBE-AMBIGUOUS-TIME:first")
      expect(calendar_schedule.to_ical).to include("X-ICECUBE-NONEXISTENT-TIME:forward")
      expect(exact_schedule.to_ical).to include("DURATION:PT24H")

      restored_calendar = Schedule.from_ical(calendar_schedule.to_ical)
      restored_exact = Schedule.from_ical(exact_schedule.to_ical)
      expect(restored_calendar.first(2).map(&:end_time)).to eq(calendar_schedule.first(2).map(&:end_time))
      expect(restored_exact.first(2).map(&:end_time)).to eq(exact_schedule.first(2).map(&:end_time))
    end

    it "round-trips the P1D versus PT24H distinction through hash and YAML" do
      calendar_schedule = daily_schedule("P1D", ambiguous_time: :first, nonexistent_time: :forward)
      exact_schedule = daily_schedule("PT24H")

      expect(calendar_schedule.to_hash[:duration]).to eq("P1D")
      expect(exact_schedule.to_hash[:duration]).to eq("PT24H")

      [
        Schedule.from_hash(calendar_schedule.to_hash),
        Schedule.from_yaml(calendar_schedule.to_yaml)
      ].each do |restored|
        expect(restored.first(2).map(&:end_time)).to eq(calendar_schedule.first(2).map(&:end_time))
      end

      [
        Schedule.from_hash(exact_schedule.to_hash),
        Schedule.from_yaml(exact_schedule.to_yaml)
      ].each do |restored|
        expect(restored.first(2).map(&:end_time)).to eq([
          Time.zone.local(2020, 3, 8, 10),
          Time.zone.local(2020, 3, 9, 9)
        ])
      end
    end

    it "keeps duration semantics in schedule equality" do
      expect(daily_schedule("P1D", nonexistent_time: :forward)).not_to eq(daily_schedule(ONE_DAY))
      expect(daily_schedule("P1D", ambiguous_time: :first)).not_to eq(
        daily_schedule("P1D", ambiguous_time: :last)
      )
    end
  end
end

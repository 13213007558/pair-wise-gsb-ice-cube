require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
  describe CalendarDuration do
    it "distinguishes a calendar day from 24 clock hours as a value" do
      expect(CalendarDuration.new(days: 1).to_ical).to eq("P1D")
      expect(CalendarDuration.new(hours: 24).to_ical).to eq("PT24H")
      expect(CalendarDuration.parse("P1D")).to eq(CalendarDuration.new(days: 1))
      expect(CalendarDuration.parse("PT24H")).to eq(CalendarDuration.new(hours: 24))
      expect(CalendarDuration.parse("P1D")).not_to eq(CalendarDuration.new(hours: 24))
    end

    it "reports calendar units and clock seconds separately" do
      expect(CalendarDuration.new(days: 1).calendar_units?).to be(true)
      expect(CalendarDuration.new(hours: 24).calendar_units?).to be(false)
      expect(CalendarDuration.new(hours: 24).clock_seconds).to eq(24 * ONE_HOUR)
      expect(CalendarDuration.new(days: 1).clock_seconds).to eq(0)
    end

    it "rejects unknown policies" do
      expect { CalendarDuration.new(days: 1, nonexistent: :nope) }
        .to raise_error(ArgumentError)
      expect { CalendarDuration.new(days: 1, ambiguous: :nope) }
        .to raise_error(ArgumentError)
    end

    it "round-trips through a hash" do
      duration = CalendarDuration.new(weeks: 1, days: 2, hours: 3,
                                      minutes: 4, seconds: 5,
                                      nonexistent: :forward, ambiguous: :later)
      expect(CalendarDuration.from_hash(duration.to_hash)).to eq(duration)
      expect(duration.to_ical).to eq("P1W2DT3H4M5S")
    end
  end

  describe Schedule, "calendar duration", system_time_zone: "America/New_York" do
    # US DST 2010: clocks spring forward 02:00 -> 03:00 on March 14 and
    # fall back 02:00 -> 01:00 on November 7.
    before(:each) do
      @spring = Time.local(2010, 3, 13, 9, 0, 0)
      @fall = Time.local(2010, 11, 6, 9, 0, 0)
    end

    it "keeps the wall-clock hour for P1D but advances an hour for PT24H in spring" do
      day = Schedule.new(@spring, duration: CalendarDuration.new(days: 1))
      hours = Schedule.new(@spring, duration: CalendarDuration.new(hours: 24))
      day.add_recurrence_rule Rule.daily
      hours.add_recurrence_rule Rule.daily

      occurrence = day.first
      expect(occurrence.start_time).to eq(Time.local(2010, 3, 13, 9))
      expect(occurrence.end_time).to eq(Time.local(2010, 3, 14, 9))
      expect(occurrence.duration).to eq(23 * ONE_HOUR)

      occurrence = hours.first
      expect(occurrence.end_time).to eq(Time.local(2010, 3, 14, 10))
      expect(occurrence.duration).to eq(24 * ONE_HOUR)
    end

    it "calculates each occurrence end from its own start in spring" do
      schedule = Schedule.new(@spring, duration: CalendarDuration.new(days: 1))
      schedule.add_recurrence_rule Rule.daily.count(3)
      occurrences = schedule.first(3)
      expect(occurrences.map(&:end_time)).to eq([
        Time.local(2010, 3, 14, 9),
        Time.local(2010, 3, 15, 9),
        Time.local(2010, 3, 16, 9)
      ])
      expect(occurrences.map { |occurrence| occurrence.duration.to_i }).to eq([23, 24, 24].map { |h| h * ONE_HOUR })
    end

    it "does the same across the fall-back transition" do
      schedule = Schedule.new(@fall, duration: CalendarDuration.new(days: 1))
      schedule.add_recurrence_rule Rule.daily.count(2)
      occurrences = schedule.first(2)
      expect(occurrences.map(&:end_time)).to eq([
        Time.local(2010, 11, 7, 9),
        Time.local(2010, 11, 8, 9)
      ])
      expect(occurrences.first.duration).to eq(25 * ONE_HOUR)

      elapsed = Schedule.new(@fall, duration: CalendarDuration.new(hours: 24))
      elapsed.add_recurrence_rule Rule.daily.count(2)
      expect(elapsed.first(2).map(&:end_time)).to eq([
        Time.local(2010, 11, 7, 8),
        Time.local(2010, 11, 8, 9)
      ])
    end

    it "supports a duration ending across midnight before a spring transition" do
      start = Time.local(2010, 3, 13, 23, 0, 0)
      day = Schedule.new(start, duration: CalendarDuration.new(days: 1)).first
      hours = Schedule.new(start, duration: CalendarDuration.new(hours: 24)).first
      expect(day.end_time).to eq(Time.local(2010, 3, 14, 23))
      expect(day.duration).to eq(23 * ONE_HOUR)
      expect(hours.end_time).to eq(Time.local(2010, 3, 15, 0))
      expect(hours.duration).to eq(24 * ONE_HOUR)
    end

    it "uses the actual end point in spanning range queries" do
      schedule = Schedule.new(@fall, duration: CalendarDuration.new(days: 1))
      schedule.add_recurrence_rule Rule.daily.count(1)
      # 08:30 on the fall-back day is inside the 25-hour occurrence
      inside = Time.local(2010, 11, 7, 8, 30)
      outside = Time.local(2010, 11, 7, 9, 30)
      expect(schedule.occurring_at?(inside)).to be(true)
      expect(schedule.occurring_at?(outside)).to be(false)
      expect(schedule.occurring_between?(inside, inside + 1)).to be(true)
      expect(schedule.occurring_between?(outside, outside + 1)).to be(false)
    end

    it "uses the actual end point for conflicts_with?" do
      long = Schedule.new(@fall, duration: CalendarDuration.new(days: 1))
      long.add_recurrence_rule Rule.daily.count(1)
      # Starts at 08:00 on the 25-hour occurrence; PT24H would have ended then
      other = Schedule.new(Time.local(2010, 11, 7, 8, 30), duration: ONE_HOUR)
      expect(long.conflicts_with?(other)).to be(true)

      elapsed = Schedule.new(@fall, duration: CalendarDuration.new(hours: 24))
      elapsed.add_recurrence_rule Rule.daily.count(1)
      expect(elapsed.conflicts_with?(other)).to be(false)
    end

    it "raises by default when the end lands on a repeated local time" do
      start = Time.local(2010, 11, 6, 1, 30)
      expect { Schedule.new(start, duration: CalendarDuration.new(days: 1)) }
        .to raise_error(InvalidLocalTimeError)
    end

    it "lets the caller pick either occurrence of a repeated local time" do
      start = Time.local(2010, 11, 6, 1, 30)
      earlier = Schedule.new(start, duration: CalendarDuration.new(days: 1, ambiguous: :earlier)).first
      later = Schedule.new(start, duration: CalendarDuration.new(days: 1, ambiguous: :later)).first
      expect(earlier.end_time).to eq(Time.new(2010, 11, 7, 1, 30, 0, "-04:00"))
      expect(later.end_time).to eq(Time.new(2010, 11, 7, 1, 30, 0, "-05:00"))
      expect(earlier.duration).to eq(24 * ONE_HOUR)
      expect(later.duration).to eq(25 * ONE_HOUR)
    end

    it "lets the caller choose a policy for a nonexistent local time" do
      start = Time.local(2010, 3, 13, 2, 30)
      forward = Schedule.new(start, duration: CalendarDuration.new(days: 1, nonexistent: :forward)).first
      backward = Schedule.new(start, duration: CalendarDuration.new(days: 1, nonexistent: :backward)).first
      expect(forward.end_time).to eq(Time.local(2010, 3, 14, 3, 30))
      expect(backward.end_time).to eq(Time.local(2010, 3, 14, 1, 30))
      expect { Schedule.new(start, duration: CalendarDuration.new(days: 1)).first }
        .to raise_error(InvalidLocalTimeError)
    end

    it "keeps P1D and PT24H distinct in iCalendar, hash and YAML" do
      day = Schedule.new(@spring, duration: CalendarDuration.new(days: 1))
      hours = Schedule.new(@spring, duration: CalendarDuration.new(hours: 24))
      expect(day.to_ical).to include("DURATION:P1D")
      expect(hours.to_ical).to include("DURATION:PT24H")
      expect(day.to_hash[:duration]).to include(days: 1, hours: 0)
      expect(hours.to_hash[:duration]).to include(days: 0, hours: 24)
      expect(day.hash).not_to eq(hours.hash)

      [day, hours].each do |schedule|
        from_ical = Schedule.from_ical(schedule.to_ical)
        expect(from_ical.duration).to eq(schedule.duration)
        expect(from_ical.first.end_time).to eq(schedule.first.end_time)
        from_hash = Schedule.from_hash(schedule.to_hash)
        expect(from_hash.duration).to eq(schedule.duration)
        from_yaml = Schedule.from_yaml(schedule.to_yaml)
        expect(from_yaml.calendar_duration).to eq(schedule.calendar_duration)
      end
    end

    it "preserves ambiguity policies through YAML and hash" do
      schedule = Schedule.new(@fall, duration: CalendarDuration.new(days: 1, ambiguous: :later))
      restored = Schedule.from_yaml(schedule.to_yaml)
      expect(restored.calendar_duration.ambiguous).to eq(:later)
      expect(Schedule.from_hash(schedule.to_hash).calendar_duration.ambiguous).to eq(:later)
    end

    it "still treats a numeric duration as elapsed seconds" do
      schedule = Schedule.new(@spring, duration: 24 * ONE_HOUR)
      expect(schedule.duration).to eq(24 * ONE_HOUR)
      expect(schedule.calendar_duration).to be_nil
      expect(schedule.first.end_time).to eq(Time.local(2010, 3, 14, 10))
    end
  end
end

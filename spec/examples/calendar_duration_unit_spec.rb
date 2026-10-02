require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
  describe CalendarDuration do
    it "parses and serializes weeks and time-only durations" do
      expect(CalendarDuration.parse("P1W").to_s).to eq("P1W")
      expect(CalendarDuration.parse("PT24H").to_s).to eq("PT24H")
    end

    it "rejects combined week durations and invalid strings" do
      expect { CalendarDuration.parse("P1W1D") }.to raise_error(ArgumentError)
      expect { CalendarDuration.parse("1D") }.to raise_error(ArgumentError)
    end

    it "treats zero numeric duration as elapsed seconds" do
      schedule = Schedule.new(Time.utc(2020, 1, 1), duration: 0)
      expect(schedule.duration).to eq(0)
      expect(schedule.end_time).to be_nil
    end

    it "raises by default when a nominal end is ambiguous", system_time_zone: "America/New_York" do
      duration = CalendarDuration.parse("P1D")
      expect { duration.after(Time.local(2020, 10, 31, 1, 30)) }
        .to raise_error(ArgumentError, /ambiguous/)
    end
  end
end

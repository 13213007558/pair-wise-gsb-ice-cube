require File.dirname(__FILE__) + "/../spec_helper"
require "date"

module IceCube
  describe BusinessCalendar do
    it "treats weekdays as business days by default" do
      calendar = BusinessCalendar.new(version: "v1")
      expect(calendar.business_day?(Date.new(2024, 5, 6))).to eq(true) # Monday
      expect(calendar.business_day?(Date.new(2024, 5, 4))).to eq(false) # Saturday
    end

    it "removes weekday holidays and includes weekend make-up days" do
      calendar = BusinessCalendar.new(
        version: "cn-may-2024",
        holidays: [Date.new(2024, 5, 1)],
        working_weekends: [Date.new(2024, 5, 5)]
      )
      expect(calendar.business_day?(Date.new(2024, 5, 1))).to eq(false) # holiday
      expect(calendar.business_day?(Date.new(2024, 5, 5))).to eq(true) # Sunday make-up
      expect(calendar.business_day?(Date.new(2024, 5, 4))).to eq(false) # regular Saturday
    end

    it "accepts a custom predicate and a serializable version" do
      calendar = BusinessCalendar.new(version: "custom-2024.1") do |date|
        date.wday != 3
      end
      expect(calendar.business_day?(Date.new(2024, 5, 1))).to eq(false) # Wednesday
      expect(calendar.version).to eq("custom-2024.1")
    end

    describe CalendarRegistry do
      after { IceCube.clear_calendars! }

      it "registers and looks calendars up by version" do
        calendar = BusinessCalendar.new(version: "lookup")
        IceCube.register_calendar(calendar)
        expect(IceCube.calendar_for_version("lookup")).to equal(calendar)
      end

      it "raises a versioned error when the calendar is not registered" do
        expect { IceCube.calendar_for_version("missing") }
          .to raise_error(CalendarVersionNotFound, /missing/)
      end

      it "rejects calendars without a non-blank version" do
        expect { IceCube.register_calendar(Object.new) }
          .to raise_error(ArgumentError, /version/)
      end
    end
  end
end

require File.dirname(__FILE__) + "/../spec_helper"

describe IceCube::YearlyRule, "week_of_year (BYWEEKNO)" do
  def occurrences_of(rule, start_time, count)
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule(rule)
    schedule.first(count)
  end

  it "selects days in the given week, where week 1 may start in the previous year" do
    # WKST defaults to Monday (RFC 5545); week 1 is the first week with at
    # least four days in the new year.
    #   week 1 of 2024 starts Monday 2024-01-01
    #   week 1 of 2025 starts Monday 2024-12-30
    #   week 1 of 2026 starts Monday 2025-12-29
    #   week 1 of 2027 starts Monday 2027-01-04
    rule = IceCube::Rule.yearly.week_of_year(1).day(:monday)
    expect(occurrences_of(rule, Time.utc(2024, 1, 1, 9, 0, 0), 5)).to eq [
      Time.utc(2024, 1, 1, 9, 0, 0),
      Time.utc(2024, 12, 30, 9, 0, 0),
      Time.utc(2025, 12, 29, 9, 0, 0),
      Time.utc(2027, 1, 4, 9, 0, 0),
      Time.utc(2028, 1, 3, 9, 0, 0)
    ]
  end

  it "counts negative week numbers from the end of the week\u2019s year" do
    # 2024 and 2025 have 52 weeks, 2026 has 53 (all per WKST=MO), so week -1
    # is week 52, 52 and 53 respectively.
    rule = IceCube::Rule.yearly.week_of_year(-1).day(:monday)
    expect(occurrences_of(rule, Time.utc(2024, 1, 1, 9, 0, 0), 4)).to eq [
      Time.utc(2024, 12, 23, 9, 0, 0),
      Time.utc(2025, 12, 22, 9, 0, 0),
      Time.utc(2026, 12, 28, 9, 0, 0),
      Time.utc(2027, 12, 27, 9, 0, 0)
    ]
  end

  it "only matches week 53 in years that have one" do
    # 2026, 2032 and 2037 are the next years with 53 weeks (WKST=MO).
    rule = IceCube::Rule.yearly.week_of_year(53).day(:monday)
    expect(occurrences_of(rule, Time.utc(2024, 1, 1, 9, 0, 0), 3)).to eq [
      Time.utc(2026, 12, 28, 9, 0, 0),
      Time.utc(2032, 12, 27, 9, 0, 0),
      Time.utc(2037, 12, 28, 9, 0, 0)
    ]
  end

  it "numbers weeks according to the rule's week_start (WKST)" do
    # With WKST=SU, week 1 of 2026 starts Sunday 2026-01-04, so its Monday
    # is 2026-01-05 rather than 2025-12-29.
    rule = IceCube::Rule.yearly.week_of_year(1, week_start: :sunday).day(:monday)
    expect(occurrences_of(rule, Time.utc(2024, 1, 1, 9, 0, 0), 3)).to eq [
      Time.utc(2024, 1, 1, 9, 0, 0),
      Time.utc(2024, 12, 30, 9, 0, 0),
      Time.utc(2026, 1, 5, 9, 0, 0)
    ]
  end

  it "supports multiple BYDAY values within the selected week" do
    # Week 1 of 2026 runs 2025-12-29 (Mon) through 2026-01-04 (Sun).
    rule = IceCube::Rule.yearly.week_of_year(1).day(:monday, :wednesday, :friday)
    expect(occurrences_of(rule, Time.utc(2025, 12, 25, 9, 0, 0), 5)).to eq [
      Time.utc(2025, 12, 29, 9, 0, 0),
      Time.utc(2025, 12, 31, 9, 0, 0),
      Time.utc(2026, 1, 2, 9, 0, 0),
      Time.utc(2027, 1, 4, 9, 0, 0),
      Time.utc(2027, 1, 6, 9, 0, 0)
    ]
  end

  it "defaults to the schedule start time's weekday without a BYDAY rule part" do
    # 2024-01-03 is a Wednesday, so expect Wednesday of week 20 each year.
    rule = IceCube::Rule.yearly.week_of_year(20)
    expect(occurrences_of(rule, Time.utc(2024, 1, 3, 9, 0, 0), 3)).to eq [
      Time.utc(2024, 5, 15, 9, 0, 0),
      Time.utc(2025, 5, 14, 9, 0, 0),
      Time.utc(2026, 5, 13, 9, 0, 0)
    ]
  end

  it "applies BYSETPOS to the occurrences within each year" do
    # Week 20 of 2024 is May 13-19; its weekdays are Mon 13th, Wed 15th, Fri 17th.
    first = IceCube::Rule.yearly.week_of_year(20).day(:monday, :wednesday, :friday).by_set_pos(1)
    expect(occurrences_of(first, Time.utc(2024, 1, 1, 9, 0, 0), 3)).to eq [
      Time.utc(2024, 5, 13, 9, 0, 0),
      Time.utc(2025, 5, 12, 9, 0, 0),
      Time.utc(2026, 5, 11, 9, 0, 0)
    ]

    last = IceCube::Rule.yearly.week_of_year(20).day(:monday, :wednesday, :friday).by_set_pos(-1)
    expect(occurrences_of(last, Time.utc(2024, 1, 1, 9, 0, 0), 3)).to eq [
      Time.utc(2024, 5, 17, 9, 0, 0),
      Time.utc(2025, 5, 16, 9, 0, 0),
      Time.utc(2026, 5, 15, 9, 0, 0)
    ]
  end

  it "applies COUNT after BYSETPOS selection" do
    # BYSETPOS=-1 selects the last weekday of each year's week 1 first;
    # COUNT=3 then stops the rule after three of those selections.
    rule = IceCube::Rule.from_ical("FREQ=YEARLY;BYWEEKNO=1;BYDAY=MO,WE,FR;BYSETPOS=-1;COUNT=3")
    expect(occurrences_of(rule, Time.utc(2024, 1, 1, 9, 0, 0), 5)).to eq [
      Time.utc(2024, 12, 30, 9, 0, 0),
      Time.utc(2025, 12, 31, 9, 0, 0),
      Time.utc(2026, 1, 2, 9, 0, 0)
    ]
  end

  it "applies UNTIL after week and weekday selection" do
    rule = IceCube::Rule.from_ical("FREQ=YEARLY;BYWEEKNO=1;BYDAY=MO,WE,FR;UNTIL=20260103T000000Z")
    expect(occurrences_of(rule, Time.utc(2025, 12, 25, 9, 0, 0), 5)).to eq [
      Time.utc(2025, 12, 29, 9, 0, 0),
      Time.utc(2025, 12, 31, 9, 0, 0),
      Time.utc(2026, 1, 2, 9, 0, 0)
    ]
  end

  it "rejects invalid week numbers" do
    expect { IceCube::Rule.yearly.week_of_year(0) }.to raise_error(ArgumentError)
    expect { IceCube::Rule.yearly.week_of_year(54) }.to raise_error(ArgumentError)
    expect { IceCube::Rule.yearly.week_of_year(-54) }.to raise_error(ArgumentError)
    expect { IceCube::Rule.yearly.week_of_year("1") }.to raise_error(ArgumentError)
  end

  it "is not available on non-yearly rules" do
    expect { IceCube::Rule.weekly.week_of_year(1) }.to raise_error(NoMethodError)
    expect { IceCube::Rule.monthly.week_of_year(1) }.to raise_error(NoMethodError)
  end

  it "serializes to a hash and back, preserving the week start" do
    rule = IceCube::Rule.yearly.week_of_year(1, -1, week_start: :sunday).day(:monday)
    hash = rule.to_hash
    expect(hash[:validations][:week_of_year]).to eq [1, -1]
    expect(hash[:week_start]).to eq 0

    restored = IceCube::Rule.from_hash(hash)
    expect(restored.week_start).to eq :sunday
    expect(restored).to eq rule
  end

  it "serializes to ical and back, preserving the week start" do
    rule = IceCube::Rule.from_ical("FREQ=YEARLY;WKST=SU;BYWEEKNO=1,-1;BYDAY=MO")
    expect(rule.week_start).to eq :sunday
    expect(rule.to_ical).to eq "FREQ=YEARLY;BYWEEKNO=1,-1;WKST=SU;BYDAY=MO"
  end

  it "omits WKST from ical when the week start is the RFC default" do
    rule = IceCube::Rule.yearly.week_of_year(1).day(:monday)
    expect(rule.to_ical).to eq "FREQ=YEARLY;BYWEEKNO=1;BYDAY=MO"
  end

  it "builds a sensible string" do
    expect(IceCube::Rule.yearly.week_of_year(-1).day(:monday).to_s).to eq(
      "Yearly on the last week of the year on Mondays"
    )
  end
end

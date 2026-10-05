require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
  describe RuleSimplifier do
    def simplify(rule_or_rules, dtstart: nil)
      RuleSimplifier.simplify(rule_or_rules, dtstart: dtstart)
    end

    it "removes duplicate alternatives from BY lists" do
      rule = Rule.monthly.day_of_week(monday: [1, 1]).day_of_month(1, 1).by_set_pos(1, 1)
      result = simplify(rule)

      expect(result.first.to_ical).to eq("FREQ=MONTHLY;BYDAY=1MO;BYMONTHDAY=1;BYSETPOS=1")
      expect(result.steps.map { |step| step[:action] }).to eq(%i[deduplicate deduplicate deduplicate])
      expect(result.steps.map { |step| step[:by_part] }).to eq(%w[BYDAY BYMONTHDAY BYSETPOS])
      expect(result.steps.map { |step| step[:basis] }.uniq)
        .to eq([:duplicate_values_within_a_by_part_are_the_same_alternative])
    end

    it "returns audit steps from an instance simplification" do
      result = Rule.from_ical("FREQ=YEARLY;BYMONTH=1,1").simplify

      expect(result.first.to_ical).to eq("FREQ=YEARLY;BYMONTH=1")
      expect(result.to_h[:steps].first).to include(
        action: :deduplicate,
        by_part: "BYMONTH",
        basis: :duplicate_values_within_a_by_part_are_the_same_alternative
      )
    end

    it "removes BYMONTH and BYMONTHDAY when a yearly BYYEARDAY singleton implies them" do
      rule = Rule.from_ical("FREQ=YEARLY;BYYEARDAY=59;BYMONTH=2;BYMONTHDAY=28;COUNT=10")
      result = simplify(rule)

      expect(result.first.to_ical).to eq("FREQ=YEARLY;COUNT=10;BYYEARDAY=59")
      expect(result.steps.map { |step| step[:removed] }).to eq(%w[BYMONTH BYMONTHDAY])
      expect(result.steps.map { |step| step[:action] }).to eq(%i[remove_redundant remove_redundant])
      expect(result.steps.all? { |step| step[:basis].include?("2000-2399 Gregorian cycle") }).to be(true)
    end

    it "uses the leap-year fork instead of trusting a common-year expansion" do
      rule = Rule.from_ical("FREQ=YEARLY;BYYEARDAY=59;BYMONTH=2;BYMONTHDAY=-1")
      result = simplify(rule)

      expect(result.first.to_ical).to eq("FREQ=YEARLY;BYYEARDAY=59;BYMONTHDAY=-1")
      expect(result.steps.map { |step| step[:removed] }).to eq(["BYMONTH"])

      [
        [2023, Date.new(2023, 2, 28)],
        [2024, nil],
        [2025, Date.new(2025, 2, 28)]
      ].each do |year, expected_day|
        year_schedule = Schedule.new(Time.utc(year, 1, 1))
        year_schedule.add_recurrence_rule(rule)
        expect(year_schedule.occurrences(Time.utc(year, 12, 31)).map(&:to_date).first).to eq(expected_day)
      end

      leap_branch = Rule.from_ical("FREQ=YEARLY;BYYEARDAY=60;BYMONTH=2;BYMONTHDAY=29")
      leap_schedule = Schedule.new(Time.utc(2024, 1, 1))
      leap_schedule.add_recurrence_rule(leap_branch)
      expect(leap_schedule.occurrences(Time.utc(2024, 12, 31)).map(&:to_date))
        .to eq([Date.new(2024, 2, 29)])
    end

    it "does not infer date redundancy when BYSETPOS is present" do
      rule = Rule.from_ical("FREQ=YEARLY;BYYEARDAY=59;BYMONTH=2;BYMONTHDAY=28;BYSETPOS=1")
      result = simplify(rule)

      expect(result.first.to_ical)
        .to eq("FREQ=YEARLY;BYYEARDAY=59;BYMONTH=2;BYMONTHDAY=28;BYSETPOS=1")
      expect(result.steps).to be_empty
    end

    it "preserves UNTIL while removing a provably redundant date restriction" do
      rule = Rule.from_ical("FREQ=YEARLY;BYYEARDAY=59;BYMONTH=2;BYMONTHDAY=28;UNTIL=20300101T000000Z")
      result = simplify(rule)

      expect(result.first.to_ical)
        .to eq("FREQ=YEARLY;UNTIL=20300101T000000Z;BYYEARDAY=59")
    end

    it "merges identical rule branches only with a shared DTSTART" do
      rules = [
        Rule.from_ical("FREQ=MONTHLY;BYDAY=MO,MO;COUNT=3"),
        Rule.from_ical("FREQ=MONTHLY;BYDAY=MO;COUNT=3")
      ]

      expect(simplify(rules).map { |rule| rule.to_ical })
        .to eq(["FREQ=MONTHLY;COUNT=3;BYDAY=MO", "FREQ=MONTHLY;COUNT=3;BYDAY=MO"])

      result = simplify(rules, dtstart: Time.utc(2024, 1, 1))
      expect(result.map { |rule| rule.to_ical }).to eq(["FREQ=MONTHLY;COUNT=3;BYDAY=MO"])
      merge_step = result.steps.find { |step| step[:action] == :merge_equivalent }
      expect(merge_step[:basis]).to eq(:canonical_rule_forms_are_identical_under_shared_dtstart)
    end

    it "keeps branches whose COUNT or UNTIL limits differ" do
      rules = [
        Rule.from_ical("FREQ=MONTHLY;BYDAY=MO;COUNT=3"),
        Rule.from_ical("FREQ=MONTHLY;BYDAY=MO;UNTIL=20300101T000000Z")
      ]

      result = simplify(rules, dtstart: Time.utc(2024, 1, 1))

      expect(result.size).to eq(2)
      expect(result.steps.map { |step| step[:action] }).not_to include(:merge_equivalent)
    end

    it "merges equivalent but differently written yearly branches over the full Gregorian cycle" do
      rules = [
        Rule.from_ical("FREQ=YEARLY;BYYEARDAY=59;BYMONTH=2;BYMONTHDAY=28"),
        Rule.from_ical("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=28")
      ]

      result = simplify(rules, dtstart: Time.utc(2024, 1, 1, 9, 30))

      expect(result.map(&:to_ical)).to eq(["FREQ=YEARLY;BYYEARDAY=59"])
      merge_step = result.steps.find { |step| step[:action] == :merge_equivalent }
      expect(merge_step[:basis]).to eq(:occurrence_sets_match_throughout_the_2000_2399_gregorian_cycle)
    end

    it "does not merge branches that agree in common years but fork in leap years" do
      rules = [
        Rule.from_ical("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=28"),
        Rule.from_ical("FREQ=YEARLY;BYYEARDAY=60;BYMONTH=2;BYMONTHDAY=29")
      ]

      result = simplify(rules, dtstart: Time.utc(2023, 1, 1))

      expect(result.size).to eq(2)
      expect(result.steps.map { |step| step[:action] }).not_to include(:merge_equivalent)
    end

    it "simplifies a schedule's recurrence rules with its DTSTART" do
      schedule = Schedule.new(Time.utc(2024, 1, 1))
      schedule.add_recurrence_rule(Rule.from_ical("FREQ=MONTHLY;BYDAY=MO,MO"))
      schedule.add_recurrence_rule(Rule.from_ical("FREQ=MONTHLY;BYDAY=MO"))

      result = schedule.simplify

      expect(result.map(&:to_ical)).to eq(["FREQ=MONTHLY;BYDAY=MO"])
      expect(schedule.recurrence_rules.size).to eq(2)
    end
  end
end

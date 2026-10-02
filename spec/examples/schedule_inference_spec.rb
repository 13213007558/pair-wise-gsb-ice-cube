require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
  describe ScheduleInference do
    def time(date)
      Time.utc(date.year, date.month, date.day)
    end

    def dates_in_window(schedule, window)
      schedule
        .occurrences_between(time(window.begin), time(window.end))
        .map(&:to_date)
    end

    describe "monthly last weekday" do
      let(:window) { Date.new(2024, 1, 1)..Date.new(2024, 12, 31) }

      let(:dates) do
        [
          [1, 31], [2, 29], [3, 29], [4, 30], [5, 31], [6, 28],
          [7, 31], [8, 30], [9, 30], [10, 31], [11, 29], [12, 31]
        ].map { |month, day| Date.new(2024, month, day) }
      end

      it "selects the last weekday from the final three days of the month" do
        result = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3
        )

        best = result.best
        expect(best.rule.to_ical).to eq(
          "FREQ=MONTHLY;BYMONTHDAY=-3,-2,-1;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
        )
        expect(best.cost).to eq(1)
        expect(best.rdates).to be_empty
        expect(best.exdates).to be_empty
        expect(dates_in_window(best.schedule, window)).to eq(dates)
      end

      it "round-trips through the schedule hash and reproduces the window" do
        best = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3
        ).best

        restored = Schedule.from_hash(best.schedule.to_hash)
        expect(dates_in_window(restored, window)).to eq(dates)
      end
    end

    describe "biweekly schedule with exceptions" do
      let(:window) { Date.new(2024, 1, 1)..Date.new(2024, 3, 31) }

      let(:dates) do
        [
          Date.new(2024, 1, 8),
          Date.new(2024, 1, 22),
          Date.new(2024, 2, 5),
          Date.new(2024, 3, 4),
          Date.new(2024, 3, 18)
        ]
      end

      it "keeps the rule and records the skipped occurrence as EXDATE" do
        result = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3
        )

        best = result.best
        expect(best.rule.to_ical).to eq(
          "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=MO"
        )
        expect(best.rdates).to be_empty
        expect(best.exdates).to eq([Date.new(2024, 2, 19)])
        expect(best.cost).to eq(4)
        expect(dates_in_window(best.schedule, window)).to eq(dates)
      end

      it "does not discard an equally good monthly explanation" do
        result = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3
        )

        explanations = result.first(2).map { |candidate| candidate.rule.to_ical }
        expect(explanations).to eq([
          "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=MO",
          "FREQ=MONTHLY;BYDAY=-4MO,-2MO"
        ])
        expect(result.first(2).map(&:cost)).to eq([4, 4])
      end

      it "restores the EXDATE through YAML" do
        best = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3
        ).best

        restored = Schedule.from_yaml(best.schedule.to_yaml)
        expect(restored.exception_times.map(&:to_date)).to eq([Date.new(2024, 2, 19)])
        expect(dates_in_window(restored, window)).to eq(dates)
      end
    end

    describe "short observations" do
      let(:window) { Date.new(2024, 1, 1)..Date.new(2024, 2, 29) }
      let(:dates) { [Date.new(2024, 1, 1), Date.new(2024, 1, 15)] }

      it "returns multiple exact explanations with stable order" do
        result = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3,
          max_interval: 2,
          max_candidates: 32
        )

        best_rules = result.first(3).map { |candidate| candidate.rule.to_ical }
        expect(best_rules).to eq([
          "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1,15",
          "FREQ=YEARLY;BYMONTH=1;BYDAY=-5MO,-3MO",
          "FREQ=YEARLY;BYMONTH=1;BYDAY=1MO,3MO"
        ])
        expect(result.first(3).map(&:cost)).to all(eq(1))
        expect(result.first(3).map { |candidate|
          dates_in_window(candidate.schedule, window)
        }).to all(eq(dates))

        second_run = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3,
          max_interval: 2,
          max_candidates: 32
        )
        expect(second_run.first(3).map { |candidate| candidate.rule.to_ical })
          .to eq(best_rules)
      end
    end

    describe "bounds and costs" do
      let(:window) { Date.new(2024, 1, 1)..Date.new(2024, 3, 31) }
      let(:dates) do
        [Date.new(2024, 1, 8), Date.new(2024, 1, 22), Date.new(2024, 2, 5)]
      end

      it "limits the number of evaluated candidates" do
        result = described_class.infer(
          window,
          dates,
          rule_cost: 1,
          rdate_cost: 3,
          exdate_cost: 3,
          max_candidates: 8
        )

        expect(result.size).to eq(8)
      end

      it "accepts callable rule costs" do
        result = described_class.infer(
          window,
          dates,
          rule_cost: ->(rule) { ScheduleInference.complexity(rule) * 10 },
          rdate_cost: 3,
          exdate_cost: 3
        )

        expect(result.best.rule).to be_nil
        expect(result.best.rdates).to eq(dates)
      end

      it "rejects observations outside the complete window" do
        expect {
          described_class.infer(
            window,
            dates + [Date.new(2024, 4, 1)],
            rule_cost: 1,
            rdate_cost: 3,
            exdate_cost: 3
          )
        }.to raise_error(ArgumentError, /outside the observation window/)
      end
    end
  end
end

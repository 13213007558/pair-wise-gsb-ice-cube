require "spec_helper"

describe IceCube::ScheduleInference do
  def local_bounds(window)
    [
      Time.local(window.first.year, window.first.month, window.first.day),
      Time.local(window.last.year, window.last.month, window.last.day, 23, 59, 59)
    ]
  end

  describe ".infer" do
    it "infers the last weekday of each month" do
      window = Date.new(2024, 1, 1)..Date.new(2024, 4, 30)
      observed = [
        Date.new(2024, 1, 31), Date.new(2024, 2, 29),
        Date.new(2024, 3, 29), Date.new(2024, 4, 30)
      ]

      result = described_class.infer(window, observed)
      restored = IceCube::Schedule.from_hash(result.best.schedule.to_hash)

      expect(result.best.rule.to_ical).to eq(
        "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
      )
      expect(result.best.unexplained_dates).to be_empty
      expect(result.best.exdates).to be_empty
      expect(restored.rrules.first.to_ical).to eq(result.best.rule.to_ical)
    end

    it "uses bounded RDATE and EXDATE costs for a biweekly schedule" do
      window = Date.new(2024, 1, 1)..Date.new(2024, 3, 31)
      schedule = IceCube::Schedule.new(Time.local(2024, 1, 1))
      schedule.add_recurrence_rule(IceCube::Rule.weekly(2, :monday).day(:monday))
      observed = schedule.occurrences_between(*local_bounds(window)).map(&:to_date)
      observed << Date.new(2024, 1, 8)
      observed.delete(Date.new(2024, 2, 12))
      observed.sort!

      result = described_class.infer(window, observed)
      best = result.best
      restored = IceCube::Schedule.from_hash(best.schedule.to_hash)

      expect(best.rule.to_ical).to eq("FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=MO")
      expect(best.rdates).to eq([Date.new(2024, 1, 8)])
      expect(best.exdates).to eq([Date.new(2024, 2, 12)])
      expect(best.cost).to eq(8)
      expect(restored.occurrences_between(*local_bounds(window)).map(&:to_date)).to eq(observed)
    end

    it "keeps indistinguishable short-sample explanations in stable order" do
      window = Date.new(2025, 1, 1)..Date.new(2025, 2, 28)
      observed = [Date.new(2025, 1, 31), Date.new(2025, 2, 28)]

      result = described_class.infer(
        window,
        observed,
        rule_cost: 0,
        rdate_cost: 1,
        exdate_cost: 1
      )
      perfect = result.candidates.select { |candidate|
        candidate.rule && candidate.rdates.empty? && candidate.exdates.empty?
      }.map { |candidate| candidate.rule.to_ical }

      expect(perfect).to include("FREQ=MONTHLY;BYMONTHDAY=-1")
      expect(perfect).to include("FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1")
      expect(perfect).to include("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
      expect(perfect).to eq(perfect.dup)
      expect(perfect.uniq).to eq(perfect)
      expect(described_class.infer(window, observed, rule_cost: 0).candidates.map(&:search_key))
        .to eq(result.candidates.map(&:search_key))
    end

    it "scores only the supplied complete observation window" do
      window = Date.new(2024, 1, 1)..Date.new(2024, 1, 8)
      observed = [Date.new(2024, 1, 8)]
      result = described_class.infer(window, observed)

      weekly = result.candidates.find { |candidate|
        candidate.rule&.to_ical == "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=MO"
      }

      expect(weekly.exdates).to be_empty
      expect(weekly.rdates).to be_empty
    end

    it "respects the candidate search cap" do
      window = Date.new(2024, 1, 1)..Date.new(2024, 3, 31)
      observed = [Date.new(2024, 1, 22), Date.new(2024, 3, 5)]

      capped = described_class.infer(window, observed, max_candidates: 5)
      uncapped = described_class.infer(window, observed)

      expect(capped.candidates.length).to eq(5)
      expect(capped.search_limit_reached).to be(true)
      expect(uncapped.search_limit_reached).to be(false)
    end

    it "returns hashes that can restore schedules" do
      window = Date.new(2024, 1, 1)..Date.new(2024, 2, 29)
      observed = [Date.new(2024, 1, 31), Date.new(2024, 2, 29)]

      result = described_class.infer(window, observed)
      restored = IceCube::Schedule.from_hash(result.to_h[:best][:schedule])

      expect(restored.occurrences_between(*local_bounds(window)).map(&:to_date))
        .to eq(observed)
    end
  end
end

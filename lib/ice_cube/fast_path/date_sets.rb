module IceCube
  class FastPath
    # A recurrence rule reduced to a set of dates plus the last second at
    # which it may still fire (from its own COUNT/UNTIL limits).
    class RuleSet
      attr_reader :date_set, :end_i

      def initialize(date_set, end_i, tod)
        @date_set = date_set
        @end_i = end_i
        @tod = tod
      end

      # Last date (Julian day number) on which this rule can produce an
      # occurrence at or before +second+, given the schedule-wide
      # +date_hi+ for that second.
      def date_hi(second, date_hi)
        return date_hi if @end_i.nil?
        e = @end_i < second ? @end_i : second
        jd = (e / ONE_DAY) + EPOCH_JD
        jd -= 1 if e % ONE_DAY < @tod
        jd
      end

      def occurs_on?(jd, second)
        (@end_i.nil? || second <= @end_i) && @date_set.occurs_on?(jd)
      end
    end

    # Month-level constraints shared by monthly and yearly style sets:
    # month index congruence, a month-of-year set, a year congruence and
    # a day-of-month specification.
    MonthConstraint = Struct.new(:m_mod, :m_res, :months, :y_mod, :y_res, :dayspec, keyword_init: true)

    # Day-of-month specification locked to the schedule start day,
    # clamped to the last day of shorter months (IceCube's schedule_lock
    # semantics).
    class LockedDaySpec
      def initialize(day)
        @day = day
      end

      def days_for_dim(dim)
        [[@day, dim].min]
      end
    end

    # Explicit day_of_month values. Positive days are literal, so months
    # too short to contain them are skipped; negative days count back
    # from the month end and clamp to the first day.
    class ExplicitDaySpec
      def initialize(days)
        @days = days
      end

      def days_for_dim(dim)
        @days.map { |day|
          if day > 0
            (day <= dim) ? day : nil
          else
            clamped = 1 + dim + day
            (clamped < 1) ? 1 : clamped
          end
        }.compact.uniq.sort
      end
    end

    # Intersection of several day specifications.
    class IntersectDaySpec
      def initialize(specs)
        @specs = specs
      end

      def days_for_dim(dim)
        @specs.map { |spec| spec.days_for_dim(dim) }.reduce(:&)
      end
    end

    # A set of dates described by residue classes modulo a fixed number
    # of days. Covers daily rules, weekly rules (one residue per selected
    # weekday), and intersections of the two.
    class APSet
      attr_reader :residues, :modulus

      def initialize(residues, modulus)
        @residues = residues
        @modulus = modulus
      end

      def count_dates(lo_jd, hi_jd)
        m = @modulus
        @residues.sum { |r| (hi_jd - r) / m - (lo_jd - 1 - r) / m }
      end

      def occurs_on?(jd)
        @residues.include?(jd % @modulus)
      end

      def empty?
        @residues.empty?
      end

      # Julian day number of the +index+-th (0-based) date in the set
      # that is >= from_jd.
      def nth_date(index, from_jd)
        q, rem = index.divmod(@residues.size)
        base = from_jd + q * @modulus
        candidates = @residues.map { |r|
          r + @modulus * ceil_div(base - r, @modulus)
        }
        candidates.sort[rem]
      end

      def ap_constraint
        [@residues, @modulus]
      end

      def month_constraint
        nil
      end

      private

      def ceil_div(a, b)
        -((-a) / b)
      end
    end

    # A set of dates described by a month-level constraint and a
    # day-of-month specification. Counting is O(1) via a cumulative table
    # over one full period (a whole number of 400-year Gregorian cycles).
    class MonthSet
      def initialize(constraint)
        @constraint = constraint
        build_table
      end

      def count_dates(lo_jd, hi_jd)
        return 0 if hi_jd < lo_jd
        d1 = Date.jd(lo_jd)
        d2 = Date.jd(hi_jd)
        m1 = d1.year * 12 + d1.month - 1
        m2 = d2.year * 12 + d2.month - 1
        if m1 == m2
          return days_in_range(m1, d1.day, d2.day)
        end
        days_in_range(m1, d1.day, FastPath.dim_of_month(m1)) +
          count_months(m1 + 1, m2 - 1) +
          days_in_range(m2, 1, d2.day)
      end

      def occurs_on?(jd)
        date = Date.jd(jd)
        mi = date.year * 12 + date.month - 1
        month_days(mi).include?(date.day)
      end

      # Julian day number of the +index+-th (0-based) date in the set
      # that is >= from_jd, or nil if the set is empty.
      def nth_date(index, from_jd)
        return nil if @period_total.zero?
        date = Date.jd(from_jd)
        mi = date.year * 12 + date.month - 1
        remaining = month_days(mi).select { |d| d >= date.day }
        if index < remaining.size
          return FastPath.jd_of_month(mi) + remaining[index] - 1
        end
        index -= remaining.size
        base = count_to(mi)
        target = base + index + 1
        hi = mi + (index / @period_total + 2) * @period
        lo = mi + 1
        while lo < hi
          mid = (lo + hi) / 2
          if count_to(mid) >= target
            hi = mid
          else
            lo = mid + 1
          end
        end
        day_index = index - (count_to(lo - 1) - base)
        FastPath.jd_of_month(lo) + month_days(lo)[day_index] - 1
      end

      def ap_constraint
        nil
      end

      def month_constraint
        @constraint
      end

      def empty?
        @period_total.zero?
      end

      protected

      def period
        @constraint.m_mod.lcm(12 * @constraint.y_mod).lcm(GREGORIAN_CYCLE_MONTHS)
      end

      def month_matches?(mi)
        c = @constraint
        return false unless mi % c.m_mod == c.m_res
        return false if c.months && !c.months.include?(mi % 12)
        (mi / 12) % c.y_mod == c.y_res
      end

      def month_days(mi)
        return [] unless month_matches?(mi)
        @constraint.dayspec.days_for_dim(FastPath.dim_of_month(mi))
      end

      def days_in_range(mi, lo_day, hi_day)
        month_days(mi).count { |d| d >= lo_day && d <= hi_day }
      end

      private

      def build_table
        @period = period
        if @period > MAX_TABLE_MONTHS
          raise UnsupportedScheduleError, "rule combination requires a " +                                          "period table of #{@period} months (limit #{MAX_TABLE_MONTHS})"
        end
        @cum = Array.new(@period)
        total = 0
        @period.times do |mi|
          total += month_days(mi).size
          @cum[mi] = total
        end
        @period_total = total
      end

      def count_months(m1, m2)
        return 0 if m2 < m1
        count_to(m2) - count_to(m1 - 1)
      end

      # Occurrences in months 0..mi inclusive.
      def count_to(mi)
        return 0 if mi < 0
        cycles, rem = mi.divmod(@period)
        cycles * @period_total + @cum[rem]
      end
    end

    # Intersection of an AP-style set with a month-based set. The
    # combined pattern repeats after the month count that realigns both
    # the Gregorian cycle and the day modulus.
    class MixedSet < MonthSet
      def initialize(constraint, residues, ap_modulus)
        @ap_residues = residues
        @ap_modulus = ap_modulus
        super(constraint)
      end

      def ap_constraint
        [@ap_residues, @ap_modulus]
      end

      protected

      def period
        ap_cycle = GREGORIAN_CYCLE_MONTHS * @ap_modulus /
          GREGORIAN_CYCLE_DAYS.gcd(@ap_modulus)
        @constraint.m_mod.lcm(12 * @constraint.y_mod).lcm(ap_cycle)
      end

      def month_days(mi)
        return [] unless month_matches?(mi)
        jd0 = FastPath.jd_of_month(mi)
        @constraint.dayspec.days_for_dim(FastPath.dim_of_month(mi)).select { |d|
          @ap_residues.include?((jd0 + d - 1) % @ap_modulus)
        }
      end
    end

    # The empty date set (produced by inconsistent intersections).
    module EmptySet
      def self.count_dates(_lo_jd, _hi_jd)
        0
      end

      def self.occurs_on?(_jd)
        false
      end

      def self.empty?
        true
      end

      def self.nth_date(_index, _from_jd)
        nil
      end

      def self.ap_constraint
        nil
      end

      def self.month_constraint
        nil
      end
    end

    # Intersection of date sets, used by inclusion-exclusion when
    # deduplicating overlapping rules.
    module DateSet
      def self.intersect(a, b)
        aps = [a.ap_constraint, b.ap_constraint].compact
        months = [a.month_constraint, b.month_constraint].compact
        ap = merge_aps(aps)
        month = merge_months(months)
        return EmptySet if ap == :empty || month == :empty
        build(ap, month)
      end

      def self.build(ap, month)
        if month.nil?
          # Both sides covered every date: the intersection is all dates.
          ap ||= [[0], 1]
          APSet.new(ap[0], ap[1])
        elsif ap.nil?
          MonthSet.new(month)
        else
          MixedSet.new(month, ap[0], ap[1])
        end
      end

      def self.merge_aps(list)
        return nil if list.empty?
        residues, modulus = list.first
        residues = residues.dup
        list.drop(1).each do |other_residues, other_modulus|
          new_modulus = modulus.lcm(other_modulus)
          if residues.size * (new_modulus / modulus) > MAX_RESIDUES
            raise UnsupportedScheduleError, "rule combination expands to " +                                            "too many residue classes for the fast path"
          end
          expanded = residues.flat_map { |r|
            (0...(new_modulus / modulus)).map { |k| r + k * modulus }
          }
          other_expanded = other_residues.flat_map { |r|
            (0...(new_modulus / other_modulus)).map { |k| r + k * other_modulus }
          }
          residues = expanded & other_expanded
          return :empty if residues.empty?
          modulus = new_modulus
        end
        residues.sort!
        # A residue set covering every date is no constraint at all.
        (residues.size == modulus) ? nil : [residues, modulus]
      end

      def self.merge_months(list)
        return nil if list.empty?
        m_mod, m_res = list.first.m_mod, list.first.m_res
        months = list.first.months
        y_mod, y_res = list.first.y_mod, list.first.y_res
        specs = [list.first.dayspec]
        list.drop(1).each do |c|
          combined = crt(m_res, m_mod, c.m_res, c.m_mod)
          return :empty unless combined
          m_res, m_mod = combined, m_mod.lcm(c.m_mod)
          months = months.nil? ? c.months : (c.months.nil? ? months : months & c.months)
          return :empty if months == []
          combined = crt(y_res, y_mod, c.y_res, c.y_mod)
          return :empty unless combined
          y_res, y_mod = combined, y_mod.lcm(c.y_mod)
          specs << c.dayspec
        end
        m_res %= m_mod
        y_res %= y_mod
        dayspec = (specs.size == 1) ? specs.first : IntersectDaySpec.new(specs)
        MonthConstraint.new(
          m_mod: m_mod, m_res: m_res, months: months,
          y_mod: y_mod, y_res: y_res, dayspec: dayspec
        )
      end

      # Solve x = r1 (mod m1), x = r2 (mod m2); nil when inconsistent.
      def self.crt(r1, m1, r2, m2)
        g = m1.gcd(m2)
        return nil if (r2 - r1) % g != 0
        return r1 if m2 / g == 1
        k = ((r2 - r1) / g) * (m1 / g).pow(-1, m2 / g)
        r1 + m1 * (k % (m2 / g))
      end
    end
  end
end

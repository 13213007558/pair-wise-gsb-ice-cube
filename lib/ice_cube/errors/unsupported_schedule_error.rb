module IceCube
  # Raised when Schedule#occurrence_at or Schedule#count_between is asked
  # to use the fast path on a schedule whose rules, validations or times
  # fall outside the supported subset (see IceCube::FastPath).
  class UnsupportedScheduleError < StandardError
  end
end

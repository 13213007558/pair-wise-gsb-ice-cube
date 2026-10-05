module IceCube
  # Raised when a serialized rule references a calendar version that has not
  # been registered in the running process. The caller must register the
  # calendar (with the same +version+ identifier) before deserializing.
  class CalendarVersionNotFound < StandardError
  end
end

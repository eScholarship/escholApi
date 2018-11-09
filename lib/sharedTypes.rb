
###################################################################################################
DateType = GraphQL::ScalarType.define do
  name "Date"
  description %{A date in ISO-8601 format. Example: "2018-03-09"}

  coerce_input ->(value, ctx) do
    begin
      Date.iso8601(value)
    rescue ArgumentError
      raise GraphQL::CoercionError, "cannot coerce `#{value.inspect}` to Date; must be ISO-8601 format"
    end
  end

  coerce_result ->(value, ctx) { (value.instance_of?(Date) ? value : Date.iso8601(value)).iso8601 }
end

###################################################################################################
DateTimeType = GraphQL::ScalarType.define do
  name "DateTime"
  description %{A date and time in ISO-8601 format, including timezone.
                Example: "2018-03-09T15:02:42-08:00"
                If you don't specify the time, midnight (server-local) will be used.}.unindent

  coerce_input ->(value, ctx) do
    begin
      # Normalize timezone to localtime
      Time.iso8601(value).localtime.to_datetime
    rescue ArgumentError
      begin
        # Synthesize timezone
        (Date.iso8601(value).to_time - Time.now.utc_offset).to_datetime
      rescue ArgumentError
        raise GraphQL::CoercionError, "cannot coerce `#{value.inspect}` to DateTime; must be ISO-8601 format"
      end
    end
  end

  coerce_result ->(value, ctx) { value.iso8601 }
end

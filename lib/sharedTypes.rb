
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

###################################################################################################
RoleEnum = GraphQL::EnumType.define do
  name "Role"
  description "Publication type of an Item (often ARTICLE)"
  value("ADVISOR", "Advised on the work (e.g. on a thesis)")
  value("EDITOR", "Edited the work")
end

###################################################################################################
ItemIDSchemeEnum = GraphQL::EnumType.define do
  name "ItemIDScheme"
  description "Ordering for item list results"
  value("ARK", "eSchol (ark:/13030/qt...) or Merritt ARK")
  value("DOI", "A Digital Object Identifier, with or w/o http://dx.doi.org prefix")
  value("LBNL_PUB_ID", "LBNL-internal publication ID")
  value("OA_PUB_ID", "Pub ID on oapolicy.universityofcalifornia.edu")
  value("OTHER_ID", "All other identifiers")
end

###################################################################################################
FileVersionEnum = GraphQL::EnumType.define do
  name "FileVersion"
  description "Version of a content file, e.g. AUTHOR_VERSION"
  value("AUTHOR_VERSION", "Author's final version")
  value("PUBLISHER_VERSION", "Publisher's final version")
end

###################################################################################################
PubRelationEnum = GraphQL::EnumType.define do
  name "PubRelation"
  description "Relationship of this publication to eScholarship"
  value("INTERNAL_PUB", "Originally published on eScholarship")
  value("EXTERNAL_PUB", "Published externally to eScholarship before deposit")
  value("EXTERNAL_ACCEPT", "Accepted and will be published externally to eScholarship post-deposit")
end

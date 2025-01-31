
###################################################################################################
#module Types
class DateType < GraphQL::Schema::Scalar
  graphql_name "Date"
  description %{A date in ISO-8601 format. Example: "2018-03-09"}

  def self.coerce_input(value, ctx)
    begin
      Date.iso8601(value)
    rescue ArgumentError
      raise GraphQL::CoercionError, "cannot coerce `#{value.inspect}` to Date; must be ISO-8601 format"
    end
  end

  def self.coerce_result(value, ctx)
    (value.instance_of?(Date) ? value : Date.iso8601(value)).iso8601 
  end
end

###################################################################################################
class DateTimeType < GraphQL::Schema::Scalar
  graphql_name "DateTime"
  description %{A date and time in ISO-8601 format, including timezone.
                Example: "2018-03-09T15:02:42-08:00"
                If you don't specify the time, midnight (server-local) will be used.}.unindent

  def coerce_input(value, ctx)
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

  def coerce_result(value, ctx) 
    value.iso8601 
  end
end

###################################################################################################
class RoleEnum < GraphQL::Schema::Enum
  graphql_name "Role"
  description "Publication type of an Item (often ARTICLE)"
  value("ADVISOR", "Advised on the work (e.g. on a thesis)")
  value("EDITOR", "Edited the work")
end

###################################################################################################
class ItemIDSchemeEnum < GraphQL::Schema::Enum
  graphql_name "ItemIDScheme"
  description "The scheme under which the identifier was minted"
  value("ARK", "eSchol (ark:/13030/qt...) or Merritt ARK")
  value("DOI", "A Digital Object Identifier, with or w/o http://dx.doi.org prefix")
  value("LBNL_PUB_ID", "LBNL-internal publication ID")
  value("OA_PUB_ID", "Pub ID on oapolicy.universityofcalifornia.edu")
  value("OTHER_ID", "All other identifiers")
end

###################################################################################################
class AuthorIDSchemeEnum < GraphQL::Schema::Enum
  graphql_name "AuthorIDScheme"
  description "The scheme under which the identifier was minted"
  value("ARK", "eSchol (ark:/13030/qt...) ARK")
  value("ORCID", "An Open Researcher and Contributor ID")
  value("OTHER_ID", "All other identifiers")
end

###################################################################################################
class FileVersionEnum < GraphQL::Schema::Enum
  graphql_name "FileVersion"
  description "Version of a content file, e.g. AUTHOR_VERSION"
  value("AUTHOR_VERSION", "Author's final version")
  value("PUBLISHER_VERSION", "Publisher's final version")
end

###################################################################################################
class PubRelationEnum < GraphQL::Schema::Enum
  graphql_name "PubRelation"
  description "Relationship of this publication to eScholarship"
  value("INTERNAL_PUB", "Originally published on eScholarship")
  value("EXTERNAL_PUB", "Published externally to eScholarship before deposit")
  value("EXTERNAL_ACCEPT", "Accepted and will be published externally to eScholarship post-deposit")
end
#end

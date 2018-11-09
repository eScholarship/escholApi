require 'base64'
require 'json'
require 'unindent'

###################################################################################################
SubmitQueryType = GraphQL::ObjectType.define do
  name "SubmitQuery"
  description "The eScholarship API"

  field :foo, !types.String, "A foo thing" do
    resolve -> (obj, args, ctx) {
      "This is foo"
    }
  end
end

###################################################################################################
SubmitMutationType = GraphQL::ObjectType.define do
  name "SubmitMutation"
  description "The eScholarship API"

  field :bar, !types.String, "A bar thing" do
    resolve -> (obj, args, ctx) {
      "This is bar"
    }
  end
end

###################################################################################################
SubmitSchema = GraphQL::Schema.define do
  query SubmitQueryType
  mutation SubmitMutationType
end

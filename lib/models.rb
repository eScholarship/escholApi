class Issue < Sequel::Model
end
class Item < Sequel::Model
  unrestrict_primary_key
end
class ItemAuthor < Sequel::Model
  unrestrict_primary_key
end
class ItemContrib < Sequel::Model
  unrestrict_primary_key
end
class Person < Sequel::Model(:people)
  unrestrict_primary_key
end
class Redirect < Sequel::Model
end
class Section < Sequel::Model
end
class Unit < Sequel::Model
  unrestrict_primary_key
end
class UnitHier < Sequel::Model(:unit_hier)
  unrestrict_primary_key
end
class UnitItem < Sequel::Model
  unrestrict_primary_key
end

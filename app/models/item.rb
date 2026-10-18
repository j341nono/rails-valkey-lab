# Vector Search 用のデータ（埋め込みベクトルだけを持つ）
class Item < ApplicationRecord
  has_neighbors :embedding
end

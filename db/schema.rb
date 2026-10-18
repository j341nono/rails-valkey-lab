# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_18_025348) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "items", force: :cascade do |t|
    t.vector "embedding", limit: 128, null: false
    t.index ["embedding"], name: "index_items_on_embedding", opclass: :vector_l2_ops, using: :hnsw
  end

  create_table "page_views", force: :cascade do |t|
    t.bigint "article_id", null: false
    t.datetime "viewed_at", null: false
    t.index ["viewed_at", "article_id"], name: "index_page_views_on_viewed_at_and_article_id"
  end
end

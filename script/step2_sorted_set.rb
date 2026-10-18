# Step 2: Sorted Set の基本操作（講演資料 p.15, p.17）
# 実行: bin/rails runner script/step2_sorted_set.rb

VALKEY.del("ranking") # 何度実行しても同じ結果になるように、前回のデータを消す

# p.15 ZADD: スコア付きでメンバーを追加
VALKEY.zadd("ranking", 100, "user1")
VALKEY.zadd("ranking", 250, "user2")
VALKEY.zadd("ranking", 180, "user3")

# p.15 ZRANGE ... REV: スコアの高い順に全件取得
p VALKEY.zrange("ranking", 0, -1, rev: true)

# p.15 ZREVRANK: 高い順で何番目か（0始まり）
p VALKEY.zrevrank("ranking", "user1")

# p.17 ZINCRBY: スコアを加算（メンバーがなければ 0 から加算）
VALKEY.zincrby("ranking", 150, "user4")
p VALKEY.zrange("ranking", 0, -1, rev: true, with_scores: true)

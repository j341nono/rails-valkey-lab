# rails-valkey-lab

Kaigi on Rails 2026「そのValkey、使いこなしていますか？」の内容を Rails で検証するリポジトリ。

## セットアップ

```sh
bundle install
docker compose up -d   # Valkey (localhost:6380) と PostgreSQL (localhost:5433)
bin/rails db:prepare   # DB作成 + マイグレーション
```

## 実行

```sh
bin/rails runner script/step2_sorted_set.rb          # Sorted Set の基本操作
bin/rails runner script/step3_ranking.rb             # 直近7日間ランキング（Ruby Hash / Valkey）
bin/rails runner script/step4_benchmark.rb           # 集計時間・メモリ → results/step4_ranking.csv
bin/rails runner script/step5_weighted_ranking.rb    # WEIGHTS → results/step5_weighted_ranking.csv
bin/rails runner script/step7_ranking_pg_valkey.rb   # 直近7日間ランキング（PostgreSQL / Valkey）
bin/rails runner script/step8_benchmark_pg_valkey.rb # 投入・集計時間・メモリ → results/step8_*.csv（EVENTS=300000,3000000 で件数指定）
```

## 停止

```sh
docker compose down
```

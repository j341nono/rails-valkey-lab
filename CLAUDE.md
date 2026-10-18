# rails-valkey-lab

## 目的

Kaigi on Rails 2026の講演「そのValkey、使いこなしていますか？」で紹介されたValkeyの活用方法について、一般的なRails実装と比較し、実行時間・メモリ使用量の違いを検証する。

参照資料:
- `references/valkey.pdf`
- `references/valkey_slide_code.md`

技術共有会で実装内容と性能測定結果を発表することが最終目標。

## 実験1：直近7日間ランキング

**一般的なRails実装**
- Active Record + PostgreSQLを使用する。
- 記事の閲覧イベントを1件ずつレコードとして保存する。
- 直近7日間の閲覧履歴をSQLの `WHERE`、`GROUP BY`、`COUNT`、`ORDER BY` などで集計し、Top 10を取得する。
- 日別の事前集計テーブルは作成しない。

**Valkey実装**
- 日付ごとのSorted Setに記事の閲覧数を記録する。
- `ZINCRBY` で閲覧数を加算する。
- `ZUNIONSTORE` で直近7日間の閲覧数を合算する。
- `ZRANGE` でTop 10を取得する。
- `WEIGHTS` による時間減衰ランキングも追加実験として扱う。

両方式で同じ閲覧イベントを使用し、結果が一致することを確認する。

## 実験2：Vector Search

- 一般的な実装：PostgreSQL + pgvector（HNSW）
- Valkey実装：Valkey Search（HNSW）
- 同一のベクトルを使用して、検索時間・メモリ使用量・Recall@10を比較する。

## 測定方針

- 両方式で同じデータを使い、結果の一致（実験2ではRecall@10）を確認してから測定する。
- データ投入時間とランキング集計・検索時間を分けて測定する。
- ウォームアップ後に複数回測定し、中央値・最小・最大を記録する。
- メモリ使用量は、Rails・PostgreSQL・Valkeyを区別して記録する。
- データ件数を段階的に増やして比較する。
- 測定結果をCSVとして保存する。
- PostgreSQLは生の閲覧履歴、Valkeyは日別の事前集計データを保持するため、これはDB単体の純粋な性能比較ではなく、**実装方式全体の比較**であることを明記する。
- 一方の方式が必ず高速になると決めつけず、実測結果に基づいて考察する。
- 実測値と推測を区別し、都合の悪い結果も記録する。

## 実装方針

- Ruby on Railsを使用し、Pythonは使わない。
- 技術検証が目的であり、完成度の高いプロダクトは不要。
- 講演資料のように、短く理解しやすいコードを優先する。
- Web UI、認証、CRUD機能、過度な抽象化、不要な依存ライブラリは作らない・入れない。
- `rails runner` またはRakeタスクで実験できればよい。
- ただし、測定結果の正確性と再現性は確保する。

## 開発環境

開発時:
- Apple Silicon Mac。RailsはMac上で実行する
- PostgreSQLとValkeyはDocker Composeで起動する

最終測定時:
- UTM上のUbuntu ARM64 VM
- Docker ComposeでRails・PostgreSQL・Valkeyを別コンテナとして実行する（k8s/k3sは使わない。k3sは最後の追加実験のみ）
- GitHubからcloneして環境を再現する

最終的な性能比較はUbuntu VM内で条件を揃えて行う。

## 開発順序

Step 1〜5は旧方針（Ruby Hash vs Valkey）で完了済み。スクリプト（`script/step2〜5_*.rb`）は参考として残す。

Step 1: Railsの最小環境を構築する（完了）  
Step 2: ValkeyのSorted Setを動かす（完了）  
Step 3: Ruby Hash版とValkey版で直近7日間ランキングを実装する（完了・旧方針）  
Step 4: ランキングの実行時間・メモリ使用量を比較する（完了・旧方針）  
Step 5: WEIGHTSによる重み付きランキングを試す（完了・旧方針）  
Step 6: Active Record + PostgreSQLを導入する  
Step 7: 閲覧イベントをPostgreSQLとValkeyに記録し、直近7日間Top 10が一致することを確認する  
Step 8: ランキングの投入時間・集計時間・メモリ使用量を比較する（WEIGHTSは追加実験）  
Step 9: pgvectorとValkey SearchでVector Searchを実装・比較する  
Step 10: GitHub経由でUbuntu VMに移し、Docker Composeで最終測定する（Railsもコンテナ化。CPU・メモリ上限、ネットワーク遅延を数段階で測定）  
Step 11: 結果を整理して共有会で発表する  
追加実験（Step 11の後）: 同じ測定をk3sでも行い、Composeとの差を見る  

## 最重要ルール

**必ず1ステップずつ進めること。**

- 一度に全機能を実装しない。
- 私が指定したStepだけを実装する。
- 次のStepには私の許可なく進まない。
- 各Stepの完了時に、実装内容と主要コード・Railsの仕組みを簡潔に説明する。
- 先のStepのために複雑な設計を先回りして作らない。
- Rails初心者でも理解できる実装を優先する。

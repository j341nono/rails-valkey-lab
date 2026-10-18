# 測定用の Rails コンテナ（Web サーバーは起動せず、rails runner で実験スクリプトを実行する）
FROM ruby:3.3.9-slim

# build-essential / libyaml-dev: ネイティブ拡張の gem 用、iproute2: tc でネットワーク遅延を入れる用
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libyaml-dev iproute2 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .

ENTRYPOINT ["bin/docker-entrypoint"]
CMD ["bin/rails", "runner", "puts 'ok'"]

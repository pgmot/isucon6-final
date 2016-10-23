FROM ruby:2.3.1

RUN gem update -N --system && gem install -N bundler

RUN mkdir -p /app
WORKDIR /app

COPY Gemfile Gemfile.lock /app/
RUN bundle install --jobs 4

COPY . /app

CMD RACK_ENV=production bundle exec unicorn -l "0.0.0.0:80" -c config/unicorn.rb config.ru

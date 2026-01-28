###############################################
# Global build arguments
###############################################
ARG RUBY_VERSION=3.3

###############################################
# Stage 1 — Builder
###############################################
FROM ruby:${RUBY_VERSION} AS builder

# Re-declare ARG inside the stage (Docker requirement)
ARG RUBY_VERSION

RUN apt-get update -qq && apt-get install -y \
  build-essential \
  libmariadb-dev \
  curl

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs

WORKDIR /app

# Install Ruby gems into /vendor/bundle
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local path /vendor/bundle
RUN bundle install --jobs 4 --retry 3

# Install Node dependencies
COPY package.json package-lock.json ./
RUN npm install

# Copy only the directories you want
COPY lib/ ./lib/
COPY public/ ./public/
COPY tools/ ./tools/
COPY views/ ./views/
COPY bin/ ./bin/
COPY config.ru start.sh ./

###############################################
# Stage 2 — Runtime
###############################################
FROM ruby:${RUBY_VERSION}

# Re-declare ARG inside this stage too
ARG RUBY_VERSION

RUN apt-get update -qq && apt-get install -y \
  libmariadb-dev \
  curl && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /vendor/bundle
COPY --from=builder /vendor/bundle /vendor/bundle

WORKDIR /app

# Copy everything from builder stage
COPY --from=builder app/ .

# Ensure Bundler uses the vendor path
ENV BUNDLE_PATH=/vendor/bundle
ENV BUNDLE_APP_CONFIG=/vendor/bundle 
ENV BUNDLE_BIN=/vendor/bundle/bin 
ENV PATH="${BUNDLE_BIN}:${PATH}"

EXPOSE 80

CMD ["./start.sh"]


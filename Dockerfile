# Use official Ruby image
FROM ruby:3.1

# Install dependencies
RUN apt-get update -qq && apt-get install -y \
  build-essential \
  libmariadb-dev \
  curl

# Install Node.js 20 and npm via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs

# Set working directory
WORKDIR /app

# Copy Gemfiles and install gems
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy Node.js dependencies and install
COPY package.json package-lock.json ./
RUN npm install

# Copy the rest of the app
COPY . .

# Expose the default port
EXPOSE 80

# Run the app
CMD ["./start.sh"]

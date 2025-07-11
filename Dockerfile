# --- Stage 1: Builder Stage ---
# This stage is responsible for installing Composer dependencies, compiling assets (if any),
# and any other build-time operations. It's discarded in the final image.
FROM dunglas/frankenphp:1.8.0-builder-php8.2-bookworm AS builder

WORKDIR /app

# Install system dependencies needed for Composer and application build
# We clean up apt lists immediately to reduce intermediate layer size
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    unzip \
    librabbitmq-dev \
    libpq-dev \
    # Add any other build-time dependencies here (e.g., nodejs/npm if you compile assets)
    && rm -rf /var/lib/apt/lists/*

# Copy composer binary from its official image
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Copy only composer.json and composer.lock first to leverage Docker cache
# If these files don't change, 'composer install' will be cached
COPY composer.json composer.lock ./

# Install Composer dependencies, skipping development dependencies
# --no-dev: Excludes dev dependencies (crucial for production)
# --optimize-autoloader: Optimizes Composer's autoloader for faster execution
# --no-interaction: Prevents Composer from asking questions
RUN composer install --no-dev --optimize-autoloader --no-interaction

# Copy the rest of the application code
# This is done after composer install to maximize caching benefit
COPY . .

# (Optional) If you have frontend assets to compile with Node.js/NPM/Yarn
# You would typically install Node.js in this builder stage and then run your build commands:
# RUN apt-get update && apt-get install -y nodejs npm
# COPY package.json package-lock.json ./
# RUN npm ci --no-audit --prefer-offline # Use 'npm ci' for reproducible builds
# RUN npm run production # Or 'npm run build' depending on your package.json scripts

# Prepare Laravel for production
# Run any artisan commands that need to be run at build time (e.g., cache config)
RUN php artisan optimize:clear \
    && php artisan config:cache \
    && php artisan route:cache \
    && php artisan view:cache

# --- Stage 2: Production Runtime Stage ---
# This stage is minimal and only contains the necessary files and runtime dependencies.
# It doesn't contain any build tools or development dependencies.
FROM dunglas/frankenphp:1.8.0-php8.2-bookworm

# Set Caddy server name to "http://" to serve on 80 and not 443
ENV SERVER_NAME="http://"

# Install only essential runtime system dependencies
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    supervisor \
    libpq-dev \
    librabbitmq-dev \
    # Add any other production runtime dependencies (e.g., specific image manipulation libs)
    && rm -rf /var/lib/apt/lists/*

# Install core PHP extensions needed at runtime
RUN install-php-extensions \
    gd \
    pcntl \
    opcache \
    pdo \
    pdo_mysql \
    redis

# Copy only the necessary files from the builder stage
# /app/vendor for Composer dependencies
# /app/public for compiled assets and Laravel's entry point
# /app/bootstrap/cache for Laravel's cached files
# /app/storage for Laravel's storage (logs, sessions, etc. - ensure permissions are set)
# The rest of the Laravel app code
COPY --from=builder /app/vendor /var/www/html/vendor
COPY --from=builder /app/public /var/www/html/public
COPY --from=builder /app/bootstrap/cache /var/www/html/bootstrap/cache
COPY --from=builder /app/storage /var/www/html/storage
COPY --from=builder /app/.env.example /var/www/html/.env.example # Copy .env.example, .env will be mounted
COPY --from=builder /app/.env /var/www/html/.env # If you want to bake a default .env, otherwise use mount

# Copy the remaining essential application files
# Exclude files that are not needed in production (e.g., tests, dev config)
# This assumes your .dockerignore handles most of the exclusions
COPY --from=builder /app/.editorconfig /var/www/html/
COPY --from=builder /app/.gitattributes /var/www/html/
COPY --from=builder /app/.gitignore /var/www/html/
COPY --from=builder /app/artisan /var/www/html/
COPY --from=builder /app/app /var/www/html/app
COPY --from=builder /app/config /var/www/html/config
COPY --from=builder /app/database /var/www/html/database
COPY --from=builder /app/resources /var/www/html/resources
# Copy web routes file specifically if you excluded the whole app folder
COPY --from=builder /app/routes /var/www/html/routes
COPY --from=builder /app/composer.json /var/www/html/composer.json
COPY --from=builder /app/composer.lock /var/www/html/composer.lock
# If you have compiled assets in public, copy them over
# COPY --from=builder /app/mix-manifest.json /var/www/html/mix-manifest.json # if using Laravel Mix
# COPY --from=builder /app/webpack.mix.js /var/www/html/webpack.mix.js # if using Laravel Mix

# Copy PHP config and Supervisor config
COPY ./php.ini /usr/local/etc/php/
COPY ./supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Set working directory in the final image
WORKDIR /var/www/html

# Set permissions for Laravel's storage and cache directories
# www-data is the user FrankenPHP runs as
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 80 443

# Start Supervisor
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

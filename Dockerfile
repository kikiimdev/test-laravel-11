# --- Stage 1: Builder Stage ---
FROM dunglas/frankenphp:1.8.0-builder-php8.2-bookworm AS builder

WORKDIR /app

# Install system dependencies needed for Composer and application build
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    unzip \
    librabbitmq-dev \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy composer binary from its official image
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Copy only composer.json and composer.lock first to leverage Docker cache
COPY composer.json composer.lock ./

# Install Composer dependencies, skipping development dependencies
RUN composer install --no-dev --optimize-autoloader --no-interaction

# --- IMPORTANT CHANGE START ---
# Copy the rest of the application code *after* composer install but *before*
# any `php artisan` commands. This ensures 'artisan' and other files are present.
COPY . .
# --- IMPORTANT CHANGE END ---

# Prepare Laravel for production
# Now, 'artisan' and other application files are available in /app
RUN php artisan optimize:clear \
    && php artisan config:cache \
    && php artisan route:cache \
    && php artisan view:cache

# (Optional) If you have frontend assets to compile with Node.js/NPM/Yarn
# You would typically install Node.js in this builder stage and then run your build commands:
# RUN apt-get update && apt-get install -y nodejs npm
# COPY package.json package-lock.json. # Copy these specific files
# RUN npm ci --no-audit --prefer-offline
# RUN npm run production # Or 'npm run build' depending on your package.json scripts

# --- Stage 2: Production Runtime Stage ---
FROM dunglas/frankenphp:1.8.0-php8.2-bookworm

# Set Caddy server name
ENV SERVER_NAME="http://"

# Install only essential runtime system dependencies
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    supervisor \
    libpq-dev \
    librabbitmq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install core PHP extensions needed at runtime
RUN install-php-extensions \
    gd \
    pcntl \
    opcache \
    pdo \
    pdo_mysql \
    redis

# Set working directory in the final image
WORKDIR /var/www/html

# Copy only the necessary files from the builder stage
# /app/vendor for Composer dependencies
COPY --from=builder /app/vendor /var/www/html/vendor
# Copy the entire application code (including the artisan file and optimized caches)
COPY --from=builder /app /var/www/html

# Copy PHP config and Supervisor config
COPY ./php.ini /usr/local/etc/php/
COPY ./supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Set permissions for Laravel's storage and cache directories
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 80 443

# Start Supervisor
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

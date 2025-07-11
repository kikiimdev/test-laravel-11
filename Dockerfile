# Use a multi-stage build to separate build dependencies from runtime dependencies,
# resulting in a smaller final image.

# --- Builder Stage ---
FROM dunglas/frankenphp:1.8.0-builder-php8.2-bookworm AS builder

# Set Caddy server name to "http://" to serve on 80 and not 443
# Read more: https://frankenphp.dev/docs/config/#environment-variables
ENV SERVER_NAME="http://"

# Install system dependencies needed for extensions and Composer
# Group apt-get commands to reduce layers.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    unzip \
    librabbitmq-dev \
    libpq-dev \
    supervisor \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions. Order matters for caching:
# install-php-extensions first, then pecl install.
# Group commands to reduce layers.
RUN install-php-extensions \
    gd \
    pcntl \
    opcache \
    pdo \
    pdo_mysql \
    redis \
    && pecl install xdebug \
    && docker-php-ext-enable xdebug

# Copy Composer from the official image. This ensures we use a known good version.
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Copy only composer.json and composer.lock first to leverage cache for dependencies.
COPY composer.json composer.lock ./

# Install Laravel dependencies. Use --no-dev for production builds.
# Use --optimize-autoloader and --no-interaction for production.
RUN composer install --no-dev

# --- Production Stage ---
# Use a smaller base image for the final production image.
FROM dunglas/frankenphp:1.8.0-php8.2-bookworm

# Set Caddy server name, inherit from builder stage or redefine if needed.
ENV SERVER_NAME="http://"

# Copy supervisor from the builder stage
COPY --from=builder /usr/bin/supervisord /usr/bin/supervisord
COPY --from=builder /etc/supervisor/conf.d/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy PHP extensions from the builder stage (if they are not included in the base image)
# Frankhenphp base images often include common extensions.
# Check if the extensions are already in the runtime image before copying.
# For example, xdebug should generally NOT be in a production image.
# If you truly need it for some very specific production debugging, then include it,
# but it's a performance overhead. For most cases, remove xdebug from the production stage.
# For the sake of matching your original request:
COPY --from=builder /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini /usr/local/etc/php/conf.d/
COPY --from=builder /usr/local/lib/php/extensions/no-debug-non-zts-*/xdebug.so /usr/local/lib/php/extensions/no-debug-non-zts-*/

# Copy the custom php.ini from the builder stage (or directly from host if it's small)
COPY ./php.ini /usr/local/etc/php/conf.d/99-custom.ini
# It's better to use conf.d/ to add custom settings rather than overwriting php.ini.
# This allows for easier merging with base image configurations.

WORKDIR /var/www/html

# Copy the application source code AFTER composer install,
# so changes to code don't invalidate the composer install layer.
COPY . .

# Copy vendor directory from the builder stage.
COPY --from=builder /var/www/html/vendor /var/www/html/vendor

# Set permissions for Laravel.
# Use a single RUN command for permissions to optimize layer creation.
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 80 443

# Start Supervisor.
# Use the full path for clarity.
CMD ["/usr/bin/supervisord", "-n", "-c",  "/etc/supervisor/conf.d/supervisord.conf"]

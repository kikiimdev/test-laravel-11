FROM dunglas/frankenphp

# Be sure to replace "your-domain-name.example.com" by your domain name
ENV SERVER_NAME=$APP_URL
# If you want to disable HTTPS, use this value instead:
#ENV SERVER_NAME=:80

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app

# If you use Symfony or Laravel, you need to copy the whole project instead:
COPY . .

# Enable PHP production settings
COPY ./php.ini /usr/local/etc/php/

# Install PHP extensions
RUN pecl install xdebug

# Install Laravel dependencies using Composer.
RUN composer install

# Enable PHP extensions
# RUN docker-php-ext-enable xdebug

# Set permissions for Laravel.
RUN chown -R www-data:www-data storage bootstrap/cache

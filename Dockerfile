# syntax=docker/dockerfile:1
# Kode aplikasi di-COPY ke dalam image (bukan bind mount) agar tidak ada
# overhead filesystem host (Docker Desktop / WSL2) yang mengganggu hasil.

ARG BASE_IMAGE=php:8.3-fpm

FROM ${BASE_IMAGE} AS base
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pdo_mysql opcache
# Konfigurasi PHP/opcache IDENTIK untuk semua varian
COPY docker/php-bench.ini /usr/local/etc/php/conf.d/zz-bench.ini
ARG APP_DIR=/var/www/html
WORKDIR ${APP_DIR}
COPY src/ ${APP_DIR}/

FROM base AS fpm
COPY docker/php-fpm-pool.conf /usr/local/etc/php-fpm.d/zzz-bench.conf

FROM base AS franken

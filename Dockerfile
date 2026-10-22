ARG BASE_IMAGE
FROM ${BASE_IMAGE}

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions pdo_mysql opcache
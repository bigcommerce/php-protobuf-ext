FROM php:8.4-fpm-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends autoconf gcc g++ make && \
    rm -rf /var/lib/apt/lists/*

# Build the patched protobuf extension from this repo's own source.
# Build context is the repo root (see docker-compose.yml), so these paths are repo-relative.
COPY src/php/ext/google/protobuf /usr/src/protobuf-ext
COPY src/third_party/utf8_range  /usr/src/protobuf-ext/third_party/utf8_range

RUN cd /usr/src/protobuf-ext && \
    phpize && \
    ./configure && \
    make -j"$(nproc)" && \
    make install && \
    docker-php-ext-enable protobuf

COPY tests/integration/docker/php/conf.d/protobuf.ini         /usr/local/etc/php/conf.d/protobuf.ini
COPY tests/integration/docker/php/fpm.d/zz-single-worker.conf /usr/local/etc/php-fpm.d/zz-single-worker.conf

WORKDIR /var/www

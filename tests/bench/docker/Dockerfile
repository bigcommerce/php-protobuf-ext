FROM php:8.4-cli-bookworm

# Build toolchain + protoc (PHP codegen is built into protoc) + composer deps.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        autoconf gcc g++ make git unzip curl ca-certificates protobuf-compiler && \
    rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Build the protobuf extension from this repo's own source (build context = repo root).
COPY src/php/ext/google/protobuf /usr/src/protobuf-ext
COPY src/third_party/utf8_range  /usr/src/protobuf-ext/third_party/utf8_range
RUN cd /usr/src/protobuf-ext && \
    phpize && ./configure && make -j"$(nproc)" && make install
# NOTE: deliberately NOT docker-php-ext-enable'd -- each config decides whether to
# load the extension via `php -d`, so the global INI must leave it off.

COPY tests/bench /opt/bench
WORKDIR /opt/bench

CMD ["bash", "bench.sh"]

# A copy of test/docker/Dockerfile of dream_postgres_driver, so that both
# repositories build the same image.
#
# A PostgreSQL test server with the extensions that the type tests need:
# pgvector, hstore, ltree and citext. The postgres alpine images ship
# hstore, ltree and citext. Alpine's own pgvector package is built for
# Alpine's PostgreSQL in /usr/lib, not for the PostgreSQL of this image in
# /usr/local, so pgvector is built from its source at a pinned tag.
#
# One layer: the build tools are added, used and removed in the same RUN,
# so they add no size to the image.
#
# Build one image for each major version and tag it
# dream-test-postgres:<version>, for example:
#
#   docker build --build-arg PG_MAJOR=18 -t dream-test-postgres:18 test/docker
#
# docker-compose.yml builds these images. Other repositories use the same
# tags.

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

ARG PGVECTOR_VERSION=v0.8.7

# with_llvm=no: the image's PostgreSQL is built with LLVM, and without this
# PGXS also wants clang to make JIT bitcode, which the tests do not use.
# OPTFLAGS="": no -march=native, so the image runs on any CPU of its
# architecture.
RUN set -eux; \
    apk add --no-cache --virtual .pgvector-build build-base git; \
    git clone --depth 1 --branch "${PGVECTOR_VERSION}" \
        https://github.com/pgvector/pgvector.git /tmp/pgvector; \
    make -C /tmp/pgvector with_llvm=no OPTFLAGS=""; \
    make -C /tmp/pgvector with_llvm=no install; \
    rm -rf /tmp/pgvector; \
    apk del --no-network .pgvector-build

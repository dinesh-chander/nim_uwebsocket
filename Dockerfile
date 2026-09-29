ARG NIM_VERSION=2.2.10

FROM nimlang/nim:${NIM_VERSION} AS builder

ARG WITH_OPENSSL=0
ARG USOCKETS_BACKEND=epoll
ARG APP_SOURCE=benchmark/bench_nim_express.nim
ARG APP_BINARY=app
ARG TCP_FASTOPEN_QUEUE=4096
ARG IOURING_MAX_CONNECTIONS=65536
ARG IOURING_RECV_BUFFERS=8192
ARG IOURING_RECV_BUFFER_SIZE=2048
ARG IOURING_ENTRIES=2048

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libssl-dev liburing-dev libsqlite3-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY nim_usockets/usockets/ nim_usockets/usockets/

WORKDIR /build/nim_usockets/usockets
RUN make clean && \
    TRANSPORT_CFLAGS="-DLIBUS_TCP_FASTOPEN_QUEUE=${TCP_FASTOPEN_QUEUE}" && \
    if [ "${USOCKETS_BACKEND}" = "io_uring" ]; then \
      TRANSPORT_CFLAGS="${TRANSPORT_CFLAGS} -DLIBUS_IO_URING_MAX_CONNECTIONS=${IOURING_MAX_CONNECTIONS} -DLIBUS_IO_URING_RECV_BUFFERS=${IOURING_RECV_BUFFERS} -DLIBUS_IO_URING_RECV_BUFFER_SIZE=${IOURING_RECV_BUFFER_SIZE} -DLIBUS_IO_URING_ENTRIES=${IOURING_ENTRIES}"; \
    fi && \
    case "${USOCKETS_BACKEND}" in \
      epoll) WITH_OPENSSL=${WITH_OPENSSL} make CFLAGS="${TRANSPORT_CFLAGS}" ;; \
      io_uring) WITH_OPENSSL=${WITH_OPENSSL} WITH_IO_URING=1 make CFLAGS="${TRANSPORT_CFLAGS}" ;; \
      *) echo "Unsupported Linux USOCKETS_BACKEND=${USOCKETS_BACKEND}; use epoll or io_uring" >&2; exit 1 ;; \
    esac
WORKDIR /build

COPY nim_utils/ nim_utils/
COPY nim_usockets/src/ nim_usockets/src/
COPY nim_usockets/nim.cfg nim_usockets/nim.cfg
COPY nim_usockets/nim_usockets.nimble nim_usockets/nim_usockets.nimble
COPY nim_fasthttpclient/ nim_fasthttpclient/
COPY nim_express/ nim_express/
COPY Makefile nim_uwebsocket.nimble ./
COPY scripts/ scripts/
COPY examples/ examples/
COPY benchmark/ benchmark/
COPY vendor/ vendor/

ARG SSL_LINK_FLAGS=""
RUN ./scripts/ensure_deps.sh && \
    test -d vendor/zippy/src && test -d vendor/checksums && \
    BACKEND_NIM_FLAGS="" && BACKEND_LINK_FLAGS="" && \
    TRANSPORT_CFLAGS="-DLIBUS_TCP_FASTOPEN_QUEUE=${TCP_FASTOPEN_QUEUE}" && \
    if [ "${USOCKETS_BACKEND}" = "io_uring" ]; then \
      TRANSPORT_CFLAGS="${TRANSPORT_CFLAGS} -DLIBUS_IO_URING_MAX_CONNECTIONS=${IOURING_MAX_CONNECTIONS} -DLIBUS_IO_URING_RECV_BUFFERS=${IOURING_RECV_BUFFERS} -DLIBUS_IO_URING_RECV_BUFFER_SIZE=${IOURING_RECV_BUFFER_SIZE} -DLIBUS_IO_URING_ENTRIES=${IOURING_ENTRIES}"; \
    fi && \
    if [ "${USOCKETS_BACKEND}" = "io_uring" ]; then BACKEND_NIM_FLAGS="-d:LIBUS_USE_IO_URING"; BACKEND_LINK_FLAGS="-luring"; fi && \
    if [ "${WITH_OPENSSL}" = "1" ]; then SSL_LINK_FLAGS="${SSL_LINK_FLAGS} -lssl -lcrypto -lstdc++"; fi && \
    mkdir -p /build/bin && nim c -d:release -d:danger --opt:speed --mm:arc ${BACKEND_NIM_FLAGS} \
    --path:nim_utils/src \
    --path:nim_usockets/src \
    --path:nim_express/src \
    --path:nim_fasthttpclient/src \
    --path:vendor/zippy/src \
    --path:vendor/brotli/src \
    --path:vendor/nim_zstd \
    --path:vendor/nim_libdeflate_gzip/src \
    --path:vendor/malebolgia/src \
    --path:vendor/jsony/src \
    --path:vendor/checksums \
    --passC:"-D_GNU_SOURCE -ftls-model=local-exec ${TRANSPORT_CFLAGS}" \
    --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl ${BACKEND_LINK_FLAGS} ${SSL_LINK_FLAGS}" \
    -o:/build/bin/${APP_BINARY} \
    ${APP_SOURCE}

FROM ubuntu:24.04 AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libssl3t64 liburing2 && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -r nimapp && useradd -r -g nimapp -s /usr/sbin/nologin nimapp

ARG APP_BINARY=app

COPY --from=builder /build/bin/${APP_BINARY} /usr/local/bin/app
COPY --from=builder /build/nim_express/config.json /etc/nim_express/config.json

USER nimapp
ENV NIM_EXPRESS_CONFIG=/etc/nim_express/config.json
ENV PORT=3000
EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["curl", "-f", "-s", "http://127.0.0.1:3000/plaintext"]

ENTRYPOINT ["/usr/local/bin/app"]

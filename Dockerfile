FROM debian:bookworm-slim AS build

ARG ZIG_VERSION=0.15.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils nodejs npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && /opt/zig/zig build -Doptimize=ReleaseFast \
    && /opt/zig/zig build wasm \
    && cd playground \
    && npm ci \
    && npm run build

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/zig-out/bin/zwgsl /usr/local/bin/zwgsl
COPY --from=build /src/zig-out/bin/zwgsl-lsp /usr/local/bin/zwgsl-lsp
COPY --from=build /src/zig-out/include/zwgsl.h /usr/local/include/zwgsl.h
COPY --from=build /src/zig-out/lib/ /usr/local/lib/

ENTRYPOINT ["zwgsl"]

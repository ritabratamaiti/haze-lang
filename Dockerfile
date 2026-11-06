# A small image with the haze command. It builds Haze from source with the Lean toolchain,
# then copies only the binary and the examples into the final image.
#
#   docker run --rm -v "$PWD:/work" ghcr.io/ritabratamaiti/haze-lang model.hz

FROM debian:bookworm-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
ENV PATH="/root/.elan/bin:${PATH}"
WORKDIR /src
# install the pinned toolchain in its own layer, so that it is cached across source changes
COPY lean-toolchain ./
RUN elan toolchain install "$(cat lean-toolchain)"
COPY . .
RUN lake build haze

FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/ritabratamaiti/haze-lang" \
      org.opencontainers.image.description="Haze: verifying software with uncertain outcomes" \
      org.opencontainers.image.licenses="FSL-1.1-ALv2"
COPY --from=build /src/.lake/build/bin/haze /usr/local/bin/haze
COPY examples /usr/share/haze/examples
WORKDIR /work
ENTRYPOINT ["haze"]

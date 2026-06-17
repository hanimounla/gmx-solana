###############################################################################
# Multi-stage Dockerfile for all GMSOL keeper services
#
# Builds:
#   gmsol-keeper order         — order executor
#   gmsol-keeper liquidator    — liquidation monitor
#   gmsol-keeper adl           — auto-deleverage keeper
#   gmsol-keeper glv           — GLV shift keeper
#   gmsol-keeper price-cache   — oracle price cache daemon
#
# The binary is selected at runtime via CMD/command override in k8s manifests.
#
# Build args:
#   BIN_NAME — binary to build (default: gmsol-keeper)
###############################################################################

ARG RUST_VERSION=1.87
ARG DEBIAN_CODENAME=bookworm

###############################################################################
# Stage 1: Chef (dependency caching)
###############################################################################
FROM rust:${RUST_VERSION}-slim-${DEBIAN_CODENAME} AS chef

RUN cargo install cargo-chef --locked
WORKDIR /app

###############################################################################
# Stage 2: Plan (generate recipe for dependency caching)
###############################################################################
FROM chef AS planner

COPY . .
RUN cargo chef prepare --recipe-path recipe.json

###############################################################################
# Stage 3: Build dependencies (cached layer)
###############################################################################
FROM chef AS builder-deps

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    libclang-dev \
    clang \
    && rm -rf /var/lib/apt/lists/*

# Cache dependencies separately from application code
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

###############################################################################
# Stage 4: Build application
###############################################################################
FROM builder-deps AS builder

ARG BIN_NAME=gmsol-keeper

# Copy full source
COPY . .

# Build only the target binary
RUN cargo build --release --bin ${BIN_NAME} \
    --no-default-features \
    --features "client,jito" \
    && strip target/release/${BIN_NAME}

###############################################################################
# Stage 5: Runtime (minimal distroless image)
###############################################################################
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

ARG BIN_NAME=gmsol-keeper

# Copy binary
COPY --from=builder /app/target/release/${BIN_NAME} /usr/local/bin/gmsol-keeper

# Copy CA certificates (needed for HTTPS to Solana RPC)
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Non-root user (uid 1000)
USER nonroot

# Health check port
EXPOSE 9090

ENTRYPOINT ["/usr/local/bin/gmsol-keeper"]
CMD ["--help"]

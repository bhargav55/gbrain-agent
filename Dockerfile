FROM oven/bun:debian AS bun_source
FROM debian:13

ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive

# Install system deps: Python, Node, git, curl, build tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    nodejs npm git curl ca-certificates \
    build-essential procps tini && \
    rm -rf /var/lib/apt/lists/*

# Copy Bun from official image
COPY --from=bun_source /usr/local/bin/bun /usr/local/bin/bun
COPY --from=bun_source /usr/local/bin/bunx /usr/local/bin/bunx

# Create non-root user
RUN useradd -u 10000 -m -d /opt/hermes hermes

WORKDIR /opt/hermes
USER hermes

# Install Hermes Agent
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

# Add Hermes to PATH
ENV PATH="/opt/hermes/.local/bin:${PATH}"

# Clone and install GBrain
RUN git clone https://github.com/garrytan/gbrain.git /opt/hermes/gbrain && \
    cd /opt/hermes/gbrain && \
    bun install && \
    bun link

# Copy entrypoint
COPY --chown=hermes:hermes entrypoint.sh /opt/hermes/entrypoint.sh
RUN chmod +x /opt/hermes/entrypoint.sh

USER root

# Railway health check port
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/hermes/entrypoint.sh"]

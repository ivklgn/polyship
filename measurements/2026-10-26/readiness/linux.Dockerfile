FROM debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends git perl procps python3 ca-certificates xz-utils >/dev/null && rm -rf /var/lib/apt/lists/*
COPY wt /usr/local/bin/wt
RUN useradd -m lab && chmod +x /usr/local/bin/wt
USER lab
RUN git config --global user.name lab && git config --global user.email lab@example.com && git config --global init.defaultBranch main

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PATH}"

# Flutter 開発に必要な最小ツールを導入する
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssh-client \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Flutter SDK をコンテナ内へ配置する（ホストは汚さない）
RUN git clone --depth 1 --branch stable https://github.com/flutter/flutter.git ${FLUTTER_HOME}

WORKDIR /workspace

# 初回起動時にキャッシュを準備しておく
RUN flutter --version

CMD ["bash"]

# zcode2api-plus 容器镜像：多阶段构建，单二进制 + 内嵌前端，无外部运行时。
# 构建：docker build -t zcode2api-plus .
# 运行：docker run -d -p 3000:3000 -v zcode-data:/data ghcr.io/janver/zcode2api-plus:latest

# ── 构建阶段 ──────────────────────────────────────────
FROM golang:1.25-bookworm AS builder

WORKDIR /src

# 先拷依赖清单，利用层缓存
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# 版本号注入（CI 传 --build-arg VERSION=2.0.1-go；默认 dev）
ARG VERSION=dev

# CGO 关闭：modernc.org/sqlite 为纯 Go 实现，产物为全静态二进制，
# 可直接跑在 debian-slim 上；rod（验证码浏览器）也是纯 Go。
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags="-s -w -X zcode2api/internal/config.AppVersion=${VERSION}" \
    -o /out/zcode2api ./cmd/zcode2api

# ── 运行阶段 ──────────────────────────────────────────
FROM debian:bookworm-slim

# ca-certificates：上游 HTTPS（api.z.ai 等）校验；
# tzdata：日志/额度时间本地化；
# wget：HEALTHCHECK 探活；
# 其余为 rod 驱动补丁 Chromium（ZCODE_CAPTCHA_BROWSER=true，首次启动自动下载
# 到 ~/.cloakbrowser）所需的共享库；默认人工回填模式用不到，但装上无副作用。
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates tzdata wget fonts-liberation \
    libasound2 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
    libcairo2 libcups2 libdbus-1-3 libdrm2 libexpat1 libfontconfig1 \
    libgbm1 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
    libpango-1.0-0 libx11-6 libx11-xcb1 libxcb1 libxcomposite1 \
    libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 \
    libxkbcommon0 libxrandr2 libxrender1 libxshmfence1 libxss1 \
    libxtst6 \
    && rm -rf /var/lib/apt/lists/*

# 非 root 运行；.cloakbrowser 预建目录供浏览器二进制缓存（可另挂卷持久化）
RUN useradd -m -u 10001 appuser \
    && mkdir -p /data /home/appuser/.cloakbrowser \
    && chown -R appuser:appuser /data /home/appuser/.cloakbrowser

USER appuser

# 数据目录（账号 SQLite、设备指纹）与监听地址；挂 -v 持久化 /data 即可
ENV ZCODE_DATA_DIR=/data \
    ZCODE_HOST=0.0.0.0 \
    ZCODE_PORT=3000

VOLUME /data
EXPOSE 3000

COPY --from=builder /out/zcode2api /usr/local/bin/zcode2api

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${ZCODE_PORT:-3000}/meta" || exit 1

ENTRYPOINT ["zcode2api", "serve"]

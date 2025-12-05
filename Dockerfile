# LibreOffice-only Gotenberg Dockerfile
ARG GOLANG_VERSION=1.25.4

# ----------------------------------------------
# pdfcpu binary build stage
# ----------------------------------------------
FROM golang:${GOLANG_VERSION} AS pdfcpu-binary-stage

ARG PDFCPU_VERSION=v0.11.1
ENV CGO_ENABLED=0

WORKDIR /home

RUN curl -Ls "https://github.com/pdfcpu/pdfcpu/archive/refs/tags/${PDFCPU_VERSION}.tar.gz" -o pdfcpu.tar.gz &&\
    tar --strip-components=1 -xvzf pdfcpu.tar.gz

RUN go mod download &&\
    go mod verify

RUN go build -o pdfcpu -ldflags "-s -w -X 'main.version=${PDFCPU_VERSION}' -X 'github.com/pdfcpu/pdfcpu/pkg/pdfcpu.VersionStr=${PDFCPU_VERSION}' -X main.builtBy=gotenberg" ./cmd/pdfcpu &&\
    ./pdfcpu version

# ----------------------------------------------
# Gotenberg binary build stage
# ----------------------------------------------
FROM golang:${GOLANG_VERSION} AS gotenberg-binary-stage

ARG GOTENBERG_VERSION=snapshot
ENV CGO_ENABLED=0

WORKDIR /home

# Copy go.mod and go.sum first for better caching
COPY go.mod go.sum ./
RUN go mod download &&\
    go mod verify

# Copy source code
COPY cmd ./cmd
COPY pkg ./pkg

RUN go build -o gotenberg -ldflags "-s -w -X 'github.com/gotenberg/gotenberg/v8/cmd.Version=${GOTENBERG_VERSION}'" cmd/gotenberg/main.go

# ----------------------------------------------
# Custom JRE stage
# ----------------------------------------------
FROM debian:13-slim AS custom-jre-stage

RUN apt-get update -qq &&\
    apt-get upgrade -yqq &&\
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends default-jdk-headless binutils

ENV JAVA_MODULES=java.base,java.desktop,java.naming,java.sql

RUN jlink \
    --add-modules ${JAVA_MODULES} \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=2 \
    --output /custom-jre

# ----------------------------------------------
# Final stage
# ----------------------------------------------
FROM debian:13-slim

COPY --from=custom-jre-stage /custom-jre /opt/java
ENV PATH="/opt/java/bin:${PATH}"

ARG GOTENBERG_VERSION=snapshot
ARG GOTENBERG_USER_GID=1001
ARG GOTENBERG_USER_UID=1001
ARG PDFTK_VERSION=v3.3.3

LABEL org.opencontainers.image.title="Gotenberg LibreOffice" \
    org.opencontainers.image.description="A containerized API for LibreOffice document to PDF conversion." \
    org.opencontainers.image.version="${GOTENBERG_VERSION}" \
    org.opencontainers.image.vendor="Gotenberg" \
    org.opencontainers.image.licenses="MIT"

# Install required packages for LibreOffice only
RUN apt-get update -qq &&\
    apt-get upgrade -yqq &&\
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    ca-certificates \
    curl \
    fontconfig \
    fonts-liberation \
    libreoffice \
    libreoffice-writer \
    libreoffice-calc \
    libreoffice-impress \
    libreoffice-draw \
    tini \
    unoconv \
    wget &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/*

# Install PDF tools
RUN curl -Ls "https://gitlab.com/pdftk-java/pdftk/-/releases/${PDFTK_VERSION}/downloads/pdftk-all.deb" -o /tmp/pdftk.deb &&\
    dpkg -i /tmp/pdftk.deb &&\
    rm /tmp/pdftk.deb

RUN curl -Ls "https://github.com/qpdf/qpdf/releases/download/v11.9.1/qpdf-11.9.1-bin-mingw64.zip" -o /tmp/qpdf.zip || \
    apt-get update -qq &&\
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends qpdf &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/* /tmp/qpdf.zip

RUN apt-get update -qq &&\
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libimage-exiftool-perl &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/*

# Copy binaries
COPY --from=pdfcpu-binary-stage /home/pdfcpu /usr/bin/
COPY --from=gotenberg-binary-stage /home/gotenberg /usr/bin/

# Create gotenberg user
RUN groupadd -r -g ${GOTENBERG_USER_GID} gotenberg &&\
    useradd -r -u ${GOTENBERG_USER_UID} -g gotenberg gotenberg &&\
    mkdir -p /home/gotenberg &&\
    chown -R gotenberg:gotenberg /home/gotenberg

# Copy fonts configuration
COPY build/fonts.conf /etc/fonts/conf.d/100-gotenberg.conf

# Set environment variables
ENV LIBREOFFICE_BIN_PATH=/usr/lib/libreoffice/program/soffice.bin
ENV UNOCONVERTER_BIN_PATH=/usr/bin/unoconv
ENV PDFTK_BIN_PATH=/usr/bin/pdftk
ENV QPDF_BIN_PATH=/usr/bin/qpdf
ENV EXIFTOOL_BIN_PATH=/usr/bin/exiftool
ENV PDFCPU_BIN_PATH=/usr/bin/pdfcpu

USER gotenberg
WORKDIR /home/gotenberg

EXPOSE 3000

ENTRYPOINT [ "/usr/bin/tini", "--" ]
CMD [ "gotenberg" ]


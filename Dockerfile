
#ARG BUILD_BASE=develop

#go-1.21
FROM --platform=$BUILDPLATFORM registry.redhat.io/ubi8/go-toolset:1.21@sha256:742ae6ec1aef3e7faae488c47695fb64964d342aefecf52d23bd9d5e6731d0b6 AS build

#rhoai-2.13-1

#FROM --platform=$BUILDPLATFORM $BUILD_BASE AS build

LABEL image="build"

USER root

# needed for konflux as the previous stage is not used
WORKDIR /opt/app
COPY go.mod go.sum ./
# Download dependencies before copying the source so they will be cached
RUN go mod download

# Copy the source
COPY . ./

ARG TARGETOS=amd64
ARG TARGETARCH=linux

# Build the binaries using native go compiler from BUILDPLATFORM but compiled output for TARGETPLATFORM
# https://www.docker.com/blog/faster-multi-platform-builds-dockerfile-cross-compilation-guide/
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    export GOOS=${TARGETOS:-linux} && \
    export GOARCH=${TARGETARCH:-amd64} && \
    go build -o puller model-serving-puller/main.go && \
    go build -o triton-adapter model-mesh-triton-adapter/main.go && \
    go build -o mlserver-adapter model-mesh-mlserver-adapter/main.go && \
    go build -o ovms-adapter model-mesh-ovms-adapter/main.go && \
    go build -o torchserve-adapter model-mesh-torchserve-adapter/main.go


###############################################################################
# Stage 3: Copy build assets to create the smallest final runtime image
###############################################################################
#ubi-minimal:latest
FROM registry.redhat.io/ubi8/ubi-minimal@sha256:cf095e5668919ba1b4ace3888107684ad9d587b1830d3eb56973e6a54f456e67 as runtime

ARG USER=2000

USER root

# install python to convert keras to tf
# NOTE: tensorflow not supported on PowerPC (ppc64le) or System Z (s390x) https://github.com/tensorflow/tensorflow/issues/46181
RUN --mount=type=cache,target=/root/.cache/microdnf:rw \
    microdnf install --setopt=cachedir=/root/.cache/microdnf --setopt=ubi-8-appstream-rpms.module_hotfixes=1 \
       gcc \
       gcc-c++ \
       python38-devel \
       python38 \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && true

# need to upgrade pip and install wheel before installing grpcio, before installing tensorflow on aarch64
# use caching to speed up multi-platform builds
COPY requirements.txt requirements.txt
ENV PIP_CACHE_DIR=/root/.cache/pip
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt
RUN rm -rfv requirements.txt
USER ${USER}

# Add modelmesh version
COPY version /etc/modelmesh-version

# Copy over the binary and use it as the entrypoint
COPY --from=build /opt/app/puller /opt/app/
COPY --from=build /opt/app/triton-adapter /opt/app/
COPY --from=build /opt/app/mlserver-adapter /opt/app/
COPY --from=build /opt/app/model-mesh-triton-adapter/scripts/tf_pb.py /opt/scripts/
COPY --from=build /opt/app/ovms-adapter /opt/app/
COPY --from=build /opt/app/torchserve-adapter /opt/app/

# wait to create commit-specific LABEL until end of the build to not unnecessarily
# invalidate the cached image layers
ARG IMAGE_VERSION
ARG COMMIT_SHA

LABEL com.redhat.component="odh-modelmesh-runtime-adapter-container" \
      name="managed-open-data-hub/odh-modelmesh-runtime-adapter-container-rhel8" \
      description="Container which runs in each model serving pod and act as an intermediary between model-mesh and third-party model-server containers" \
      summary="odh-model-serving-runtime-adapter" \
      maintainer="['managed-open-data-hub@redhat.com']" \
      io.k8s.display-name="odh-model-serving-runtime-adapter" \
      io.k8s.description="odh-model-serving-runtime-adapter" \
      com.redhat.license_terms="https://www.redhat.com/licenses/Red_Hat_Standard_EULA_20191108.pdf"
      
# Don't define an entrypoint. This is a multi-purpose image so the user should specify which binary they want to run (e.g. /opt/app/puller or /opt/app/triton-adapter)
# ENTRYPOINT ["/opt/app/puller"]

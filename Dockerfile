# Copyright 2021 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG GOLANG_VERSION=1.21
ARG BUILD_BASE=develop

FROM --platform=$BUILDPLATFORM registry.redhat.io/ubi8/go-toolset@sha256:4ec05fd5b355106cc0d990021a05b71bbfb9231e4f5bdc0c5316515edf6a1c96 AS build

FROM --platform=$BUILDPLATFORM $BUILD_BASE AS build

LABEL image="build"

USER root

# needed for konflux as the previous stage is not used
WORKDIR /opt/app
COPY go.mod go.sum ./
# Download dependencies before copying the source so they will be cached
RUN go mod download

# Copy the source
COPY . ./

# https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope
# don't provide "default" values (e.g. 'ARG TARGETARCH=amd64') for non-buildx environments,
# see https://github.com/docker/buildx/issues/510
ARG TARGETOS
ARG TARGETARCH

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
FROM registry.access.redhat.com/ubi8/ubi-minimal:latest as runtime

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

LABEL name="model-serving-runtime-adapter" \
      version="${IMAGE_VERSION}" \
      release="${COMMIT_SHA}" \
      summary="Sidecar container which runs in the ModelMesh Serving model server pods" \
      description="Container which runs in each model serving pod acting as an intermediary between ModelMesh and third-party model-server containers"

# Don't define an entrypoint. This is a multi-purpose image so the user should specify which binary they want to run (e.g. /opt/app/puller or /opt/app/triton-adapter)
ENTRYPOINT ["/opt/app/puller"]

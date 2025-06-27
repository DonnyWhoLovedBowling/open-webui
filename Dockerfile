# Use an internal Harbor registry for base images
# Define the Harbor registry URL as a build argument (override as needed)
ARG HARBOR_REGISTRY=harbor.intern.ind.nl/docker.io/library

# Initialize device type args
# use build args in the docker build command with --build-arg="BUILDARG=true"
ARG USE_CUDA=false
ARG USE_OLLAMA=false
# Tested with cu117 for CUDA 11 and cu121 for CUDA 12 (default)
ARG USE_CUDA_VER=cu128
# any sentence transformer model; models to use can be found at https://huggingface.co/models?library=sentence-transformers
# Leaderboard: https://huggingface.co/spaces/mteb/leaderboard
# for better performance and multilangauge support use "intfloat/multilingual-e5-large" (~2.5GB) or "intfloat/multilingual-e5-base" (~1.5GB)
# IMPORTANT: If you change the embedding model (sentence-transformers/all-MiniLM-L6-v2) and vice versa, you aren't able to use RAG Chat with your previous documents loaded in the WebUI! You need to re-embed them.
ARG USE_EMBEDDING_MODEL=""
ARG USE_RERANKING_MODEL=""

# Tiktoken encoding name; models to use can be found at https://huggingface.co/models?library=tiktoken
ARG USE_TIKTOKEN_ENCODING_NAME=""

ARG BUILD_HASH=dev-build
# Override at your own risk - non-root configurations are untested
ARG UID=0
ARG GID=0

# Define Nexus PyPI index for pip installs (override as needed)
ARG PIP_INDEX_URL

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM ${HARBOR_REGISTRY}/node:22-alpine3.20 AS build

# trust your internal CA if needed
COPY tls-ca-bundle.pem /usr/local/share/ca-certificates/tls-ca-bundle.crt
RUN cat /usr/local/share/ca-certificates/tls-ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt && \
    apk --no-cache add ca-certificates && update-ca-certificates -v -f
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/tls-ca-bundle.crt
ARG BUILD_HASH
WORKDIR /app
# Before your RUN npm ci line
ARG HTTP_PROXY_ARG
ARG HTTPS_PROXY_ARG
ARG NO_PROXY_ARG

# Set them as environment variables for the build stage
ENV HTTP_PROXY=${HTTP_PROXY_ARG}
ENV HTTPS_PROXY=${HTTPS_PROXY_ARG}
ENV NO_PROXY=${NO_PROXY_ARG}

# to store git revision in build
RUN apk add --no-cache git
COPY .npmrc .
COPY package.json package-lock.json ./
RUN npm ci || (cat /root/.npm/_logs/*-debug-0.log && exit 1)

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## WebUI backend ########
FROM ${HARBOR_REGISTRY}/python:3.12-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID
ARG PIP_INDEX_URL
ARG PIP_TRUSTED_HOST
## Basis ##
ENV ENV=prod \
    PORT=8080 \
    # pass build args to the build
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    # use Nexus PyPI index for all pip installs
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST}

## Basis URL Config ##
ENV OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL=""

## API Key and Security Config ##
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

#### Other models #########################################################
## whisper TTS model settings ##
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models"

## RAG Embedding model settings ##
ENV RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models"

## Tiktoken model settings ##
ENV TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken"

## Hugging Face download cache ##
ENV HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

ENV HOME=/root

# Create user and group if not root
RUN if [ $UID -ne 0 ]; then \
      if [ $GID -ne 0 ]; then addgroup --gid $GID app; fi; \
      adduser --uid $UID --gid $GID --home $HOME --disabled-password --no-create-home app; \
    fi

RUN mkdir -p $HOME/.cache/chroma
RUN echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id

# Make sure the user has access to the app and home
RUN chown -R $UID:$GID /app $HOME

# install python dependencies, using Nexus PyPI index
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

RUN pip3 install --no-cache-dir --index-url ${PIP_INDEX_URL} --trusted-host ${PIP_TRUSTED_HOST} uv && \
    uv pip install --system -r requirements.txt --no-cache-dir \
      --index-url ${PIP_INDEX_URL} --trusted-host ${PIP_TRUSTED_HOST} && \
    mkdir -p /app/backend/data && \
    chown -R $UID:$GID /app/backend/data/

# copy built frontend files
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# copy backend files
COPY --chown=$UID:$GID ./backend .

EXPOSE 8080

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

USER $UID:$GID

ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

CMD [ "bash", "start.sh" ]

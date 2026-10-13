# syntax=docker/dockerfile:1
#
# Galadari voice ordering agent.
#
# Python is pinned to 3.12 to match the environment the agent is developed
# and run on (3.12.3); chromadb / onnxruntime wheel availability is the
# reason not to float to a newer minor.
ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim AS base

ENV PYTHONUNBUFFERED=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

ARG UID=10001
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/app" \
    --shell "/sbin/nologin" \
    --uid "${UID}" \
    appuser

RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    python3-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
USER appuser

COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# No `livekit.agents download-files` step: this agent is pure
# speech-to-speech via the OpenAI Realtime model and installs no plugin
# that ships model weights (no silero VAD, no turn-detector).

COPY . .

# The Chroma index is NOT baked into the image. It is built on first run
# from data/menu.csv, which costs one embedding pass over 108 dishes.
CMD ["python", "agent.py", "start"]

# Immagine locale di OpenMausBot (ADR-012). L'immagine pubblicata upstream
# (target `server`) non contiene nessun engine: senza le CLI qui sotto il
# server parte ma nessun bot può lavorare. Stesso schema di
# deploy/local/Dockerfile upstream, con due differenze:
# - versioni fissate invece di "l'ultima di npm a ogni build", così Renovate
#   propone i bump (customManagers in renovate.json, commenti qui sotto);
# - niente Grok: non usato, una CLI in meno con accesso alla shell dei bot.
#
# Il tag di FROM lo aggiorna Renovate (manager dockerfile, regola senza
# automerge in renovate.json: pre-1.0, rilasci quotidiani).
FROM ghcr.io/milind-soni/openmausbot:v0.1.111

USER root

# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.300
# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.162.1

# HOME temporanea: le cache npm della build non devono finire nell'immagine
# né, soprattutto, nel volume /data (che è la HOME di maus a runtime).
RUN HOME=/tmp/omb-build-home npm install -g \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
  && rm -rf /tmp/omb-build-home /tmp/node-compile-cache

USER maus

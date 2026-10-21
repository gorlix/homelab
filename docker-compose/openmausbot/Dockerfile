# Immagine locale di OpenMausBot (ADR-012). L'immagine pubblicata upstream
# (target `server`) non contiene nessun engine: senza le CLI qui sotto il
# server parte ma nessun bot può lavorare. Stesso schema di
# deploy/local/Dockerfile upstream, con due differenze:
# - versioni fissate invece di "l'ultima di npm a ogni build", così Renovate
#   propone i bump (customManagers in renovate.json, commenti qui sotto);
# - niente Grok: non usato, una CLI in meno con accesso alla shell dei bot;
# - in più opencode e Cursor, engine supportati upstream ma non nell'immagine.
#
# Il tag di FROM lo aggiorna Renovate (manager dockerfile, regola senza
# automerge in renovate.json: pre-1.0, rilasci quotidiani).
FROM ghcr.io/milind-soni/openmausbot:v0.1.120

USER root

# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.306
# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.163.0
# renovate: datasource=npm depName=opencode-ai
ARG OPENCODE_VERSION=1.19.3

# HOME temporanea: le cache npm della build non devono finire nell'immagine
# né, soprattutto, nel volume /data (che è la HOME di maus a runtime).
RUN HOME=/tmp/omb-build-home npm install -g \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
      "opencode-ai@${OPENCODE_VERSION}" \
  && rm -rf /tmp/omb-build-home /tmp/node-compile-cache

# Cursor CLI. Non `curl https://cursor.com/install | bash`: quello script
# installa in ~/.local (cioè nel volume /data, fuori dall'immagine) e prende
# sempre l'ultima versione. Qui si scarica lo stesso pacchetto che lo script
# scarica, a versione fissata, in /opt, e si espone `cursor-agent`, il nome
# che il driver di OpenMausBot cerca (docs/cursor.md upstream).
# Non è su npm: Renovate non lo vede, la versione si aggiorna a mano leggendo
# DOWNLOAD_URL in https://cursor.com/install.
ARG CURSOR_AGENT_VERSION=2026.10.19-6bbf2c4
RUN mkdir -p /opt/cursor-agent \
  && curl -fsSL "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/x64/agent-cli-package.tar.gz" \
     | tar --strip-components=1 -xzf - -C /opt/cursor-agent \
  && ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/cursor-agent \
  && cursor-agent --version

# Antigravity non si installa qui: OpenMausBot scarica da solo il runtime
# ufficiale Google (circa 1.9 GB, SHA-256 verificato) dalla UI, in
# /data/.openmausbot/tools/. Escluso dal backup (docker-compose.yml).

USER maus

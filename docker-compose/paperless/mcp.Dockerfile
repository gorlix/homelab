# Immagine locale del server MCP di Paperless (HOME-52). Il progetto
# (github.com/tb1337/paperless-mcp, MIT) pubblica su PyPI ma non un'immagine:
# si costruisce qui, con la versione fissata. Pre-1.0 ("highly experimental"
# nel README, nomi dei tool che cambiano): Renovate propone i bump senza
# automerge (renovate.json, customManagers + packageRules).
FROM python:3.13-slim

# renovate: datasource=pypi depName=paperless-mcp
ARG PAPERLESS_MCP_VERSION=0.1.0

RUN pip install --no-cache-dir "paperless-mcp==${PAPERLESS_MCP_VERSION}" \
  && useradd --system --no-create-home mcp

USER mcp
EXPOSE 8000
# Il resto (URL, token, modalità) arriva dalle variabili PAPERLESS_* del compose.
CMD ["paperless-mcp", "--http"]

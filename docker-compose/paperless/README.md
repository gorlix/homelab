# paperless-gpt su Paperless-119 (HOME-48)

paperless-gpt suggerisce titolo, tag, corrispondente e tipo di documento con un
LLM. Qui usa l'API Anthropic (`claude-haiku-5-5`). Contesto generale in
ADR-014 (PR #59); questa nota va poi riassunta lì.

## Come funziona

- Il servizio guarda solo i documenti con il tag **`ai-process`** (`AUTO_TAG`).
  Un documento senza quel tag non lascia mai la LXC.
- A fine elaborazione toglie `ai-process` e mette `paperless-gpt-auto-complete`;
  se Paperless rifiuta la modifica mette `paperless-gpt-failed`.
- Non crea tag nuovi (`CREATE_NEW_TAGS=false`): usa solo quelli già esistenti.
- Nessuna porta pubblicata. La UI di paperless-gpt non ha autenticazione e non
  serve in modalità automatica.

## Cosa esce verso Anthropic

Il testo già estratto da Paperless (OCR di Paperless, non di paperless-gpt) dei
soli documenti con il tag, più i nomi di tag e corrispondenti esistenti. Niente
immagini: OCR LLM e vision non sono configurati.

## Limiti da tenere presente

- È un provider esterno: il tag è l'unico filtro. Un tag messo per errore su un
  documento sensibile lo manda ad Anthropic. Non c'è un controllo ulteriore.
- Modalità automatica: i suggerimenti vengono applicati senza approvazione. Per
  rivedere prima serve la UI (`MANUAL_TAG`), che andrebbe esposta solo su LAN o
  Tailscale, mai pubblica.
- Immagine pre-1.0 (0.x): Renovate non fa automerge (`renovate.json`).
- La qualità sui documenti italiani non è ancora misurata: va provata su un
  documento di test.
- Il costo è a carico dei crediti API dell'account Anthropic.

## Segreti

Su Infisical `homelab-env`, `prod`, cartella `/paperless`, oltre a quelli di
Paperless: `ANTHROPIC_API_KEY` e `PAPERLESS_API_TOKEN` (token dell'utente
`gorlix`, con i permessi di quell'utente sui documenti).

## Dati

`/mnt/persistent-data/paperless-gpt/{prompts,config,db}`, proprietario `10001`
(utente del container). `db` contiene lo storico per l'annullamento.

## Provare

1. Aggiungere un documento di prova e mettergli il tag `ai-process`.
2. `docker compose logs -f paperless-gpt` nella cartella `/opt/paperless`.
3. Controllare titolo e tag, poi cancellare il documento di prova.

---
name: new-docker-service
description: Scaffold a new Docker Compose service for this homelab repo so it is publishable from the moment it's written — secrets go through Infisical from the start, never inline in the compose file.
when_to_use: Use when the user has drafted (or wants to draft) a new docker-compose.yml for a service and says things like "aggiungi un nuovo servizio", "scaffold questo docker compose", "prepara questo servizio per Infisical", or invokes this skill directly after writing a new compose file. Also use if asked to review/fix an EXISTING compose file that has secrets hardcoded in it (e.g. the Semaphore case) — same end state, different starting point.
---

# Contesto del repository (leggi prima di fare qualunque cosa)

Repo: homelab GitOps portfolio. Regola d'oro (da CLAUDE.md): nessun segreto in
chiaro nel repo, mai. Prima di questa skill, i docker-compose venivano scritti
con segreti a volte inline (caso reale: `Semaphore/docker-compose.yml` aveva un
token di registrazione runner e un token Gotify direttamente
nell'`environment:` del container) e poi "sanitizzati" a posteriori — fragile,
facile dimenticare un caso. Questa skill inverte l'ordine: il file nasce già
corretto, non c'è nulla da sanitizzare dopo.

**Architettura da rispettare (verificata dal vivo in questa sessione, non
assunta):**

- `docker/<servizio>/docker-compose.yml` nel repo è la fonte di verità
  versionata. Sull'host reale (es. `pve-management`, alias SSH già
  configurato) esiste anche `/opt/docker-compose/<servizio>/` — quella è la
  copia LIVE dove i container girano davvero, con dati/segreti reali. Le due
  cose sono concettualmente parallele ma **in questo repo la fonte di verità
  tracciata è `docker/`**, non `docker-compose/` (decisione esplicita
  dell'utente — non duplicare tracciando entrambe a meno che non lo chieda
  di nuovo esplicitamente).
- Segreti applicativi (password DB, token, credenziali) vivono in **Infisical**
  (self-hosted, vedi ADR-007), non in un `.env` versionato. Il ruolo Ansible
  `infrastructure/ansible/roles/infisical_secrets/tasks/main.yml` fa login con l'identità
  `ansible-automation` (Universal Auth, credenziali in 1Password) e per ogni
  servizio elencato in `infrastructure/ansible/roles/infisical_secrets/defaults/main.yml`
  (`infisical_migrated_services`) esporta la cartella Infisical corrispondente
  come `.env` **al momento del deploy**, mai committato. Il ruolo
  `infrastructure/ansible/roles/docker_service/tasks/main.yml` scrive quell'`.env` generato
  solo se il servizio è in quella lista; altrimenti copia un `.env` statico se
  presente (da evitare per servizi nuovi).
- Il progetto Infisical è **"Homelab Env"**, id `578016f6-4dc0-4507-a961-4d1e84c9be17`,
  ambiente realmente usato è **`prod`** (slug `prod`). Ogni servizio ha una
  cartella dedicata a `/<nome-servizio>` nell'ambiente `prod`.
- Tool MCP Infisical disponibili: `mcp__infisical__create-folder`,
  `mcp__infisical__create-secret`, `mcp__infisical__update-secret`,
  `mcp__infisical__get-secret`, `mcp__infisical__list-secrets`,
  `mcp__infisical__list-projects`, `mcp__infisical__create-environment`.
- Sincronizzazione con l'host reale: dopo un push, `/opt` su `pve-management`
  va risincronizzato con `ssh pve-management 'cd /opt && git fetch origin &&
  git reset --hard origin/main'` — tocca solo i path tracciati, mai
  `docker-compose/` o `infrastructure/` (ignorate per nome, vedi `.gitignore`).
- L'hook pre-commit gitleaks è attivo sia in locale che su `/opt` — è una rete
  di sicurezza aggiuntiva, MAI la difesa primaria. La difesa primaria è la
  revisione riga per riga fatta da questa skill.

# REGOLA CRITICA sui tool MCP di Infisical — letta da un incidente reale

`mcp__infisical__list-secrets` e `mcp__infisical__get-secret` restituiscono i
**valori in chiaro**, non solo i nomi delle chiavi. In questa stessa sessione,
chiamare `list-secrets` su `/traefik` per verificare un project id ha esposto
un `TUNNEL_TOKEN` reale nell'output — trattato come compromesso, ruotato
manualmente dopo.

**Prima di chiamare `list-secrets` o `get-secret` su un path che potrebbe già
contenere segreti reali, chiediti se ti serve davvero il VALORE o solo sapere
che una chiave esiste.** Se ti serve solo verificare l'esistenza/i nomi delle
chiavi di un servizio già migrato, non c'è un modo pulito per farlo via questi
due tool senza vedere i valori — in quel caso o lo eviti, o accetti
consapevolmente l'esposizione e tratti il valore come da ruotare se il
servizio è già in produzione con quel valore. Per un servizio NUOVO che stai
scaffoldando (valori appena creati da te, non ancora "in produzione" da
proteggere), il rischio è più basso ma la disciplina resta: non echeggiare mai
un valore recuperato in un messaggio di testo verso l'utente.

# Procedura

## 1. Identifica il servizio e leggi il compose reale

Chiedi (se non è ovvio dal contesto) il nome del servizio e dove si trova il
file draft (locale, o già su un host via SSH). Leggi il file per intero prima
di scrivere qualunque cosa.

## 2. Revisione riga per riga (manuale, non delegata a gitleaks)

Cerca esplicitamente:

- **`environment:` con valori letterali che sembrano segreti** (password,
  token, chiavi, connection string con credenziali dentro). Qualunque cosa
  che NON sia configurazione pubblica (nomi di rete, porte, flag booleani) va
  estratta.
- **`env_file: .env`** già presente — bene, ma verifica che NON esista un
  `.env` reale da copiare insieme al compose (mai committare l'`.env` stesso,
  solo il compose).
- **`volumes:` con bind mount locali** (`./data`, `./pgdata`, nomi custom) —
  ogni cartella di stato/dati reale deve avere un pattern in `.gitignore`.
  Non assumere che un pattern esistente copra un nome nuovo: verifica sempre
  con `git check-ignore -v docker/<servizio>/<cartella>/test` — deve
  rispondere con la regola che matcha. Se non risponde nulla, aggiungi il
  pattern (stesso stile delle righe già presenti sotto `# Docker`) prima di
  procedere, non dopo.
- **IP/domini hardcoded**: IP privati LAN (`192.168.x.x`) sono accettati,
  convenzione già in uso nel repo (vedi `docker/traefik/dynamic/dynamic.yml`,
  `docker/linkwarden/docker-compose.yml`). IP pubblici mai.
- **Immagini non pinnate** (`:latest`): non bloccante, ma segnalalo
  all'utente — è una scelta loro, non tua, se accettare la deriva di
  versione.
- **File montati che NON sono variabili d'ambiente** (es. un file di
  credenziali JSON, un certificato): questi NON possono passare da Infisical
  come env var. Fermati e chiedi come vuole gestirli — di solito significa
  "non versionabile" (come `1password-credentials.json`) o "servono un
  meccanismo diverso" (non inventarne uno senza chiedere).

Se trovi segreti hardcoded che il servizio stesso non riesce a esprimere
diversamente (es. un tool che non supporta `env_file`, solo config file con
dentro credenziali) — fermati, spiega il problema, chiedi come procedere.
Non "aggirarlo" mettendo il segreto in un commento o in un file adiacente
non tracciato senza dirlo chiaramente.

## 3. Riscrivi il compose nella forma corretta

Ogni variabile che porta un valore reale diventa una entry in `env_file:
.env` (mai `environment:` con valore letterale). Le uniche eccezioni
legittime a rimanere in `environment:` sono valori non segreti (nomi rete,
porte, flag) — stesso pattern già in uso in `docker/infisical/docker-compose.yml`
(es. `NODE_ENV=production`) e `docker/traefik/docker-compose.yml`.

## 4. Provisioning su Infisical

1. Se non esiste già, crea la cartella del servizio:
   `mcp__infisical__create-folder` con `projectId:
   578016f6-4dc0-4507-a961-4d1e84c9be17`, `environment: prod`, `name:
   <nome-servizio>`, `path: /`.
2. Per ciascuna chiave individuata al passo 2-3, determina il valore:
   - **Generabile localmente** (password DB, token random interni): generalo
     tu stesso (es. `openssl rand -base64 32` via Bash, o inline) e passalo
     DIRETTAMENTE a `mcp__infisical__create-secret` nella stessa risposta in
     cui lo generi — non stamparlo mai in un messaggio di testo, non
     rileggerlo con `get-secret` dopo per "controllare".
   - **Emesso da terzi** (API key di un servizio esterno, credenziali che
     l'utente possiede già): chiedi all'utente il valore. Se te lo incolla in
     chat, è inevitabilmente visibile una volta — non ripeterlo, non
     echeggiarlo in nessun messaggio successivo, usalo subito per
     `create-secret` e basta.
   - Crea il secret: `mcp__infisical__create-secret` con `projectId`,
     `environmentSlug: prod`, `secretPath: /<nome-servizio>`, `secretName`,
     `secretValue`.
3. Registra il servizio in
   `infrastructure/ansible/roles/infisical_secrets/defaults/main.yml`, lista
   `infisical_migrated_services` (aggiungi il nome, mantieni ordine
   alfabetico se ragionevole).

## 5. Posiziona il file nel repo

Copia il compose (senza `.env`, senza cartelle dati) in
`docker/<nome-servizio>/docker-compose.yml`. Se il servizio ha config
aggiuntiva non-segreta da versionare (es. `dynamic.yml` di Traefik), copiala
insieme.

## 6. Registra il servizio per il deploy

Se il servizio va su un host già provisionato da OpenTofu, aggiorna la lista
`services` di quell'host in `infrastructure/opentofu/nodes/dell-emc/variables.tf`. Il deploy
effettivo avviene poi con `infrastructure/opentofu/nodes/dell-emc/apply.sh apply`
(rigenera l'inventory e rilancia Ansible in modo idempotente — non serve un
meccanismo diverso).

## 7. Verifica prima di committare

- `git check-ignore -v` su ogni cartella dati che il compose monta — deve
  risultare ignorata.
- Il compose file stesso NON deve risultare ignorato (verifica il contrario
  con `git check-ignore -q docker/<servizio>/docker-compose.yml` — deve
  fallire, cioè non essere ignorato).
- Nessun valore letterale sospetto rimasto in `environment:` — rileggi il
  file finale, non fidarti della riscrittura al passo 3 senza un secondo
  passaggio.

## 8. Commit, push, sync

Commit (Conventional Commits, italiano, stile del repo — vedi commit
recenti per il tono). L'hook gitleaks scansiona automaticamente; se blocca
qualcosa, non forzare con `--no-verify`, capisci cosa ha trovato e correggi.
Poi:

```
git push origin main
ssh pve-management 'cd /opt && git fetch origin && git reset --hard origin/main'
```

## 9. Deploy e verifica funzionale

Esegui `infrastructure/opentofu/nodes/dell-emc/apply.sh apply` (chiedi conferma esplicita
prima di un apply reale, come da prassi del repository — non è un'azione
automatica silenziosa). Dopo il deploy, verifica che il container sia up
(`docker ps` sull'host target) e, se il servizio espone un endpoint HTTP, che
risponda (`curl -s -o /dev/null -w "%{http_code}"`). Non dichiarare successo
solo perché `docker compose up -d` non ha dato errori.

# Cosa NON fare

- Non committare mai un `.env` reale, nemmeno "temporaneamente".
- Non assumere che un pattern `.gitignore` esistente copra un nome di
  cartella nuovo — verifica sempre.
- Non chiamare `list-secrets`/`get-secret` per curiosità o per "ricontrollare"
  qualcosa che hai appena scritto — se l'hai scritto tu in questa stessa
  chiamata, sai già cosa c'è.
- Non inventare un meccanismo di gestione segreti alternativo a Infisical/
  1Password per un caso scomodo (file montati, config YAML con segreti
  inline) senza prima chiedere all'utente.
- Non fare `tofu apply` senza conferma esplicita — tocca infrastruttura
  reale.

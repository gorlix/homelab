# carlo-vault

Vault Obsidian del bot Carlo (HOME-56). Tre servizi sulla cartella `./vault`:
`mcp` (server MCP), `git` (commit e push ogni 5 minuti) e `tailscale`
(condivisione in sola lettura via Taildrive, HOME-56).

## Lettura del vault dal PC (Taildrive)

Il container `tailscale` entra nel tailnet come `carlo-vault` con il tag
`tag:carlo-vault` e condivide `/vault` con il nome `carlo_vault` (i nomi di share non ammettono il trattino). Il vault è
montato `:ro` nel container, quindi il demone non può scriverci. Le ACL del
tailnet danno poi accesso `ro` solo ad Ale.

### ACL del tailnet (da applicare nella console, non versionate)

```jsonc
"tagOwners": { "tag:carlo-vault": ["autogroup:admin"] },
"nodeAttrs": [
  { "target": ["tag:carlo-vault"], "attr": ["drive:share"] },
  { "target": ["<dispositivo o utente di Ale>"], "attr": ["drive:access"] }
],
"grants": [
  {
    "src": ["<utente o dispositivo di Ale>"],
    "dst": ["tag:carlo-vault"],
    "app": { "tailscale.com/cap/drive": [{ "shares": ["carlo_vault"], "access": "ro" }] }
  }
]
```

Il nome del tailnet e gli indirizzi non stanno nel repo.

### Segreto

`CARLO_VAULT_TS_AUTHKEY` su Infisical `prod/carlo-vault`: chiave di
autenticazione creata con tag `tag:carlo-vault`, monouso, non effimera. Serve
solo al primo avvio; lo stato del nodo sta nel volume `tailscale-state`.

### Mount sul PC

```sh
rclone mount --read-only :webdav: ~/carlo-vault \
  --webdav-url http://100.100.100.100:8080/<tailnet>/carlo-vault/carlo_vault
```

L'URL ha la forma `/<tailnet>/<macchina>/<condivisione>`. In alternativa
`davfs2`, come indica la documentazione Taildrive.

## Da tenere presente

- **Taildrive è alpha.** Sintassi delle ACL e comportamento possono cambiare.
- **Solo lettura, in due punti:** `:ro` di Docker e `access: "ro"` nelle ACL.
  Il sidecar `git` fa `git add -A`: nessuno deve scrivere file nel vault, altrimenti
  finiscono nei commit di Carlo.
- **Niente tempo reale.** Obsidian su un mount WebDAV non vede le modifiche
  da solo: bisogna ricaricare il vault. Il vault stesso cambia al ritmo di Carlo.
- **Obsidian vuole scrivere `.obsidian/`** (configurazione, workspace). Su un
  mount read-only può dare errori o aprire il vault senza salvare le impostazioni.
- **Modalità userspace.** Docker-100 è una LXC senza `/dev/net/tun`: il nodo
  non instrada pacchetti, serve solo Taildrive. Non è una prova che la
  condivisione funzioni in questa modalità: va verificata al primo deploy.
- **Revoca:** togliere la grant dalle ACL basta a chiudere l'accesso; per
  eliminare il nodo, rimuoverlo dalla console e fermare il servizio.
- **Chiave di autenticazione:** la chiave scade (fino a 90 giorni). Se il
  volume di stato va perso, ne serve una nuova su Infisical.

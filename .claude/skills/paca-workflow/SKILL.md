---
name: paca-workflow
description: Come tracciare il lavoro su PACA per il repo homelab (progetto PACA "Homelab", prefisso HOME) — ID stabili, priorità, stati, epic, sottotask, branch/PR e piani approvati → epic.
when_to_use: Usala proattivamente ogni volta che in questo repo si trova un bug, si prende una decisione, si implementa un fix, si apre un branch/PR, o si approva un piano con ExitPlanMode — non solo quando l'utente nomina PACA. Anche per "aggiorna le task", "è aggiornato PACA?", "che priorità ha X".
---

# PACA per homelab

Generata il 2026-10-19 con `paca-project-bootstrap`. Lezioni generali complete:
`~/.claude/skills/paca-project-bootstrap/references/lessons-learned.md` — questa
skill ne contiene le regole applicate a questo progetto. Se qualcosa qui
diverge dal comportamento reale dei tool, vince il tool (e aggiorna questa skill).

## 1. MCP

Per questo repo i tool sono `mcp__paca-homelab__*`: server `paca-homelab` a scope
**local** del repo (in `~/.claude.json`, mai nel repo), legato al progetto Homelab con
`PACA_PROJECT_ID`. Il server `paca` a scope user è legato a Trimind: non usarlo
per Home, risponde "single-project agent mode".

- L'identità MCP è un **agent** (`53847204-5b98-4158-8e1a-ffc09280470c`), non
  l'utente `@claude`. Va aggiunto al progetto dalla pagina **Agents**, non da
  Team, con un ruolo di scrittura. Sintomi: `403 insufficient permissions` su
  tutto e `member not found (404)` su `get_my_project_permissions`.
- Tool mancanti o parziali → riavvia la sessione (la lista si carica solo
  all'avvio). Dopo ogni cambio di config MCP serve un riavvio.
- Non serve il bridge ACP per il tracking. API key e token del bridge non vanno
  mai scritti nel repo né stampati.

## 2. ID stabili (verificati 2026-10-19)

Progetto **Homelab**: `cd2189af-87bb-45c1-8272-03a82b5f16ce` · prefisso task `HOME`
· repo `gorlix/homelab` collegato (branch `main`, webhook attivo).

**Tipi**
| Tipo | ID |
|---|---|
| Task (default) | `e2281b13-87e5-4e62-bcd9-74c24f8d04ff` |
| Bug | `58f14d78-6dae-40cf-8cb9-a536a510445f` |
| Story | `cac8093a-5149-40d6-b572-b8ebf2115840` |
| Epic | `295ce9f5-185e-4ee3-8835-9b44361baae0` |

**Stati** (ordine board)
| Pos | Stato | ID | Categoria |
|---|---|---|---|
| 1 | 📥 Backlog (default) | `19c17abf-6b31-44d6-a3ea-398c5573b629` | backlog |
| 2 | 📋 Todo | `31ce7b56-b983-4240-8f2f-fdab339be8e4` | todo |
| 3 | 🔧 In Progress | `cb9bba50-49f6-48b0-a436-cb61b3be38fa` | inprogress |
| 4 | ⏸️ Waiting | `ce33b0c3-7179-4798-acb7-811a7b0caa29` | inprogress |
| 5 | ✅ Done | `a84cec19-1125-45c6-abaf-4455ed5879f8` | done |

**Epic categoria** (permanenti — parent di default)
| Epic | ID (numero) | Quando |
|---|---|---|
| 🔴 Bug e incidenti | `2b875f4d-6524-46ba-8b39-a3b92d58fd52` (HOME-1) | Guasti e regressioni sui servizi |
| 🧹 Debito tecnico e pulizia | `94a62ccd-958f-4512-9124-dad810ecdd14` (HOME-2) | Drift repo/realtà, doc disallineata, cleanup |
| 🟡 Decisioni aperte | `91aca227-b435-433a-abd0-583a4b15b844` (HOME-3) | Scelte ancora da prendere (adguardhome-sync, VRRP) |
| 📚 Documentazione | `f58357c3-7ad7-4bcd-8b93-dff1553efb88` (HOME-4) | ADR-003/004, MkDocs + Pages, README |
| 🏠 Region A IaC | `fab76618-72a8-47f4-a621-f2bb2cd25050` (HOME-5) | OpenTofu/Ansible/compose per hp-laptop e thinkcentre |
| ☸️ Kubernetes + Flux | `fe8153a5-1cea-4e49-bd39-fd69b5f58998` (HOME-6) | Cluster k8s in GitOps |

Nuovo lavoro che non rientra in nessuna epic: crea il task sotto l'epic più
vicina e, se ne nasce un filone ricorrente, proponi una nuova epic categoria.
Per CI su GitHub Actions e backup/resilienza non esiste ancora un'epic: oggi
vanno sotto Debito tecnico e pulizia (HOME-2).

Un ID dà 404 o un numero punta a un task che "parla d'altro" → il progetto
potrebbe essere stato ricreato: rifai discovery (`list_projects` →
`list_task_types` → `list_task_statuses`), verifica i numeri con
`get_task_by_number`, aggiorna questa tabella. Dopo lunghi intervalli senza
toccare PACA, un `get_project` di controllo prima di fidarti.

## 3. Disciplina di tracking (sempre)

1. Bug/decisione → task subito: tipo, parent epic (§2), `importance` (§4),
   `storyPoints` (§4), descrizione con sintomo, causa `file:riga`, effetto, fix.
2. Inizi a lavorarci → `🔧 In Progress`.
3. Finito → commento: file toccati, test, commit hash, **deployato sì/no**
   (sul nodo reale, non solo nel repo). `✅ Done` solo se concluso e confermato;
   altrimenti resta aperto con commento su cosa manca.
4. Risposta a una domanda aperta → commento sul task esistente, niente duplicati.
5. Lavoro pianificato ma non tracciato → crealo appena te ne accorgi.
6. Superato → commento + `✅ Done`; `delete_task` solo per duplicati creati per errore.
7. Lingua di titoli/descrizioni/commenti: **italiano**.
8. Niente segreti, IP pubblici, MAC o token in titoli, descrizioni e commenti:
   il repo è pubblico e il progetto PACA va trattato con la stessa attenzione.

## 4. Priorità e stima

`importance` è un intero; la UI lo mostra per fasce. Valori da usare:

| Fascia | Valore | Criterio in questo progetto |
|---|---|---|
| Critical | 150 | Servizio in produzione giù o dati a rischio, segreto esposto |
| High | 75 | Servizio degradato, o blocca altro lavoro sull'infrastruttura |
| Medium | 35 | Miglioria o feature pianificata (nuovo servizio, nuovo ADR) |
| Low | 10 | Rifinitura/nice-to-have (tag `someday` se "un giorno") |
| None | 0 | Non ancora triagiato. Le epic restano a 0 |

Escalation = alza il valore + commento, mai duplicato.

`storyPoints` alla creazione (Fibonacci): 1 banale · 2 piccolo · 3 moderato ·
5 cross-cutting (più nodi o servizi) · 8 grosso/incerto · 13 → valuta un'epic.

**Tag ammessi** (non inventarne altri senza aggiungerli qui):
| Tag | Quando |
|---|---|
| `someday` | Idea utile ma senza scadenza |
| `security` | Segreti, esposizione pubblica, hardening |
| `plan` | Sottotask nati da un piano approvato (§7) |

## 5. Stati — ciclo di vita

```
📥 Backlog → 📋 Todo → 🔧 In Progress → ✅ Done
                          ↕
                       ⏸️ Waiting
```
`⏸️ Waiting` = bloccato su qualcosa di esterno: hardware, tempo di attesa, una
decisione, la rete della Region B (gestita da terzi). Commento con **cosa**
si aspetta e da quando. Non c'è un cliente: niente "Client Review".
Parent riflette il figlio più indietro; parent Done solo con tutti i figli Done.

## 6. Epic e sottotask

- Epic categoria (§2): permanenti, mai chiuse.
- Epic di round: ≥3 punti dalla stessa fonte con scadenza comune →
  `<Argomento> — N punti (YYYY-MM-DD)`, chiusa a consegna.
- Gerarchia max: Epic → Task/Bug/Story → Sottotask.

## 7. Piani approvati → PACA

Piano ExitPlanMode **approvato** → prima di toccare file: ≥3 step = epic
`<Titolo> — piano (YYYY-MM-DD)` con un sottotask per step (descrizione = lo step),
primo `🔧 In Progress`, altri `📋 Todo`, importance+storyPoints per
step, tag `plan`. <3 step = un task sotto l'epic categoria. Piano cambiato →
aggiorna i sottotask, non creare una seconda epic.

## 8. Branch, PR e autolink (GitHub)

Repo `gorlix/homelab` collegato via plugin GitHub (`com.paca.github`).
- Naming branch **obbligatorio** quando si usa un branch: `<tipo>/HOME-<n>-slug`
  (es. `feat/HOME-12-mkdocs`). È l'unico aggancio branch/PR ↔ task (pattern
  matching sul nome).
- Il webhook aggancia anche `git push` / `gh` puri.
- `github_create_pull_request` linka già: non richiamare `github_link_pr_to_task`
  dopo. Serve solo per PR con branch fuori pattern.
- 404/403 sui tool del plugin → verifica integrazione `connected` e repo linkato
  prima di incolpare il naming. Il token GitHub lo fornisce Ale (non risulta
  ancora impostato: `github_get_integration` non mostra uno stato di connessione).
- Review/commenti via plugin restano su GitHub: se servono in PACA,
  `add_task_comment`.
- Base branch: `main` (non protetto, nessuna CI su GitHub per ora). Fix piccoli
  e docs vanno direttamente su `main` con `HOME-<n>` nel messaggio di commit;
  cambi grossi o rischiosi (nuove LXC, modifiche OpenTofu su risorse con dati,
  ADR) passano da branch + PR. I PR di Renovate restano come sono.

## 9. Regole del progetto per agenti e subagent

Dal `CLAUDE.md` del repo (leggerlo, è la fonte):
- **Regola d'oro:** prima di ogni commit l'autore deve poter spiegare il file
  riga per riga. Config complesse vanno accompagnate dal *perché*, non solo dal
  *cosa*.
- **OpenTofu su LXC con dati (ADR-010):** prima di ogni `apply`, `plan` e ricerca
  di `forces replacement` per ogni container; se c'è, dump verificato fuori
  dalla LXC. Mai dichiarare "in-place" senza averlo visto nel plan. Non togliere
  mai `ignore_changes = [mount_point]` senza aver riletto il plan. Se un `apply`
  fallisce, Tofu stampa le chiavi SSH: chiedere solo le ultime righe e rieseguire
  il deploy con `infrastructure/ansible/run.sh`.
- **Segreti:** nessun valore in chiaro nel repo, solo `op://` o Infisical.
  Attenzione ai segreti impliciti (IP pubblici, MAC, coordinate, serial).
- **Documentazione:** italiano, niente emoji (README, ADR, doc, diagrammi).
  Questa skill e i nomi su PACA sono l'eccezione, perché non sono doc del repo.
- **Commit:** Conventional Commits; se l'AI è stata sostanziale nella stesura,
  segnalarlo (`docs(adr): draft AI-assisted, reviewed and edited by author`).
  Si committa solo se Ale lo chiede.
- Il working tree può avere modifiche non committate di altro lavoro: non
  includerle nei commit di un task che non le riguarda.
- Prima di toccare infrastruttura reale via MCP (Proxmox, Authentik, Cloudflare)
  vedi la skill `MCP-homelab`.

Delegando a subagent: segui la skill `multi-agent` e copia nel prompt queste
regole + gli ID di §2 necessari.

## 10. Note e incidenti di questo progetto

- **2026-10-19 — bootstrap.** L'MCP globale `paca` (scope user) era fissato a
  Trimind con `PACA_PROJECT_ID`; per questo `create_project` e ogni chiamata su
  Home davano errore. Soluzione: server `paca-homelab` a scope local con un
  agent dedicato a Home, aggiunto dalla pagina Agents del progetto.
- Il nome del progetto su PACA era "Home" al bootstrap; rinominato in "Homelab" il 2026-10-19. Il prefisso resta `HOME` e l'ID non cambia.
- Il task HOME-7 ("Bootstrap skill PACA") traccia la creazione di questa skill.

(Aggiungi qui ogni nuova lezione specifica, con data. Le lezioni valide per
tutti i progetti vanno anche in `~/.claude/skills/paca-project-bootstrap/references/lessons-learned.md`.)

---
aliases:
  - ADR-000
  - Metodologia AI
tags:
  - adr
  - meta
  - processo
status: accettato
date: 2026
---

# ADR-000: Metodologia di lavoro e uso di strumenti AI

| | |
|---|---|
| **Stato** | ✅ Accettato |
| **Data** | 2026 |
| **Tipo** | Meta-ADR (processo, non infrastruttura) |

## Contesto

Questo repository è pubblico e ha, dichiaratamente, anche uno scopo di portfolio tecnico. È quindi giusto essere trasparenti su **come** è stato prodotto, non solo su cosa contiene.

Nella stesura di documentazione (README, ADR, guide) e, in alcuni casi, come supporto alla progettazione di configurazioni, ho utilizzato Claude (Anthropic) come strumento di lavoro. È un fatto rilevante da dichiarare esplicitamente, per due ragioni:

1. Nasconderlo sarebbe disonesto verso chiunque legga questo repository per valutare le mie competenze (recruiter, colleghi, altri homelabber).
2. Non dichiararlo bene rischierebbe l'effetto opposto: far sembrare superficiale un lavoro che, nel merito tecnico, non lo è.

Il rischio reale non è "aver usato uno strumento AI" — nel 2026 è normale e diffuso — ma **pubblicare qualcosa che non saprei spiegare o difendere** se qualcuno me lo chiedesse in un colloquio o in una issue.

## Decisione

Distinguo esplicitamente due ambiti, con due livelli di responsabilità diversi:

**1. Documentazione (README, ADR, guide in `docs/`)**
Uso l'AI liberamente come assistente di scrittura e struttura: mi aiuta a organizzare i contenuti, a mantenere un formato coerente (es. il formato ADR stesso), a scrivere in modo chiaro. Il contenuto tecnico — le decisioni, i motivi, i trade-off descritti — è mio: viene da scelte reali fatte sul mio homelab, non generato.

**2. Configurazione reale (Terraform, Ansible, Docker Compose, manifest Kubernetes)**
Qui vale una regola più stretta: **ogni file pubblicato in questo repository è stato letto, capito e testato da me prima del commit**, indipendentemente da come è nata la prima bozza. Non pubblico configurazioni che non saprei spiegare riga per riga.

Regola pratica che mi do — il test prima di ogni commit:

> *Se qualcuno mi chiedesse "perché hai configurato questa cosa così, cosa succede se fallisce X", saprei rispondere senza guardare il file?*

Se sì → pubblico. Se no → prima capisco davvero, poi pubblico.

**Tracciabilità nei commit.** Dove l'assistenza AI è stata sostanziale nella stesura di un documento, lo segnalo nel messaggio di commit, ad esempio:

```
docs(adr): draft AI-assisted, reviewed and edited by author
```

Non lo faccio per ogni singola riga (sarebbe rumore inutile), ma per i documenti principali, così la cronologia stessa del repository resta onesta.

## Alternative considerate

| Alternativa | Perché scartata |
|---|---|
| **Non dichiarare nulla** | Rischio reputazionale maggiore del beneficio: se emerge senza contesto (es. in un colloquio), sembra reticenza piuttosto che normalità. |
| **Disclaimer generico tipo "contenuti generati con AI"** | Poco informativo, non distingue tra documentazione e infrastruttura, e non comunica la review effettiva fatta sul contenuto. |
| **Evitare del tutto strumenti AI** | Scelta legittima in astratto, ma non riflette il mio workflow reale né le pratiche ormai comuni nel settore; sarebbe una dichiarazione poco credibile quanto il suo opposto. |

## Conseguenze

> [!TIP] Positive
> - Trasparenza che si trasforma in un segnale positivo: mostra consapevolezza del proprio processo di lavoro, non solo del risultato finale.
> - Il repository resta a prova di domanda diretta: qualunque configurazione pubblicata, la so spiegare.
> - Stabilisce un criterio oggettivo (il "test prima del commit") applicabile a ogni contributo futuro, mio o di eventuali collaboratori.

> [!WARNING] Da tenere presente
> - Richiede disciplina reale: la tentazione di pubblicare qualcosa "che funziona" senza averlo davvero capito esiste, e questo ADR è anche un promemoria a me stesso.
> - Se in futuro accetterò contributi esterni, andrà chiarito se questa stessa regola si applica anche a chi contribuisce dall'esterno (probabile: sì).

## Riferimenti

- Questo stesso repository, come caso applicato del principio sopra descritto.

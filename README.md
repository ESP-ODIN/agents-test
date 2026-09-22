# student_deals_watcher

Agent local de veille des **bons plans étudiants**.  
Il surveille Dealabs et UNiDAYS, filtre les offres pertinentes, et t’envoie un email à chaque nouveauté.

**Langage :** Bash (shell Unix) — script `watcher.sh`.  
Dépendances système : `curl`, `grep`, `sed`, `awk`. Config en TOML (`agent.toml`).

100 % gratuit, exécutable en local et planifiable avec `cron`.

## Fonctionnement

1. Lit la config `agent.toml`
2. Interroge :
   - les flux RSS Dealabs (`/rss/tous`, `/rss/hot`)
   - les pages de recherche Dealabs (`q=etudiant`)
   - les pages UNiDAYS FR (nouveautés + accueil)
3. Filtre par mots-clés (sauf UNiDAYS, déjà 100 % étudiant)
4. Déduplique via `seen_deals.json` (pas de doublons)
5. Envoie un mail via **Gmail SMTP** vers ton adresse Epitech

## Prérequis

- macOS / Linux
- `bash`, `curl`, `grep`, `sed`, `awk`
- un compte **@gmail.com** avec la validation en 2 étapes
- un [mot de passe d’application Google](https://myaccount.google.com/apppasswords)

> L’envoi SMTP direct depuis un compte Epitech / Microsoft 365 est souvent bloqué (`Login denied`).  
> D’où l’envoi **depuis Gmail**, réception sur `shirel.sabbah@epitech.eu`.

## Installation

```bash
cd agents-test
cp .env.example .env
```

Édite `.env` :

```bash
# Obligatoire : une vraie adresse @gmail.com (pas @epitech.eu)
GMAIL_ADDRESS=toncompte@gmail.com
GMAIL_APP_PASSWORD=xxxx xxxx xxxx xxxx
```

Les espaces dans le mot de passe d’application sont acceptés.

Le destinataire se configure dans `agent.toml` (`[email] to = ...`).

## Utilisation

```bash
# Test sans envoyer de mail ni écrire seen_deals.json
./watcher.sh --dry-run

# Vraie passe (envoie les mails)
./watcher.sh
```

Au **premier** run réel, tu peux recevoir beaucoup de mails (historique Dealabs + UNiDAYS).  
Ensuite, seules les **nouvelles** offres sont envoyées.

## Planification (cron)

Vérification toutes les heures :

```bash
crontab -e
```

```
0 * * * * cd /chemin/vers/agents-test && ./watcher.sh >> watcher.log 2>&1
```

Le script charge `.env` automatiquement.

## Configuration (`agent.toml`)

| Section | Rôle |
|---------|------|
| `[source] rss_feeds` | Flux RSS Dealabs |
| `[source] search_pages` | Pages de recherche Dealabs |
| `[source] unidays_pages` | Pages UNiDAYS FR |
| `[source] keywords` | Mots-clés (Dealabs / RSS) |
| `[trigger] poll_interval_minutes` | Intervalle indicatif (cron) |
| `[trigger] dedup_store` | Fichier anti-doublons |
| `[email]` | SMTP Gmail + destinataire |

Ajoute / retire des sources ou mots-clés directement dans ce fichier.

## Fichiers

```
agent.toml       # config (sources, mots-clés, email)
watcher.sh       # script principal
.env             # secrets Gmail (ne pas committer)
.env.example     # modèle
seen_deals.json  # offres déjà vues (créé au 1er envoi)
watcher.log      # logs cron (optionnel)
```

## Dépannage

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| `Login denied` | Adresse non-Gmail ou mauvais mot de passe | `GMAIL_ADDRESS` = `@gmail.com` + mot de passe d’**application** |
| `tvjz: command not found` | Espaces mal lus dans `.env` | Mettre le mot de passe entre guillemets, ou relancer (le script gère les espaces) |
| `0 nouvelle(s) offre(s)` sur les RSS | Aucune offre « étudiant » dans le top Dealabs | Normal ; les `search_pages` et UNiDAYS prennent le relais |
| Beaucoup de mails d’un coup | Premier run | Attendu ; ensuite `seen_deals.json` filtre |
| SMTP Epitech refusé | Tenant Microsoft bloque SMTP AUTH | Garder Gmail en envoi (config actuelle) |

## Licence

Usage personnel / scolaire.

# ODIN — fixtures de test du pipeline de sécurité

Agents de test **inertes** qui doivent être rejetés (ou signalés comme douteux) par le pipeline de sécurité ODIN, plus un agent propre qui doit passer. Le principe est celui du fichier de test EICAR : ça ressemble à quelque chose de dangereux pour les scanners, mais rien ne fait de mal.

## Agent de base

`weather-digest` : un agent qui renvoie un résumé météo statique (pas d'appel réseau, pour que le smoke test soit déterministe).

- `GET /health` → `{"status": "ok"}` (utilisé par le healthcheck Docker et l'étape 4)
- `GET /digest` → résumé météo
- Python 3.12-slim, utilisateur non-root, port 8080

Chaque fixture = `base/` + la surcouche de `variants/<nom>/`.

## Les fixtures

| Fixture | Étape visée | Outil | Résultat attendu |
|---|---|---|---|
| `00-clean` | — | tous | **validé** (sinon faux positif) |
| `01-bad-manifest` | 1. Normalisation | validation du schéma | rejeté |
| `02-eicar` | 3. Analyse | ClamAV | rejeté |
| `03-leaked-secrets` | 3. Analyse | gitleaks | rejeté |
| `04-risky-code` | 3. Analyse | Bandit + semgrep | rejeté / douteux |
| `05-overreach` | 3. Analyse | règle manifeste **à écrire** | douteux |
| `06-smoke-fail` | 4. Smoke test | healthcheck < 30 s | rejeté |

Le détail (raisons, outil, étape d'arrêt) est dans `expected-results.json`, lisible par un test automatisé.

## Pourquoi c'est inerte

- **02** : la chaîne EICAR standard, reconnue comme test par tous les antivirus.
- **03** : clés générées à partir d'un hash, au bon format pour les règles gitleaks par défaut (AWS, GitHub PAT, Anthropic), mais inventées.
- **04** : le blob base64 vaut `print("odin-test-fixture")` ; l'URL d'« exfiltration » utilise le TLD réservé `.invalid` (RFC 6761) qui ne résout jamais, et la fonction n'est jamais appelée ; la commande shell est un `echo` fixe.
- **05** : les permissions sont déclarées mais jamais utilisées.

## Construire

```bash
python build.py          # dist/<fixture>/
python build.py --tar    # + dist/<fixture>.tar.gz à publier via la CLI / l'API
```

02 et 03 sont **générés au build** et ne sont jamais commités : sinon GitHub push protection et les antivirus des postes de l'équipe les bloqueraient. Gardez `dist/` dans le `.gitignore`.

## Points d'attention pour le pipeline

1. **`05-overreach` n'est détecté par aucun des 4 outils actuels.** gitleaks, semgrep, Bandit et ClamAV analysent le code, pas le sens du manifeste. Il faut une règle maison à l'étape 1 ou 3 (par ex. plafonds CPU/mémoire, liste de standards MCP autorisés, permissions `admin`/`execute`/`delete` → douteux).
2. **Bandit signale le contrôle propre (B104, bind sur `0.0.0.0`)**, alors que c'est obligatoire dans un conteneur. Le code de base l'annote avec `# nosec B104`. Décision à prendre : est-ce que le pipeline fait confiance aux `# nosec` des auteurs ? Si oui, un attaquant peut aussi en mettre. Bonne idée de fixture ciblée pour plus tard.
3. **Normalisation** : `01-bad-manifest` accumule plusieurs erreurs. Pour savoir quelle règle marche, il faudra plus tard un manifeste par erreur.
4. **Sandbox (étape 5)** : simulé au MVP. Le motif d'exfiltration de `04` est le candidat naturel pour la V2 (CAPEv2 doit voir la tentative DNS vers `exfil.example.invalid`).

## Vérifié

- Tous les manifestes (`manifest.toml`) sont du TOML valide, tout le code Python compile. `01-bad-manifest` est du TOML correct mais au contenu invalide : il teste la validation du schéma, pas le parseur.
- Bandit : `00-clean` sans alerte ; `04-risky-code` → B102 (exec), B310 (urlopen), B602/B607 (shell=True), B404.
- Les secrets de `03` correspondent aux regex gitleaks par défaut (aws-access-token, github-pat, anthropic-api-key). Le binaire gitleaks n'a pas pu être lancé ici : à confirmer en vrai.
- Non testés ici : ClamAV, semgrep, le build Docker et le smoke test.

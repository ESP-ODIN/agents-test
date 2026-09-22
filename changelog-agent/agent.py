"""Changelog Agent : génère un CHANGELOG.md à partir de l'historique git local."""
import argparse
import os
import subprocess
import sys
from pathlib import Path

from google import genai
from google.genai import types

MODEL = "gemini-3.6-flash"  # à adapter selon les modèles visibles dans Google AI Studio

SYSTEM_PROMPT = (
    "Tu rédiges des changelogs clairs et concis, en Markdown, "
    "groupés par sections : Ajouts / Corrections / Autres."
)


def load_env_file() -> None:
    """Charge un fichier .env (dossier courant, puis dossier de l'agent) sans écraser l'existant."""
    for path in (Path.cwd() / ".env", Path(__file__).resolve().parent / ".env"):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def get_git_log(n: int) -> str:
    try:
        result = subprocess.run(
            ["git", "log", f"-{n}", "--pretty=format:%h %s (%an, %ad)", "--date=short"],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        sys.exit("Erreur : git n'est pas installé.")
    except subprocess.CalledProcessError as e:
        sys.exit(f"Erreur : ce dossier n'est pas un dépôt git valide.\n{e.stderr.strip()}")
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description="Génère un CHANGELOG.md depuis git log")
    parser.add_argument("--task", default="Génère un changelog", help="Consigne donnée au LLM")
    parser.add_argument("--commits", type=int, default=30, help="Nombre de commits à lire")
    parser.add_argument("--output", default="CHANGELOG.md", help="Fichier de sortie")
    parser.add_argument("--dry-run", action="store_true", help="Affiche le plan sans rien exécuter")
    args = parser.parse_args()

    if args.dry_run:
        print("[dry-run] Actions prévues :")
        print(f"  - lire les {args.commits} derniers commits (git log)")
        print(f"  - envoyer ces commits à Gemini ({MODEL})")
        print(f"  - écrire le résultat dans {args.output}")
        return

    load_env_file()
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        sys.exit("Erreur : la variable d'environnement GEMINI_API_KEY n'est pas définie.")

    log = get_git_log(args.commits)
    if not log.strip():
        sys.exit("Aucun commit trouvé.")

    client = genai.Client(api_key=api_key)
    response = client.models.generate_content(
        model=MODEL,
        contents=f"{args.task}\n\nCommits :\n{log}",
        config=types.GenerateContentConfig(system_instruction=SYSTEM_PROMPT),
    )

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(response.text)

    tokens = response.usage_metadata.total_token_count if response.usage_metadata else "?"
    print(f"{args.output} généré ({tokens} tokens utilisés)")


if __name__ == "__main__":
    main()

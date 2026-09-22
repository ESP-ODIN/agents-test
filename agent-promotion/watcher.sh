#!/usr/bin/env bash
# Veilleur local de bons plans étudiants (Bash + cron, sans Python).
# Lit agent.toml, interroge les flux RSS, filtre par mots-clés,
# déduplique via seen_deals.json, envoie un mail Gmail (curl SMTP).
#
# Usage :
#   cp .env.example .env   # puis édite GMAIL_ADDRESS / GMAIL_APP_PASSWORD
#   ./watcher.sh           # une passe
#   ./watcher.sh --dry-run # sans envoyer ni écrire seen_deals.json
#
# Cron (toutes les heures) — crontab -e :
#   0 * * * * cd /chemin/vers/agents-test/agent-promotion && ./watcher.sh >> watcher.log 2>&1

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${ROOT}/agent.toml"
TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

# Charge .env sans `source` (gère espaces / guillemets dans les valeurs)
load_env_file() {
  local file="$1" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # ignore commentaires / lignes vides
    case "$line" in
      ''|\#*) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    # retire guillemets éventuels
    val=${val#\"}
    val=${val%\"}
    val=${val#\'}
    val=${val%\'}
    # mot de passe d'application Google : les espaces sont décoratifs
    if [ "$key" = "GMAIL_APP_PASSWORD" ]; then
      val=${val// /}
    fi
    export "$key=$val"
  done <"$file"
}

load_env_file "${ROOT}/.env"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Commande requise introuvable : $1" >&2
    exit 1
  }
}

need curl
need grep
need sed
need awk
need tr
need base64

[ -f "$CONFIG" ] || { echo "Config introuvable : $CONFIG" >&2; exit 1; }

toml_scalar() {
  local key="$1"
  awk -v k="$key" '
    $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      gsub(/^"/, "", line)
      gsub(/"$/, "", line)
      print line
      exit
    }
  ' "$CONFIG"
}

# Écrit chaque élément d'un tableau TOML string dans un fichier (une ligne / entrée)
toml_string_array_to_file() {
  local key="$1"
  local out="$2"
  : >"$out"
  awk -v k="$key" '
    BEGIN { inarr = 0 }
    $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") { inarr = 1 }
    inarr {
      n = split($0, parts, "\"")
      # parts impairs = hors quotes, pairs = contenu quoté (si split sur ")
      # "a","b" -> empty, a, ,, b, ...
      for (i = 2; i <= n; i += 2) {
        if (parts[i] != "") print parts[i]
      }
      if (index($0, "]")) exit
    }
  ' "$CONFIG" >>"$out"
}

DEDUP_STORE="$(toml_scalar dedup_store)"
DEDUP_STORE="${DEDUP_STORE:-seen_deals.json}"
SEEN_FILE="${ROOT}/${DEDUP_STORE}"
MAIL_TO="$(toml_scalar to)"
SMTP_HOST="$(toml_scalar smtp_host)"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="$(toml_scalar smtp_port)"
SMTP_PORT="${SMTP_PORT:-587}"

FEEDS_FILE="${TMPDIR_RUN}/feeds.txt"
SEARCH_FILE="${TMPDIR_RUN}/search.txt"
UNIDAYS_FILE="${TMPDIR_RUN}/unidays.txt"
KEYWORDS_FILE="${TMPDIR_RUN}/keywords.txt"
toml_string_array_to_file rss_feeds "$FEEDS_FILE"
toml_string_array_to_file search_pages "$SEARCH_FILE"
toml_string_array_to_file unidays_pages "$UNIDAYS_FILE"
toml_string_array_to_file keywords "$KEYWORDS_FILE"

if [ ! -s "$FEEDS_FILE" ] && [ ! -s "$SEARCH_FILE" ] && [ ! -s "$UNIDAYS_FILE" ]; then
  echo "Aucune source (rss_feeds / search_pages / unidays_pages) dans agent.toml" >&2
  exit 1
fi
if [ ! -s "$KEYWORDS_FILE" ]; then
  echo "Aucun mot-clé dans agent.toml" >&2
  exit 1
fi

if [ -z "$MAIL_TO" ]; then
  echo "Destinataire 'to' manquant dans agent.toml" >&2
  exit 1
fi
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "${GMAIL_ADDRESS:-}" ]; then
    echo "Exporte GMAIL_ADDRESS ou mets-le dans .env" >&2
    exit 1
  fi
  if [ -z "${GMAIL_APP_PASSWORD:-}" ]; then
    echo "Exporte GMAIL_APP_PASSWORD ou mets-le dans .env" >&2
    exit 1
  fi
fi

SEEN_TMP="${TMPDIR_RUN}/seen.txt"
: >"$SEEN_TMP"
if [ -f "$SEEN_FILE" ]; then
  grep -o '"[^"]*"' "$SEEN_FILE" 2>/dev/null | sed 's/^"//;s/"$//' >"$SEEN_TMP" || true
fi

is_seen() {
  grep -Fxq -- "$1" "$SEEN_TMP" 2>/dev/null
}

mark_seen() {
  printf '%s\n' "$1" >>"$SEEN_TMP"
}

save_seen() {
  local out="${TMPDIR_RUN}/seen.json"
  {
    echo "["
    if [ -s "$SEEN_TMP" ]; then
      sort -u "$SEEN_TMP" | sed 's/"/\\"/g; s/.*/  "&",/' | sed '$ s/,$//'
    fi
    echo "]"
  } >"$out"
  mv "$out" "$SEEN_FILE"
}

decode_xml() {
  sed -e 's/<!\[CDATA\[//g' -e 's/\]\]>//g' \
      -e 's/<[^>]*>//g' \
      -e 's/&lt;/</g' -e 's/&gt;/>/g' \
      -e 's/&amp;/\&/g' -e 's/&quot;/"/g' \
      -e "s/&#39;/'/g" -e "s/&apos;/'/g" \
      -e 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

matches_keywords() {
  local text="$1"
  local lower kw kl
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r kw || [ -n "$kw" ]; do
    [ -z "$kw" ] && continue
    kl=$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *"$kl"*) return 0 ;;
    esac
  done <"$KEYWORDS_FILE"
  return 1
}

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

send_mail() {
  local title="$1" description="$2" url="$3"
  local emlf="${TMPDIR_RUN}/mail.eml"
  local subject="Nouveau bon plan etudiant : ${title}"

  {
    printf 'From: %s\r\n' "$GMAIL_ADDRESS"
    printf 'To: %s\r\n' "$MAIL_TO"
    printf 'Subject: =?UTF-8?B?%s?=\r\n' "$(b64 "$subject")"
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: text/plain; charset=UTF-8\r\n'
    printf 'Content-Transfer-Encoding: 8bit\r\n'
    printf '\r\n'
    printf '%s\n\n%s\n\nLien : %s\n' "$title" "$description" "$url"
  } >"$emlf"

  # Gmail : SMTP + STARTTLS sur 587 (ou smtps://:465)
  curl -sS --url "smtp://${SMTP_HOST}:${SMTP_PORT}" --ssl-reqd \
    --mail-from "$GMAIL_ADDRESS" \
    --mail-rcpt "$MAIL_TO" \
    --user "${GMAIL_ADDRESS}:${GMAIL_APP_PASSWORD}" \
    -T "$emlf" >/dev/null
}

emit_deal() {
  local title="$1" description="$2" url="$3" uid="$4"
  [ -z "$uid" ] && uid="$url"
  [ -z "$uid" ] && return 0
  if is_seen "$uid"; then
    return 0
  fi
  echo "  • $title"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run : email non envoyé)"
  else
    send_mail "$title" "$description" "$url"
    echo "    email envoyé."
  fi
  mark_seen "$uid"
  return 0
}

process_feed() {
  local feed_url="$1"
  local raw="${TMPDIR_RUN}/feed.xml"
  local items="${TMPDIR_RUN}/items.txt"

  echo "→ flux : $feed_url"
  if ! curl -fsSL --max-time 30 \
      -A "Mozilla/5.0 (compatible; student_deals_watcher/1.0)" \
      -o "$raw" "$feed_url"; then
    echo "  ⚠ téléchargement échoué" >&2
    return 0
  fi

  if ! grep -q '<item' "$raw"; then
    echo "  ⚠ aucun <item> (flux vide ou HTML/erreur)" >&2
    return 0
  fi

  tr '\n' ' ' <"$raw" \
    | sed 's/<item/\n<item/g' \
    | grep '^<item' >"$items" || true

  local count=0
  local item title link desc uid haystack

  while IFS= read -r item || [ -n "$item" ]; do
    [ -z "$item" ] && continue

    title=$(printf '%s' "$item" | sed -n 's/.*<title[^>]*>\(.*\)<\/title>.*/\1/p' | head -1 | decode_xml)
    link=$(printf '%s' "$item" | sed -n 's/.*<link[^>]*>\(.*\)<\/link>.*/\1/p' | head -1 | decode_xml)
    desc=$(printf '%s' "$item" | sed -n 's/.*<description[^>]*>\(.*\)<\/description>.*/\1/p' | head -1 | decode_xml)
    uid=$(printf '%s' "$item" | sed -n 's/.*<guid[^>]*>\(.*\)<\/guid>.*/\1/p' | head -1 | decode_xml)
    [ -z "$uid" ] && uid="$link"
    [ -z "$uid" ] && uid="$title"
    [ -z "$uid" ] && continue

    haystack="${title} ${desc} ${link}"
    if ! matches_keywords "$haystack"; then
      continue
    fi

    if ! is_seen "$uid"; then
      emit_deal "$title" "$desc" "$link" "$uid"
      count=$((count + 1))
    fi
  done <"$items"

  echo "  → $count nouvelle(s) offre(s) sur ce flux."
}

# Pages de recherche Dealabs (HTML) : extrait les liens /bons-plans/
slug_to_title() {
  local slug="$1"
  slug=$(printf '%s' "$slug" | sed -E 's/-[0-9]+$//')
  printf '%s' "$slug" | tr '-' ' '
}

process_search_page() {
  local page_url="$1"
  local raw="${TMPDIR_RUN}/search.html"
  local links="${TMPDIR_RUN}/links.txt"

  echo "→ recherche : $page_url"
  if ! curl -fsSL --max-time 30 \
      -A "Mozilla/5.0 (compatible; student_deals_watcher/1.0)" \
      -o "$raw" "$page_url"; then
    echo "  ⚠ téléchargement échoué" >&2
    return 0
  fi

  grep -oE 'https://www\.dealabs\.com/bons-plans/[a-z0-9-]+-[0-9]+' "$raw" \
    | sort -u >"$links" || true

  if [ ! -s "$links" ]; then
    echo "  ⚠ aucune offre trouvée sur la page" >&2
    return 0
  fi

  local count=0 link slug title uid
  while IFS= read -r link || [ -n "$link" ]; do
    [ -z "$link" ] && continue
    slug=${link##*/}
    title=$(slug_to_title "$slug")
    uid="$link"

    # La page est déjà filtrée "étudiant" ; on garde quand même le filtre mots-clés
    # sur le slug (souvent contient etudiant / etudiants).
    if ! matches_keywords "$title $link"; then
      continue
    fi

    if ! is_seen "$uid"; then
      emit_deal "$title" "" "$link" "$uid"
      count=$((count + 1))
    fi
  done <"$links"

  echo "  → $count nouvelle(s) offre(s) sur cette recherche."
}

# UNiDAYS : extrait les perks depuis __NEXT_DATA__ (JSON embarqué).
# Pas de filtre mots-clés — tout est déjà étudiant.
process_unidays_page() {
  local page_url="$1"
  local raw="${TMPDIR_RUN}/unidays.html"
  local perks="${TMPDIR_RUN}/unidays_perks.txt"

  echo "→ unidays : $page_url"
  if ! curl -fsSL --max-time 30 \
      -A "Mozilla/5.0 (compatible; student_deals_watcher/1.0)" \
      -o "$raw" "$page_url"; then
    echo "  ⚠ téléchargement échoué" >&2
    return 0
  fi

  # "displayName":"...","type":"perk","url":"https://www.myunidays.com/perks/UUID"
  grep -oE '"displayName":"[^"]+","type":"perk","url":"https://www\.myunidays\.com/perks/[a-f0-9-]+"' "$raw" \
    | sort -u >"$perks" || true

  if [ ! -s "$perks" ]; then
    echo "  ⚠ aucune offre UNiDAYS trouvée" >&2
    return 0
  fi

  local count=0 line title perk_id url uid
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    title=$(printf '%s' "$line" | sed -n 's/.*"displayName":"\([^"]*\)".*/\1/p')
    perk_id=$(printf '%s' "$line" | sed -n 's|.*/perks/\([a-f0-9-]*\)".*|\1|p')
    [ -z "$title" ] || [ -z "$perk_id" ] && continue
    url="https://www.myunidays.com/FR/fr-FR/perks/${perk_id}"
    uid="$url"
    title="UNiDAYS — ${title}"

    if ! is_seen "$uid"; then
      emit_deal "$title" "Offre étudiante UNiDAYS" "$url" "$uid"
      count=$((count + 1))
    fi
  done <"$perks"

  echo "  → $count nouvelle(s) offre(s) UNiDAYS."
}

echo "Agent : student_deals_watcher (bash)"
[ "$DRY_RUN" -eq 1 ] && echo "(mode dry-run)"

if [ -s "$FEEDS_FILE" ]; then
  while IFS= read -r feed || [ -n "$feed" ]; do
    [ -z "$feed" ] && continue
    process_feed "$feed"
  done <"$FEEDS_FILE"
fi

if [ -s "$SEARCH_FILE" ]; then
  while IFS= read -r page || [ -n "$page" ]; do
    [ -z "$page" ] && continue
    process_search_page "$page"
  done <"$SEARCH_FILE"
fi

if [ -s "$UNIDAYS_FILE" ]; then
  while IFS= read -r page || [ -n "$page" ]; do
    [ -z "$page" ] && continue
    process_unidays_page "$page"
  done <"$UNIDAYS_FILE"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  save_seen
else
  echo "→ dry-run : ${DEDUP_STORE} non modifié."
fi

echo "Terminé."

#!/usr/bin/env bash

# Enable strict Bash mode:
# -e: exit on errors
# -u: fail on undefined variables
# -o pipefail: fail if any command in a pipeline fails
set -euo pipefail

################################################################################
# Script: check-sql.sh
#
# Purpose:
#   Validate SQL files changed in a pull request without checking out the repo.
#
# Flow:
#   1. Ensure this runs only for pull_request / pull_request_target.
#   2. List changed PR files through GitHub REST API.
#   3. Keep changed .sql files, excluding removed/renamed files.
#   4. Apply optional path exclusions.
#   5. Exit successfully if no SQL files remain.
#   6. Bypass check for exempt actors or exempt GitHub teams.
#   7. Fetch each SQL file at the PR head SHA.
#   8. Optionally validate UTF-8 BOM.
#   9. Remove comments, quoted strings, and allowed SQL patterns.
#  10. Fail if remaining SQL contains disallowed DROP or ALTER.
#
# Required environment variables:
#   GH_TOKEN       GitHub App token with Contents: read and Members: read.
#   REPOSITORY     Repository in owner/name format.
#   ORG            Repository owner / organization.
#   ACTOR          User or app that triggered the workflow.
#   EVENT_NAME     GitHub event name.
#   PR_NUMBER      Pull request number.
#   PR_HEAD_SHA    Pull request head SHA.
#
# Optional environment variables:
#   EXEMPT_TEAMS    Space-separated team slugs, e.g. "dba ort".
#   EXEMPT_ACTORS   Space-separated actors, e.g. "jenkins-ci[bot]".
#   EXCLUDE_PATHS   Comma-separated regex fragments, e.g. "ignore-sql,test/sql".
#   UTF8_BOM_CHECK  Set to "true" to require UTF-8 BOM.
################################################################################

if [[ "$EVENT_NAME" != "pull_request" && "$EVENT_NAME" != "pull_request_target" ]]; then
  echo "::error::This action is PR-only. Run it from a pull_request workflow."
  exit 1
fi

# Call GitHub REST API and return JSON.
api_get() {
  curl -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

# Fetch raw file content from GitHub.
api_get_raw() {
  curl -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github.raw" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

# URL-encode a repository path for the Contents API.
url_encode_path() {
  jq -rn --arg v "$1" '$v|@uri'
}

# List changed SQL files in the PR.
# Output format:
#   <ref>\t<filename>
#
# The ref is always PR_HEAD_SHA because PR mode validates final PR content.
get_changed_sql_files_pr() {
  local page=1 response count

  while true; do
    response="$(api_get "https://api.github.com/repos/$REPOSITORY/pulls/$PR_NUMBER/files?per_page=100&page=$page")"
    count="$(echo "$response" | jq 'length')"

    [[ "$count" -eq 0 ]] && break

    echo "$response" |
      jq -r --arg ref "$PR_HEAD_SHA" '
        .[]
        | select((.status != "removed") and (.status != "renamed") and (.filename | endswith(".sql")))
        | "\($ref)\t\(.filename)"
      '

    page=$((page + 1))
  done
}

# Fetch a file from the repository at a specific ref/SHA.
fetch_file() {
  local path="$1"
  local ref="$2"
  local encoded_path

  encoded_path="$(url_encode_path "$path")"
  api_get_raw "https://api.github.com/repos/$REPOSITORY/contents/$encoded_path?ref=$ref"
}

# Check whether a file starts with UTF-8 BOM bytes: EF BB BF.
has_utf8_bom() {
  [[ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' ')" == "efbbbf" ]]
}

# Return success if SQL contains disallowed DROP or ALTER after sanitization.
is_sql_file_containing_disallowed_command() {
  local file="$1"

  perl -0777 -pe '
    # Remove block comments: /* ... */
    s|/\*.*?\*/||gis;

    # Remove line comments: -- ...
    s|--.*$||gm;

    # Remove single-quoted strings.
    s|'\''[^'\'']*'\''||g;

    # Allow DROP/ALTER on temp tables.
    s|drop\s*table\s*(\[?dbo\]?\.)?\[?#\w+\]?||gi;
    s|alter\s*table\s*(\[?dbo\]?\.)?\[?#\w+\]?\s*drop||gi;
    s|alter\s*table\s*(\[?dbo\]?\.)?\[?#\w+\]?||gi;

    # Allow GRANT ALTER ON.
    s|grant\s*alter\s*on||gi;

    # Allow known-safe ALTER TABLE forms.
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*ALTER\s*COLUMN||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*ADD\s*CONSTRAINT||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*WITH\s*CHECK\s*ADD\s*CONSTRAINT||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*WITH\s*NOCHECK\s*ADD\s*CONSTRAINT||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*CHECK\s*CONSTRAINT||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*NOCHECK\s*CONSTRAINT||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*DROP\s*CONSTRAINT||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*DISABLE\s*TRIGGER||gis;
    s|ALTER\s*TABLE\s*(\[?dbo\]?\.)?\s*(\[?\w+\]?\.?)+\s*ENABLE\s*TRIGGER||gis;
  ' "$file" | grep -iqE '(^|\s|;)(DROP|ALTER)($|\s|;)'
}

echo "Initiating SQL guard check..."

# Get changed SQL files before doing exemption/team API calls.
mapfile -t entries < <(get_changed_sql_files_pr | sort -u)

# Apply optional path exclusions.
if [[ -n "$EXCLUDE_PATHS" && ${#entries[@]} -gt 0 ]]; then
  exclude_regex="$(echo "$EXCLUDE_PATHS" | sed 's/, */,/g; s/,/|/g')"
  mapfile -t entries < <(printf "%s\n" "${entries[@]}" | grep -vE "$exclude_regex" || true)
fi

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "No SQL files found for check."
  exit 0
fi

echo "SQL file entries found: ${#entries[@]}"
echo "Actor: $ACTOR"

# Fast local bypass for bot/user actors.
if [[ " $EXEMPT_ACTORS " == *" $ACTOR "* ]]; then
  echo "Actor '$ACTOR' is exempt from SQL checks."
  exit 0
fi

# Team bypass. Done only after SQL files are found to avoid unnecessary API calls.
for team in $EXEMPT_TEAMS; do
  status="$(curl -sS -o /tmp/team_membership.json -w "%{http_code}" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/$ORG/teams/$team/memberships/$ACTOR")"

  if [[ "$status" == "200" ]] && grep -q '"state": "active"' /tmp/team_membership.json; then
    echo "Actor '$ACTOR' is member of exempt team '$team'. SQL check bypassed."
    exit 0
  fi
done

mkdir -p /tmp/sql-guard

error_files_encoding=""
error_files_disallowed=""

total="${#entries[@]}"
current=0

for entry in "${entries[@]}"; do
  current=$((current + 1))

  ref="$(cut -f1 <<< "$entry")"
  file="$(cut -f2- <<< "$entry")"

  echo "Checking file $current/$total: $file at $ref"

  safe_name="$(printf "%s" "$ref-$file" | sha256sum | awk '{print $1}')"
  local_file="/tmp/sql-guard/$safe_name.sql"

  if ! fetch_file "$file" "$ref" > "$local_file"; then
    echo "::warning::Could not fetch '$file' at ref '$ref'. Skipping."
    continue
  fi

  if [[ "$UTF8_BOM_CHECK" == "true" ]] && ! has_utf8_bom "$local_file"; then
    error_files_encoding+="$ref --> $file"$'\n'
    continue
  fi

  if is_sql_file_containing_disallowed_command "$local_file"; then
    error_files_disallowed+="$ref --> $file"$'\n'
  fi
done

if [[ -n "$error_files_encoding" || -n "$error_files_disallowed" ]]; then
  if [[ -n "$error_files_encoding" ]]; then
    echo "::error::The following SQL files do not have the required UTF-8 BOM encoding:"
    echo "$error_files_encoding"
  fi

  if [[ -n "$error_files_disallowed" ]]; then
    echo "::error::The following SQL files contain disallowed DROP or ALTER commands:"
    echo "$error_files_disallowed"
  fi

  echo "Please review and modify these files before merging."
  exit 1
fi

echo "All SQL files passed check."
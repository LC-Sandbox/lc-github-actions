#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Script: check-sql.sh
#
# Purpose:
#   Validate SQL files changed between a baseline and a target branch state
#   without checking out the repository.
#
# Flow:
#   1. Resolve target SHA from BRANCH_NAME.
#   2. Resolve baseline SHA:
#        - master       -> commit from Izvrseno.json
#        - other branch -> tag v<BRANCH_NAME>_db
#   3. Compare baseline SHA and target SHA through GitHub REST API.
#   4. Keep changed .sql files, excluding removed/renamed files.
#   5. Apply optional path exclusions.
#   6. Exit successfully if no SQL files remain.
#   7. Fetch remaining SQL files at the target SHA.
#   8. Optionally validate UTF-8 BOM.
#   9. Remove comments, quoted strings, and allowed SQL patterns.
#  10. Fail if remaining SQL contains disallowed DROP or ALTER.
#
# Required environment variables:
#   GH_TOKEN      GitHub token with Contents: read permission.
#   REPOSITORY    Repository in owner/name format.
#   BRANCH_NAME   Branch to validate.
#   DB_TYPE       Database type, e.g. SPI, ARH.
#
# Optional environment variables:
#   EXCLUDE_PATHS   Comma-separated regex fragments.
#   UTF8_BOM_CHECK  Set to "true" to require UTF-8 BOM.
################################################################################

: "${EXCLUDE_PATHS:=}"
: "${UTF8_BOM_CHECK:=false}"

required_vars=(GH_TOKEN REPOSITORY BRANCH_NAME DB_TYPE)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "::error::Required environment variable '$var' is not set."
    exit 1
  fi
done

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

# URL-encode a repository path, branch, or tag reference.
url_encode_path() {
  jq -rn --arg v "$1" '$v|@uri'
}

# Resolve the HEAD commit SHA of a branch.
resolve_branch_sha() {
  local branch="$1"
  local encoded_branch

  encoded_branch="$(url_encode_path "$branch")"

  api_get "https://api.github.com/repos/$REPOSITORY/branches/$encoded_branch" |
    jq -r '.commit.sha'
}

# Resolve a Git tag to the commit SHA it points to.
# Supports both lightweight and annotated tags.
resolve_tag_sha() {
  local tag="$1"
  local encoded_ref response object_type object_sha

  encoded_ref="$(url_encode_path "tags/$tag")"

  response="$(api_get "https://api.github.com/repos/$REPOSITORY/git/ref/$encoded_ref")"
  object_type="$(echo "$response" | jq -r '.object.type')"
  object_sha="$(echo "$response" | jq -r '.object.sha')"

  if [[ "$object_type" == "commit" ]]; then
    echo "$object_sha"
    return
  fi

  if [[ "$object_type" == "tag" ]]; then
    api_get "https://api.github.com/repos/$REPOSITORY/git/tags/$object_sha" |
      jq -r '.object.sha'
    return
  fi

  echo "::error::Unsupported tag object type '$object_type' for tag '$tag'."
  exit 1
}

# Fetch a file from the repository at a specific ref/SHA.
fetch_file() {
  local path="$1"
  local ref="$2"
  local encoded_path

  encoded_path="$(url_encode_path "$path")"
  api_get_raw "https://api.github.com/repos/$REPOSITORY/contents/$encoded_path?ref=$ref"
}

# Resolve daily baseline SHA from Izvrseno.json.
#
# The file is fetched from:
#   Database/Scripts/<DB_TYPE>/DnevnaNadogradnja/Izvrseno.json
#
# at the target branch HEAD commit.
#
# Expected JSON format:
# {
#   "gitCommitHash": "<sha>",
#   ...
# }
resolve_daily_from_sha() {
  local to_sha="$1"
  local path="Database/Scripts/${DB_TYPE}/DnevnaNadogradnja/Izvrseno.json"
  local tmp="/tmp/izvrseno.json"
  local from_sha

  echo "Resolving daily baseline from '$path' at '$to_sha'..."

  if ! fetch_file "$path" "$to_sha" > "$tmp"; then
    echo "::error::Could not fetch '$path' at '$to_sha'."
    exit 1
  fi

  from_sha="$(jq -r '.gitCommitHash // empty' "$tmp")"

  if [[ -z "$from_sha" || "$from_sha" == "null" ]]; then
    echo "::error::Could not resolve gitCommitHash from '$path'."
    exit 1
  fi

  echo "$from_sha"
}

# List changed SQL files between two commits.
# Output format:
#   <to_sha>\t<filename>
get_changed_sql_files_range() {
  local from_sha="$1"
  local to_sha="$2"
  local response

  response="$(api_get "https://api.github.com/repos/$REPOSITORY/compare/$from_sha...$to_sha")"

  echo "$response" |
    jq -r --arg ref "$to_sha" '
      .files[]
      | select((.status != "removed") and (.status != "renamed") and (.filename | endswith(".sql")))
      | "\($ref)\t\(.filename)"
    '
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

echo "Initiating SQL guard range check..."
echo "Repository: $REPOSITORY"
echo "Branch: $BRANCH_NAME"
echo "DB type: $DB_TYPE"

TO_SHA="$(resolve_branch_sha "$BRANCH_NAME")"

if [[ "$BRANCH_NAME" == "master" ]]; then
  MODE="daily"
  FROM_SHA="$(resolve_daily_from_sha "$TO_SHA")"
else
  MODE="hf"
  FROM_SHA="$(resolve_tag_sha "v${BRANCH_NAME}_db")"
fi

echo "Mode: $MODE"
echo "From SHA: $FROM_SHA"
echo "To SHA:   $TO_SHA"

# Get changed SQL files before fetching file contents.
mapfile -t entries < <(get_changed_sql_files_range "$FROM_SHA" "$TO_SHA" | sort -u)

# Apply optional path exclusions before fetching file contents.
if [[ -n "$EXCLUDE_PATHS" && ${#entries[@]} -gt 0 ]]; then
  exclude_regex="$(echo "$EXCLUDE_PATHS" | sed 's/, */,/g; s/,/|/g')"
  mapfile -t entries < <(printf "%s\n" "${entries[@]}" | grep -vE "$exclude_regex" || true)
fi

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "No SQL files found for check."
  exit 0
fi

echo "SQL file entries found: ${#entries[@]}"

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

  echo "Please review and modify these files before continuing."
  exit 1
fi

echo "All SQL files passed check."
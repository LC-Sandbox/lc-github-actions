#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Script: check-sql.sh
#
# Purpose:
#   Validate SQL files changed between a baseline and a target branch state
#   for a specific database type without checking out the repository.
#
# Flow:
#   1. Resolve target SHA from BRANCH_NAME.
#   2. Resolve baseline SHA:
#        - master       -> commit from Izvrseno.json
#        - other branch -> tag v<BRANCH_NAME>_db
#   3. Compare baseline SHA and target SHA through GitHub REST API.
#   4. Keep changed .sql files:
#        - excluding removed/renamed files
#        - limited to Database/Scripts/<DB_TYPE>/
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
    echo "::error::Required environment variable '$var' is not set." >&2
    exit 1
  fi
done

# Function: api_get
#
# Description:
#   Executes a GitHub REST API GET request and returns the JSON response.
#
# Parameters:
#   url - Fully qualified GitHub API URL.
#
# Returns:
#   JSON response through stdout.
#
# Example:
#   api_get "https://api.github.com/repos/org/repo/branches/master"
api_get() {
  curl -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

# Function: api_get_raw
#
# Description:
#   Downloads raw file contents from GitHub using the Contents API.
#
# Parameters:
#   url - Fully qualified GitHub API URL.
#
# Returns:
#   Raw file contents through stdout.
#
# Example:
#   api_get_raw "https://api.github.com/repos/org/repo/contents/test.sql?ref=<sha>"
api_get_raw() {
  curl -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github.raw" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

# Function: url_encode_path
#
# Description:
#   URL-encodes a string for safe use inside GitHub API URLs.
#
# Parameters:
#   value - String to encode.
#
# Returns:
#   URL-encoded string.
#
# Example:
#   url_encode_path "tags/v7.00.05.00_db"
#
# Result:
#   tags%2Fv7.00.05.00_db
url_encode_path() {
  jq -rn --arg v "$1" '$v|@uri'
}

# Function: resolve_branch_sha
#
# Description:
#   Resolves the current HEAD commit SHA for a GitHub branch.
#
# Parameters:
#   branch - Branch name.
#
# Returns:
#   Branch HEAD commit SHA.
resolve_branch_sha() {
  local branch="$1"
  local encoded_branch response sha

  encoded_branch="$(url_encode_path "$branch")"
  response="$(api_get "https://api.github.com/repos/$REPOSITORY/branches/$encoded_branch")"
  sha="$(echo "$response" | jq -r '.commit.sha // empty')"

  if [[ -z "$sha" || "$sha" == "null" ]]; then
    echo "::error::Could not resolve HEAD SHA for branch '$branch'." >&2
    exit 1
  fi

  echo "$sha"
}

# Function: resolve_tag_sha
#
# Description:
#   Resolves the commit SHA referenced by a Git tag.
#
#   Supports both lightweight and annotated tags.
#
# Parameters:
#   tag - Tag name.
#
# Returns:
#   Commit SHA referenced by the tag.
resolve_tag_sha() {
  local tag="$1"
  local encoded_ref response object_type object_sha tag_response commit_sha

  encoded_ref="$(url_encode_path "tags/$tag")"
  response="$(api_get "https://api.github.com/repos/$REPOSITORY/git/ref/$encoded_ref")"

  object_type="$(echo "$response" | jq -r '.object.type // empty')"
  object_sha="$(echo "$response" | jq -r '.object.sha // empty')"

  if [[ -z "$object_type" || -z "$object_sha" || "$object_type" == "null" || "$object_sha" == "null" ]]; then
    echo "::error::Could not resolve tag '$tag'." >&2
    exit 1
  fi

  if [[ "$object_type" == "commit" ]]; then
    echo "$object_sha"
    return
  fi

  if [[ "$object_type" == "tag" ]]; then
    tag_response="$(api_get "https://api.github.com/repos/$REPOSITORY/git/tags/$object_sha")"
    commit_sha="$(echo "$tag_response" | jq -r '.object.sha // empty')"

    if [[ -z "$commit_sha" || "$commit_sha" == "null" ]]; then
      echo "::error::Could not resolve annotated tag '$tag' to commit SHA." >&2
      exit 1
    fi

    echo "$commit_sha"
    return
  fi

  echo "::error::Unsupported tag object type '$object_type' for tag '$tag'." >&2
  exit 1
}

# Function: fetch_file
#
# Description:
#   Retrieves raw file contents from the repository at the specified
#   commit SHA, branch, or tag reference.
#
# Parameters:
#   path - Repository-relative file path.
#   ref  - Commit SHA, branch, or tag.
#
# Returns:
#   Raw file contents through stdout.
#
# Example:
#   fetch_file "Database/Scripts/SPI/Test.sql" "a92204c..."
fetch_file() {
  local path="$1"
  local ref="$2"
  local encoded_path encoded_ref

  encoded_path="$(url_encode_path "$path")"
  encoded_ref="$(url_encode_path "$ref")"

  api_get_raw "https://api.github.com/repos/$REPOSITORY/contents/$encoded_path?ref=$encoded_ref"
}

# Function: resolve_daily_from_sha
#
# Description:
#   Resolves the baseline commit SHA for a daily (master) build.
#
#   The baseline is stored in:
#
#     Database/Scripts/<DB_TYPE>/DnevnaNadogradnja/Izvrseno.json
#
#   The file is fetched from the current branch HEAD commit and the
#   value of property "gitCommitHash" is used as the comparison start
#   point.
#
#   Example:
#     Current master HEAD:
#       395d8fb...
#
#     Izvrseno.json:
#       {
#         "gitCommitHash": "a92204c..."
#       }
#
#     Result:
#       a92204c...
#
# Parameters:
#   to_sha - Current branch HEAD commit SHA.
#
# Returns:
#   Baseline commit SHA from Izvrseno.json.
#
# Errors:
#   Fails if Izvrseno.json cannot be fetched or does not contain
#   a valid gitCommitHash value.
resolve_daily_from_sha() {
  local to_sha="$1"
  local path="Database/Scripts/${DB_TYPE}/DnevnaNadogradnja/Izvrseno.json"
  local tmp="/tmp/izvrseno.json"
  local from_sha

  echo "Resolving daily baseline from '$path' at '$to_sha'..." >&2

  if ! fetch_file "$path" "$to_sha" > "$tmp"; then
    echo "::error::Could not fetch '$path' at '$to_sha'." >&2
    exit 1
  fi

  from_sha="$(jq -r '.gitCommitHash // empty' "$tmp")"

  if [[ -z "$from_sha" || "$from_sha" == "null" ]]; then
    echo "::error::Could not resolve gitCommitHash from '$path'." >&2
    exit 1
  fi

  echo "$from_sha"
}

# Function: get_changed_sql_files_range
#
# Description:
#   Lists changed SQL files between two commits using the GitHub
#   Compare API.
#
#   The comparison includes the entire commit range:
#
#     from_sha ... to_sha
#
#   Only SQL files belonging to the selected database type are returned:
#
#     Database/Scripts/<DB_TYPE>/
#
#   Removed and renamed files are ignored because only files that
#   currently exist at the target revision can be validated.
#
#   Returned entries always use to_sha as the file reference because
#   validation is performed against the final file contents that exist
#   at the end of the range.
#
# Parameters:
#   from_sha - Baseline commit SHA.
#   to_sha   - Target commit SHA.
#
# Output:
#   One line per SQL file:
#
#     <to_sha>\t<filename>
#
# Example:
#   395d8fb...    Database/Scripts/SPI/DatabaseObjects/Test.sql
#
# Returns:
#   Changed SQL files for the selected DB_TYPE between the two commits.
#
# Errors:
#   Fails if the GitHub Compare API returns an error.
get_changed_sql_files_range() {
  local from_sha="$1"
  local to_sha="$2"
  local response message

  response="$(api_get "https://api.github.com/repos/$REPOSITORY/compare/$from_sha...$to_sha")"

  message="$(echo "$response" | jq -r '.message // empty')"
  if [[ -n "$message" ]]; then
    echo "::error::GitHub compare API failed: $message" >&2
    exit 1
  fi

  echo "$response" |
    jq -r --arg ref "$to_sha" --arg db_type "$DB_TYPE" '
      .files[]
      | select((.status != "removed") and (.status != "renamed"))
      | select(.filename | endswith(".sql"))
      | select(.filename | startswith("Database/Scripts/" + $db_type + "/"))
      | "\($ref)\t\(.filename)"
    '
}

# Function: has_utf8_bom
#
# Description:
#   Checks whether a file begins with the UTF-8 BOM sequence:
#
#     EF BB BF
#
# Parameters:
#   file - Path to local file.
#
# Returns:
#   0 if BOM exists.
#   1 otherwise.
has_utf8_bom() {
  [[ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' ')" == "efbbbf" ]]
}

# Function: is_sql_file_containing_disallowed_command
#
# Description:
#   Checks whether a SQL file contains disallowed DROP or ALTER commands.
#
#   Before checking, the SQL content is sanitized by removing:
#     - block comments
#     - line comments
#     - string literals
#
#   The following patterns are explicitly allowed:
#     - DROP TABLE on temporary tables
#     - ALTER TABLE on temporary tables
#     - GRANT ALTER ON
#     - ALTER COLUMN
#     - ADD CONSTRAINT
#     - CHECK/NOCHECK CONSTRAINT
#     - DROP CONSTRAINT
#     - ENABLE/DISABLE TRIGGER
#
# Parameters:
#   file - Local SQL file path.
#
# Returns:
#   0 if disallowed DROP/ALTER is detected.
#   1 otherwise.
is_sql_file_containing_disallowed_command() {
  local file="$1"

  perl -0777 -pe '
    s|/\*.*?\*/||gis;
    s|--.*$||gm;
    s|'\''[^'\'']*'\''||g;

    s|drop\s*table\s*(\[?dbo\]?\.)?\[?#\w+\]?||gi;
    s|alter\s*table\s*(\[?dbo\]?\.)?\[?#\w+\]?\s*drop||gi;
    s|alter\s*table\s*(\[?dbo\]?\.)?\[?#\w+\]?||gi;

    s|grant\s*alter\s*on||gi;

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
echo "Database scope: Database/Scripts/${DB_TYPE}/"
echo "From SHA: $FROM_SHA"
echo "To SHA:   $TO_SHA"

mapfile -t entries < <(get_changed_sql_files_range "$FROM_SHA" "$TO_SHA" | sort -u)

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
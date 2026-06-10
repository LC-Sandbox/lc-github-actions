#!/usr/bin/env bash
#
# Mirrors a GitHub repository to an existing AWS CodeCommit repository.
#
# Authentication:
#   - GitHub: GITHUB_TOKEN (provided by GitHub Actions)
#   - AWS: Temporary credentials obtained via OIDC and
#          aws-actions/configure-aws-credentials
#
# Assumptions:
#   - The target CodeCommit repository already exists.
#   - By default, the CodeCommit repository name matches the GitHub
#     repository name (without the owner/org prefix).
#   - CODECOMMIT_REPOSITORY can be provided to override the target name.
#
# Notes:
#   - Uses a bare mirror clone instead of actions/checkout to avoid
#     creating a working tree and to ensure all refs are synchronized.
#   - git push --mirror propagates branches, tags and ref deletions.

set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

# Use an explicit CodeCommit repository name when provided,
# otherwise derive it from the GitHub repository name.
# Example:
#   org/my-service -> my-service
repository_name="${CODECOMMIT_REPOSITORY:-${REPOSITORY##*/}}"

echo "Mirroring ${REPOSITORY} to CodeCommit repository ${repository_name}"

git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

# Resolve the HTTPS clone URL for the target CodeCommit repository.
clone_url="$(
  aws codecommit get-repository \
    --repository-name "$repository_name" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["repositoryMetadata"]["cloneUrlHttp"])'
)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

github_url="https://github.com/${REPOSITORY}.git"

# Perform a bare mirror clone to fetch all refs without creating
# a working tree. Use an HTTP authorization header rather than
# embedding the token in the repository URL.
git \
  -c "http.https://github.com/.extraheader=AUTHORIZATION: bearer ${GH_TOKEN}" \
  clone --mirror "$github_url" "$workdir/repo.git"

cd "$workdir/repo.git"

# Synchronize all refs (branches, tags and deletions) to CodeCommit.
git push --mirror "$clone_url"
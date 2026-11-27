#!/usr/bin/env bash
# Commits the working tree changes on a new branch and opens a pull request,
# unless that branch exists already (an earlier run opened the PR).
# Used by bump-dependencies.yml and wordpress-release.yml.
#
# Usage: open-bump-pr.sh <branch> <title> <body>
# Needs GH_TOKEN; BUMP_PR_TOKEN_SET=1 when it is the BUMP_PR_TOKEN secret.
set -euo pipefail
branch=$1 title=$2 body=$3

if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  echo "Branch $branch exists already; not opening another pull request"
  exit 0
fi

# A pull request opened with GITHUB_TOKEN doesn't trigger workflows, so its
# required build checks would never start.
if [ "${BUMP_PR_TOKEN_SET:-}" != 1 ]; then
  body+=$'\n\n'"> [!NOTE]"$'\n'"> Opened with \`GITHUB_TOKEN\`, which doesn't start the build checks. Close and reopen this pull request to run them, or add a \`BUMP_PR_TOKEN\` secret (fine-grained token with contents and pull request write access) so they start on their own."
  echo "::warning::No BUMP_PR_TOKEN secret: the pull request's checks won't start until it is closed and reopened"
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git switch -c "$branch"
git commit -qam "$title"
git push -q origin "$branch"
gh pr create --base main --head "$branch" --title "$title" --body "$body"

---
name: frogloop
description: >
  Iteratively improves a GitHub pull request with PullFrog. Triggers PullFrog
  reviews, waits for PullFrog GitHub Actions runs to finish, fetches unresolved
  PullFrog review feedback and failing checks, fixes or delegates actionable
  items, pushes updates, and repeats until the PR has no unresolved PullFrog
  feedback and checks are passing.
license: MIT
compatibility: Requires git, gh authenticated for the target GitHub repository, jq, and PullFrog configured on the repo with a .github/workflows/pullfrog.yml or .yaml workflow.
metadata:
  author: thomas
  version: "1.0"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(jq:*) Bash(sleep:*) Bash(date:*)
---

# Frogloop

Iteratively drive a GitHub PR through PullFrog review and fix cycles until the
PullFrog feedback is addressed and CI is passing.

PullFrog is GitHub-only. Do not try to apply this skill to GitLab, Perforce, or
local-only changes without an open GitHub PR.

## Inputs

- **PR number** (optional): If omitted, detect the PR for the current branch.
- **Mode** (optional):
  - `local-fix` (default): the agent fixes PullFrog feedback locally, commits, and
    pushes.
  - `delegate`: ask PullFrog to address review feedback or failing CI, then fetch
    the pushed result before checking again.

## Instructions

### 0. Check prerequisites

Verify the repository is a GitHub repository and PullFrog is configured:

```bash
gh repo view --json nameWithOwner
git remote get-url origin
```

Find the PullFrog workflow:

```bash
PULLFROG_WORKFLOW=$(
  gh workflow list --json name,path,state |
    jq -r '.[] | select(.state == "active") |
      select((.path | test("(^|/)pullfrog\\.ya?ml$"; "i")) or (.name | test("pullfrog"; "i"))) |
      .path' |
    head -n 1
)
```

If `PULLFROG_WORKFLOW` is empty, report that PullFrog is not configured. The
repo should have `.github/workflows/pullfrog.yml` or `.github/workflows/pullfrog.yaml`
and the PullFrog GitHub App/dashboard configured.

Check for unrelated local work before making changes:

```bash
git status --short
```

Do not discard or overwrite user changes. If unrelated dirty files exist, work
around them or report the conflict.

### 1. Identify the PR

If the user did not provide a PR number, detect the PR for the current branch:

```bash
PR_JSON=$(gh pr view --json number,headRefName,headRefOid,baseRefName,url)
PR_NUMBER=$(echo "$PR_JSON" | jq -r .number)
HEAD_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
HEAD_SHA=$(echo "$PR_JSON" | jq -r .headRefOid)
```

If the command fails, ask the user for a PR number or to push/open a PR first.

Ensure the local branch matches the PR head:

```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$HEAD_BRANCH" ]; then
  git fetch origin "$HEAD_BRANCH"
  git switch "$HEAD_BRANCH"
fi
```

### 2. Loop

Repeat this cycle. **Max 5 iterations** to avoid runaway agent loops.

#### A. Trigger PullFrog review

Push any local commits first so PullFrog reviews the latest PR head:

```bash
git push
```

Record a timestamp before triggering:

```bash
TRIGGERED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
```

Trigger PullFrog with a PR comment:

```bash
gh pr comment "$PR_NUMBER" --body "@pullfrog please review this pull request. Focus on correctness, regressions, security, tests, and maintainability. Leave actionable inline comments for issues. If there are no issues, say that clearly."
```

Use a re-review wording on later iterations:

```bash
gh pr comment "$PR_NUMBER" --body "@pullfrog please re-review this pull request after the latest fixes. Focus on new changes and any still-unresolved feedback. If there are no remaining issues, say that clearly."
```

#### B. Wait for the PullFrog run

Poll GitHub Actions for a PullFrog workflow run created after `TRIGGERED_AT`:

```bash
while true; do
  RUN_JSON=$(
    gh run list --workflow "$PULLFROG_WORKFLOW" \
      --json databaseId,displayTitle,status,conclusion,createdAt,url,headSha \
      --limit 30 |
      jq --arg triggered "$TRIGGERED_AT" '
        [.[] | select(.createdAt >= $triggered)] |
        sort_by(.createdAt) |
        last // empty'
  )

  if [ -z "$RUN_JSON" ] || [ "$RUN_JSON" = "null" ]; then
    echo "Waiting for PullFrog workflow run to appear..."
    sleep 10
    continue
  fi

  RUN_ID=$(echo "$RUN_JSON" | jq -r .databaseId)
  RUN_STATUS=$(echo "$RUN_JSON" | jq -r .status)
  RUN_CONCLUSION=$(echo "$RUN_JSON" | jq -r '.conclusion // "pending"')

  if [ "$RUN_STATUS" = "completed" ]; then
    echo "PullFrog run completed with: $RUN_CONCLUSION"
    break
  fi

  echo "Waiting for PullFrog... (status: $RUN_STATUS)"
  sleep 15
done
```

If the run failed, fetch useful context before deciding what to do:

```bash
gh run view "$RUN_ID" --json conclusion,status,url,displayTitle,createdAt,updatedAt
gh run view "$RUN_ID" --log-failed
```

Treat a failed PullFrog run as an issue to report unless the failure is caused by
the PR code and can be fixed locally.

#### C. Refresh local state

PullFrog may push changes in delegated or auto-fix flows. After every completed
PullFrog run, refresh the PR branch:

```bash
git fetch origin "$HEAD_BRANCH"
git pull --ff-only
PR_JSON=$(gh pr view "$PR_NUMBER" --json number,headRefName,headRefOid,baseRefName,url)
HEAD_SHA=$(echo "$PR_JSON" | jq -r .headRefOid)
```

If `git pull --ff-only` fails, stop and report that the local branch diverged.
Do not merge or rebase automatically unless the user explicitly asked for that.

#### D. Fetch PullFrog review results

Fetch all relevant result surfaces. PullFrog can post issue comments, PR reviews,
inline review comments, and workflow logs.

General PR comments:

```bash
gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUMBER/comments?per_page=100" |
  jq '[.[] | select((.user.login // "" | test("pullfrog"; "i")) or (.body // "" | test("@pullfrog|PullFrog"; "i"))) ] |
      sort_by(.updated_at)'
```

PR reviews:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews" |
  jq '[.[] | select(.user.login // "" | test("pullfrog"; "i"))] |
      sort_by(.submitted_at)'
```

Inline PR comments:

```bash
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments?per_page=100" |
  jq --arg head "$HEAD_SHA" '
    [.[] |
      select(.user.login // "" | test("pullfrog"; "i")) |
      select((.commit_id == $head) or (.original_commit_id == $head))] |
    sort_by(.updated_at)'
```

Unresolved review threads require GraphQL:

```bash
OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)

gh api graphql \
  -f owner="$OWNER" \
  -f repo="$REPO" \
  -F number="$PR_NUMBER" \
  -f query='
query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 20) {
            nodes {
              body
              path
              line
              originalLine
              diffHunk
              author { login }
              createdAt
              updatedAt
            }
          }
        }
      }
    }
  }
}'
```

Filter unresolved PullFrog-authored threads:

- `isResolved == false`
- `isOutdated == false` unless the comment is still clearly applicable
- at least one comment author login contains `pullfrog` case-insensitively

If the user asked to satisfy all reviewers, include unresolved human review
threads too. Otherwise, keep the loop scoped to PullFrog-authored feedback.

#### E. Check CI status

Wait for checks on the current PR head to finish:

```bash
gh pr checks "$PR_NUMBER" --watch
```

Then inspect the result:

```bash
gh pr checks "$PR_NUMBER" --json name,state,conclusion,link,bucket
```

Treat these as failing CI states: `FAIL`, `ERROR`, `CANCELLED`, `TIMED_OUT`,
or any completed check with a non-success conclusion. Ignore the PullFrog run
itself when deciding whether product/test CI is passing.

#### F. Check exit conditions

Stop the loop if all of these are true:

- PullFrog workflow run completed successfully.
- There are zero unresolved, non-outdated PullFrog review threads.
- There are no fresh PullFrog comments asking for follow-up.
- Non-PullFrog PR checks are passing or there are no checks configured.

Unlike Greptile, PullFrog does not publish a numeric confidence score. Do not
invent one. Report the final state in terms of unresolved feedback, check status,
and PullFrog run conclusion.

#### G. Fix or delegate actionable items

In `local-fix` mode:

1. Read each affected file and understand the PullFrog comment in context.
2. Determine whether it is actionable, informational, stale, or a false positive.
3. Fix actionable issues with the smallest reasonable change.
4. Run focused local tests or checks when available.
5. Resolve only threads that were addressed, became stale, or are clear false
   positives.

In `delegate` mode, or when the issue is better handled by PullFrog because it
requires PR-context automation:

```bash
gh pr comment "$PR_NUMBER" --body "@pullfrog please address all unresolved review feedback and failing CI checks on this PR. Keep the changes focused, run the relevant tests, resolve only threads that your changes actually address, and push to this PR branch."
```

Then wait for the PullFrog run, refresh local state, and continue the loop.

#### H. Resolve addressed threads

Only resolve review threads after the feedback has been addressed or confirmed
not actionable. Do not resolve a thread just because it is inconvenient.

Use GraphQL to resolve addressed threads:

```bash
gh api graphql -f query='
mutation {
  t1: resolveReviewThread(input: {threadId: "THREAD_ID_1"}) { thread { isResolved } }
  t2: resolveReviewThread(input: {threadId: "THREAD_ID_2"}) { thread { isResolved } }
}'
```

For many threads, build one mutation with aliases (`t1`, `t2`, ...), or run
individual mutations.

#### I. Commit and push local fixes

If local changes were made:

```bash
git status --short
git add -A
git commit -m "address pullfrog feedback (frogloop iteration N)"
git push
```

If there are no local changes but unresolved feedback remains, either delegate
to PullFrog or report the remaining comments as requiring human judgment.

Then return to step A for the next review.

### 3. Report

After exiting the loop, summarize:

| Field                    | Value |
| ------------------------ | ----- |
| PR                       | URL / number |
| Iterations               | N |
| Mode                     | local-fix / delegate |
| PullFrog run conclusion  | success / failure / cancelled / timed_out |
| PullFrog threads resolved| N |
| Remaining PullFrog threads | N |
| Check status             | passing / failing / pending / none |

If the loop stopped due to the max iteration cap, list remaining actionable
threads and failing checks with file paths, check names, and links where
available.

## Output format

Successful run:

```text
Frogloop complete.
  PR:                     #123
  Iterations:             2
  Mode:                   local-fix
  PullFrog run:           success
  Threads resolved:       5
  Remaining threads:      0
  Checks:                 passing
```

Stopped run:

```text
Frogloop stopped after 5 iterations.
  PR:                     #123
  PullFrog run:           success
  Threads resolved:       8
  Remaining threads:      2
  Checks:                 failing

Remaining issues:
  - src/auth.ts:45 - PullFrog: "Missing authorization check"
  - test job - failing after retry: https://github.com/OWNER/REPO/actions/runs/RUN_ID
```

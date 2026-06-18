#!/bin/bash
set -eo pipefail

# Impact Scholars Submission Manager
#
# Subcommands:
#   create <author-repo-url> [target-name]
#       Create review target repo, seed main, build review branch, open PR.
#       Idempotent: re-running on an existing target skips already-done steps.
#       Author URL may be GitHub or a plain-git host (e.g. GIN/Gitea); for a
#       non-GitHub source, [target-name] is required and --source-ref selects
#       the branch to ingest (GIN default branch is 'master').
#
#   add-reviewers <target-name> <user>...
#       Invite reviewers as push collaborators on target repo.
#
#   promote-authors <target-name> <author-repo-url>
#       Invite author repo contributors as push collaborators on target.
#
#   resync-author <target-name> <author-repo-url> --force
#       Force-push fresh author content onto review branch. Wipes any existing review commits.
#
#   apply-rulesets <target-name>
#       Apply branch + tag rulesets + zenodo-publish env + grant @ORG/editors
#       write access. Idempotent. Also runs automatically as the last step of `create`.
#
# Common options:
#   --yes / -y          Skip confirmation prompt (required for non-TTY)
#   --source-ref <ref>  Branch to ingest from the author URL (create; default main)
#   --help / -h         Show this help
#
# Environment:
#   ISP_ORG   Override the target org/account (default impact-scholars)

export GH_PAGER=cat

ORG="${ISP_ORG:-impact-scholars}"
TEMPLATE_REPO="impact-scholars/isp-micropublication-template"

# ---------- helpers ----------

usage() {
    sed -n '4,33p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

confirm() {
    if [ "$ASSUME_YES" = "true" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "Error: not a TTY and --yes not set. Re-run with --yes." >&2
        exit 1
    fi
    read -rp "Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

require_gh_auth() {
    command -v gh &>/dev/null || { echo "Error: gh CLI not found. Install from https://cli.github.com/"; exit 1; }
    gh auth status &>/dev/null || { echo "Error: gh CLI not authenticated. Run 'gh auth login'"; exit 1; }
}

require_org_membership() {
    local actor="$1"
    local role
    role=$(gh api "orgs/$ORG/memberships/$actor" --jq .role 2>/dev/null) || {
        echo "Error: $actor is not a member of org: $ORG"; exit 1;
    }
    echo "  ✓ org membership: $role"
}

repo_exists()   { gh api "repos/$1" &>/dev/null; }
branch_exists() { gh api "repos/$1/branches/$2" &>/dev/null; }
pr_exists()     { [ "$(gh pr list --repo "$1" --head "$2" --json number --jq length 2>/dev/null)" -gt 0 ]; }

# Grant push without downgrading an existing role: PUT permission=push overwrites
# the current role, so skip anyone already at write/admin. $1 = repo, $2 = user.
ensure_push_collaborator() {
    local target_repo="$1" user="$2" current
    current=$(gh api "repos/$target_repo/collaborators/$user/permission" --jq .permission 2>/dev/null || true)
    case "$current" in
        admin|maintain|write)
            echo "  ✓ $user already has '$current' (≥push); skipping to avoid downgrade"
            return 0 ;;
    esac
    if gh api "repos/$target_repo/collaborators/$user" --method PUT --field permission=push >/dev/null 2>&1; then
        echo "  ✓ $user (push)"
    else
        echo "  ⚠️  $user — failed (may already be collaborator at this level)"
    fi
}

is_github_url() {
    # Returns 0 if the URL points at github.com, 1 otherwise.
    [[ "$1" =~ github\.com[/:] ]]
}

parse_github_url() {
    # Sets AUTHOR_USER, AUTHOR_REPO from a GitHub URL.
    if [[ "$1" =~ github\.com[/:]([^/]+)/([^/\.]+) ]]; then
        AUTHOR_USER="${BASH_REMATCH[1]}"
        AUTHOR_REPO="${BASH_REMATCH[2]}"
    else
        echo "Error: could not parse GitHub URL: $1"; exit 1;
    fi
}

CLEANUP_DIRS=()
cleanup() {
    for d in "${CLEANUP_DIRS[@]}"; do
        [ -d "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

make_temp_dir() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Idempotent — looks up an existing ruleset by name, creates if absent.
# $1 = target repo (owner/repo), $2 = ruleset JSON body.
upsert_ruleset() {
    local target_repo="$1"
    local body="$2"
    local name
    name=$(echo "$body" | jq -r .name)
    local existing output
    if ! output=$(gh api "repos/$target_repo/rulesets" --jq ".[] | select(.name==\"$name\") | .id" 2>&1); then
        echo "Error: could not list rulesets for $target_repo while checking '$name':" >&2
        echo "$output" >&2
        return 1
    fi
    existing="$output"
    if [ -n "$existing" ]; then
        echo "  ✓ ruleset '$name' already exists (id $existing); skipping"
        return 0
    fi
    echo "$body" | gh api -X POST "repos/$target_repo/rulesets" --input - >/dev/null \
        && echo "  ✓ created ruleset '$name'"
}

apply_rulesets_to_repo() {
    local target_repo="$1"
    local owner_type
    owner_type=$(gh api "users/$ORG" --jq .type)

    # CODEOWNERS + tag bypass both require the editors team to have write on the
    # repo; without it GitHub silently ignores team references. Idempotent.
    if [ "$owner_type" = "Organization" ]; then
        if gh api -X PUT "orgs/$ORG/teams/editors/repos/$target_repo" \
            -f permission=push >/dev/null 2>&1; then
            echo "  ✓ @$ORG/editors team granted write access"
        else
            echo "Error: failed to grant @$ORG/editors team write on $target_repo" >&2
            return 1
        fi
    fi

    upsert_ruleset "$target_repo" "$(cat <<'EOF'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    }
  ]
}
EOF
)"

    local bypass team_id team_output
    if [ "$owner_type" = "Organization" ]; then
        if ! team_output=$(gh api "orgs/$ORG/teams/editors" --jq .id 2>&1); then
            echo "Error: could not find @$ORG/editors team for tag ruleset bypass:" >&2
            echo "$team_output" >&2
            return 1
        fi
        team_id="$team_output"
        if [[ ! "$team_id" =~ ^[0-9]+$ ]]; then
            echo "Error: @$ORG/editors team id is not numeric: $team_id" >&2
            return 1
        fi
        bypass="[{\"actor_id\":$team_id,\"actor_type\":\"Team\",\"bypass_mode\":\"always\"}]"
    else
        # Personal-account test repos cannot have org teams; allow repo admins
        # to create/update/delete release tags so v* tags are not locked forever.
        bypass='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
        echo "  ⚠️  $ORG is a personal account — v* tag bypass is repo admins, not @$ORG/editors"
    fi
    upsert_ruleset "$target_repo" "$(cat <<EOF
{
  "name": "editors-only-v-tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [
    { "type": "creation" },
    { "type": "update" },
    { "type": "deletion" }
  ],
  "bypass_actors": $bypass
}
EOF
)"

    # GitHub Pages with workflow build type — required for deploy-paper.yml
    # to publish the rendered paper. Idempotent: GET first, then POST only if
    # absent (POST returns 409 on existing config).
    if gh api "repos/$target_repo/pages" >/dev/null 2>&1; then
        echo "  ✓ Pages already enabled; skipping"
    else
        if gh api -X POST "repos/$target_repo/pages" -f build_type=workflow >/dev/null 2>&1; then
            echo "  ✓ Pages enabled (build_type=workflow)"
        else
            echo "Error: failed to enable Pages on $target_repo" >&2
            return 1
        fi
    fi

    # zenodo-publish environment — gates the publish job to v* tag refs only.
    gh api -X PUT "repos/$target_repo/environments/zenodo-publish" \
        --field 'deployment_branch_policy[protected_branches]=false' \
        --field 'deployment_branch_policy[custom_branch_policies]=true' \
        >/dev/null
    local existing_policy
    existing_policy=$(gh api "repos/$target_repo/environments/zenodo-publish/deployment-branch-policies" \
        --jq '.branch_policies[] | select(.name=="v*") | .id' 2>/dev/null || true)
    if [ -n "$existing_policy" ]; then
        echo "  ✓ zenodo-publish environment v* policy already exists; skipping"
    else
        gh api -X POST "repos/$target_repo/environments/zenodo-publish/deployment-branch-policies" \
            --field 'name=v*' --field 'type=tag' >/dev/null
        echo "  ✓ created zenodo-publish environment with v* tag policy"
    fi
}

# ---------- subcommand: create ----------

cmd_create() {
    local author_url="${1:-}"
    local target_name="${2:-}"
    [ -n "$author_url" ] || { echo "Error: <author-repo-url> required"; usage; }

    # Source can be a GitHub author repo or a plain-git host (e.g. GIN/Gitea).
    # For GitHub we keep the original behavior; for other hosts we fetch the
    # given URL + --source-ref directly and require an explicit target-name.
    local source_is_github=false source_url source_label
    if is_github_url "$author_url"; then
        source_is_github=true
        parse_github_url "$author_url"
        source_url="https://github.com/$AUTHOR_USER/$AUTHOR_REPO.git"
        source_label="$AUTHOR_USER/$AUTHOR_REPO"
        if [ -z "$target_name" ]; then
            target_name="${AUTHOR_REPO}-$(date +%Y%m%d-%H%M%S)"
        fi
    else
        source_url="$author_url"
        source_label="$author_url"
        [ -n "$target_name" ] || { echo "Error: non-GitHub source requires an explicit [target-name]"; exit 1; }
    fi
    local target_repo="$ORG/$target_name"

    # ----- preflight -----
    echo "=== Preflight: create $target_repo ==="

    require_gh_auth
    local actor
    actor=$(gh api user --jq .login)
    echo "  ✓ gh authenticated as $actor"
    # require_org_membership "$actor"

    if [ "$source_is_github" = "true" ]; then
        local repo_info
        repo_info=$(gh api "repos/$AUTHOR_USER/$AUTHOR_REPO" 2>/dev/null) || {
            echo "Error: author repo not accessible: $AUTHOR_USER/$AUTHOR_REPO (must exist and be public)"
            exit 1
        }
        local visibility
        visibility=$(echo "$repo_info" | jq -r 'if .private then "private" else "public" end')
        [ "$visibility" = "public" ] || { echo "Error: author repo $AUTHOR_USER/$AUTHOR_REPO is $visibility (must be public)"; exit 1; }
        echo "  ✓ author repo $AUTHOR_USER/$AUTHOR_REPO is public"
    else
        echo "  ⚠️  non-GitHub source ($author_url) — skipping gh-api public/visibility check"
    fi

    local target_exists=false main_seeded=false review_exists=false pr_open=false
    if repo_exists "$target_repo"; then
        target_exists=true
        branch_exists "$target_repo" main   && main_seeded=true
        branch_exists "$target_repo" review && review_exists=true
        [ "$review_exists" = "true" ] && pr_exists "$target_repo" review && pr_open=true
    fi

    # ----- plan -----
    echo ""
    echo "=== Plan ==="
    if [ "$target_exists" = "false" ]; then echo "  ○ target repo: does not exist → will create (public)"; else echo "  ✓ target repo: exists"; fi
    if [ "$main_seeded" = "false" ];   then echo "  ○ main: will seed from template/bare";              else echo "  ✓ main: already seeded (skip)"; fi
    if [ "$review_exists" = "false" ]; then echo "  ○ review: will create from $author_url@$SOURCE_REF";    else echo "  ✓ review: exists (skip — use resync-author to refresh)"; fi
    if [ "$pr_open" = "false" ];       then echo "  ○ PR: will open review → main";                     else echo "  ✓ PR: already open (skip)"; fi
    echo "  ○ rulesets + env: @$ORG/editors write grant + protect-main (PR required, CODEOWNERS gates workflow changes) + editors-only-v-tags + Pages (workflow build) + zenodo-publish env (idempotent)"
    echo ""

    confirm || { echo "Aborted."; exit 0; }

    # ----- execute -----
    if [ "$target_exists" = "false" ]; then
        echo "=== Creating $target_repo ==="
        gh repo create "$target_repo" --public --description "Review target for $source_label"
    fi

    if [ "$main_seeded" = "false" ] || [ "$review_exists" = "false" ]; then
        local tmp
        tmp=$(make_temp_dir)

        if [ "$main_seeded" = "false" ]; then
            echo "=== Seeding main from template/bare ==="
            git clone --branch bare --single-branch "git@github.com:$TEMPLATE_REPO.git" "$tmp"
            (
                cd "$tmp"
                git checkout --orphan new-main
                git add -A
                git commit -m "startpoint"
                git remote remove origin
                git remote add origin "git@github.com:$target_repo.git"
                git push origin new-main:main
            )
        fi

        if [ "$review_exists" = "false" ]; then
            echo "=== Building review branch ==="
            if [ "$main_seeded" = "true" ]; then
                # tmp is empty (didn't seed); clone target fresh
                rmdir "$tmp"
                git clone "git@github.com:$target_repo.git" "$tmp"
                CLEANUP_DIRS+=("$tmp")
            fi
            (
                cd "$tmp"
                git fetch origin main
                git fetch "$source_url" "$SOURCE_REF"
                git checkout -B review origin/main
                git rm -rf .
                git checkout FETCH_HEAD -- .
                rm -rf .github/workflows
                # Restore editor-controlled GitHub metadata from bare/main so
                # workflow hardening and CODEOWNERS survive the review merge.
                git checkout origin/main -- .github/workflows
                git checkout origin/main -- .github/CODEOWNERS
                git add -A
                git commit -m "Submission from $source_label

Original repository: $author_url"
                git push origin review
            )
        fi
    fi

    if [ "$pr_open" = "false" ]; then
        echo "=== Opening PR ==="
        local pr_title_name="$AUTHOR_REPO"
        [ "$source_is_github" = "true" ] || pr_title_name="$target_name"
        gh api "repos/$target_repo/pulls" \
            --method POST \
            --field title="Submission: $pr_title_name" \
            --field head="review" \
            --field base="main" \
            --field body="Original repository: $author_url

---

*This PR was created via the Impact Scholars submission workflow.*" \
            --jq '"  ✓ PR: " + .html_url'
    fi

    echo "=== Applying rulesets ==="
    apply_rulesets_to_repo "$target_repo"

    echo ""
    echo "Done: https://github.com/$target_repo"
}

# ---------- subcommand: add-reviewers ----------

cmd_add_reviewers() {
    local target_name="${1:-}"
    [ -n "$target_name" ] || { echo "Error: <target-name> required"; usage; }
    shift
    local reviewers=("$@")
    [ ${#reviewers[@]} -gt 0 ] || { echo "Error: at least one reviewer required"; usage; }

    local target_repo="$ORG/$target_name"

    echo "=== Preflight: add-reviewers $target_repo ==="
    require_gh_auth
    repo_exists "$target_repo" || { echo "Error: $target_repo does not exist"; exit 1; }
    echo "  ✓ target repo exists"

    echo ""
    echo "=== Plan ==="
    for u in "${reviewers[@]}"; do echo "  ○ invite $u as reviewer (permission=push)"; done
    echo ""
    confirm || { echo "Aborted."; exit 0; }

    for u in "${reviewers[@]}"; do
        ensure_push_collaborator "$target_repo" "$u"
    done
}

# ---------- subcommand: promote-authors ----------

cmd_promote_authors() {
    local target_name="${1:-}"
    local author_url="${2:-}"
    [ -n "$target_name" ] || { echo "Error: <target-name> required"; usage; }
    [ -n "$author_url" ] || { echo "Error: <author-repo-url> required"; usage; }

    local target_repo="$ORG/$target_name"
    parse_github_url "$author_url"

    echo "=== Preflight: promote-authors $target_repo ==="
    require_gh_auth
    repo_exists "$target_repo" || { echo "Error: $target_repo does not exist"; exit 1; }
    echo "  ✓ target repo exists"

    local contributors
    contributors=$(gh api "repos/$AUTHOR_USER/$AUTHOR_REPO/contributors" --jq '.[].login' 2>/dev/null || true)
    if [ -z "$contributors" ]; then
        contributors="$AUTHOR_USER"
        echo "  ⚠️  no contributors API result; falling back to author user $AUTHOR_USER"
    fi

    echo ""
    echo "=== Plan ==="
    while IFS= read -r u; do
        [ -z "$u" ] && continue
        echo "  ○ invite $u as author (permission=push)"
    done <<< "$contributors"
    echo ""
    confirm || { echo "Aborted."; exit 0; }

    while IFS= read -r u; do
        [ -z "$u" ] && continue
        ensure_push_collaborator "$target_repo" "$u"
    done <<< "$contributors"
}

# ---------- subcommand: resync-author ----------

cmd_resync_author() {
    local target_name="${1:-}"
    local author_url="${2:-}"
    [ -n "$target_name" ] || { echo "Error: <target-name> required"; usage; }
    [ -n "$author_url" ] || { echo "Error: <author-repo-url> required"; usage; }
    [ "$FORCE" = "true" ] || { echo "Error: resync-author requires --force (force-pushes review, wipes existing review commits)"; exit 1; }

    local target_repo="$ORG/$target_name"
    local source_url source_label
    if is_github_url "$author_url"; then
        parse_github_url "$author_url"
        source_url="https://github.com/$AUTHOR_USER/$AUTHOR_REPO.git"
        source_label="$AUTHOR_USER/$AUTHOR_REPO"
    else
        source_url="$author_url"
        source_label="$author_url"
    fi

    echo "=== Preflight: resync-author $target_repo ==="
    require_gh_auth
    repo_exists "$target_repo" || { echo "Error: $target_repo does not exist"; exit 1; }
    branch_exists "$target_repo" main || { echo "Error: $target_repo has no main branch (run create first)"; exit 1; }
    echo "  ✓ target repo + main exist"

    echo ""
    echo "=== Plan ==="
    echo "  ⚠️  WILL FORCE-PUSH review branch — wipes any existing commits on review"
    echo "  ○ rebuild review from $source_label@$SOURCE_REF on top of $target_repo@main"
    echo ""
    confirm || { echo "Aborted."; exit 0; }

    local tmp
    tmp=$(make_temp_dir)
    rmdir "$tmp"
    git clone "git@github.com:$target_repo.git" "$tmp"
    CLEANUP_DIRS+=("$tmp")
    (
        cd "$tmp"
        git fetch origin main
        git fetch "$source_url" "$SOURCE_REF"
        git checkout -B review origin/main
        git rm -rf .
        git checkout FETCH_HEAD -- .
        rm -rf .github/workflows
        # Restore editor-controlled GitHub metadata from main so workflow
        # hardening and CODEOWNERS survive the review merge.
        git checkout origin/main -- .github/workflows
        git checkout origin/main -- .github/CODEOWNERS
        git add -A
        git commit -m "Resync from $source_label

Original repository: $author_url"
        git push --force origin review
    )

    echo ""
    echo "Done: https://github.com/$target_repo (review force-pushed)"
}

# ---------- subcommand: apply-rulesets ----------

cmd_apply_rulesets() {
    local target_name="${1:-}"
    [ -n "$target_name" ] || { echo "Error: <target-name> required"; usage; }
    local target_repo="$ORG/$target_name"

    echo "=== Preflight: apply-rulesets $target_repo ==="
    require_gh_auth
    repo_exists "$target_repo" || { echo "Error: $target_repo does not exist"; exit 1; }
    echo "  ✓ target repo exists"

    echo ""
    echo "=== Plan ==="
    echo "  ○ grant @$ORG/editors team write access (org-owned repos only)"
    echo "  ○ branch ruleset 'protect-main' on refs/heads/main (require PR; CODEOWNERS review only for workflow changes)"
    echo "  ○ tag ruleset 'editors-only-v-tags' on refs/tags/v* (@$ORG/editors on org repos, repo admins on personal test repos)"
    echo "  ○ enable GitHub Pages (build_type=workflow)"
    echo "  ○ 'zenodo-publish' deployment environment with v* tag policy"
    echo "  (idempotent — existing rulesets/env are skipped if already configured)"
    echo ""
    confirm || { echo "Aborted."; exit 0; }

    echo "=== Applying rulesets ==="
    apply_rulesets_to_repo "$target_repo"
}

# ---------- arg parsing & dispatch ----------

ASSUME_YES=false
FORCE=false
SOURCE_REF="main"
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)      ASSUME_YES=true; shift ;;
        --force)       FORCE=true; shift ;;
        --source-ref)  SOURCE_REF="$2"; shift 2 ;;
        --help|-h)     usage ;;
        *)             ARGS+=("$1"); shift ;;
    esac
done

[ ${#ARGS[@]} -gt 0 ] || usage

SUBCOMMAND="${ARGS[0]}"
ARGS=("${ARGS[@]:1}")

case "$SUBCOMMAND" in
    create)          cmd_create          "${ARGS[@]}" ;;
    add-reviewers)   cmd_add_reviewers   "${ARGS[@]}" ;;
    promote-authors) cmd_promote_authors "${ARGS[@]}" ;;
    resync-author)   cmd_resync_author   "${ARGS[@]}" ;;
    apply-rulesets)  cmd_apply_rulesets  "${ARGS[@]}" ;;
    *) echo "Unknown subcommand: $SUBCOMMAND" >&2; usage ;;
esac

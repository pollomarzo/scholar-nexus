#!/bin/bash
set -eo pipefail

# Impact Scholars Submission Manager
#
# Subcommands:
#   create <author-repo-url> [target-name]
#       Create review target repo, set secrets, seed main, build review branch, open PR.
#       Idempotent: re-running on an existing target skips already-done steps.
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
# Common options:
#   --yes / -y    Skip confirmation prompt (required for non-TTY)
#   --help / -h   Show this help

export GH_PAGER=cat

ORG="pollomarzo"
TEMPLATE_REPO="impact-scholars/isp-micropublication-template"

# ---------- helpers ----------

usage() {
    sed -n '4,22p' "$0" | sed 's/^# \{0,1\}//'
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

# ---------- subcommand: create ----------

cmd_create() {
    local author_url="${1:-}"
    local target_name="${2:-}"
    [ -n "$author_url" ] || { echo "Error: <author-repo-url> required"; usage; }

    parse_github_url "$author_url"

    if [ -z "$target_name" ]; then
        target_name="${AUTHOR_REPO}-$(date +%Y%m%d-%H%M%S)"
    fi
    local target_repo="$ORG/$target_name"

    # ----- preflight -----
    echo "=== Preflight: create $target_repo ==="

    [ -n "$CLOUDFLARE_API_TOKEN" ] || { echo "Error: CLOUDFLARE_API_TOKEN unset in environment"; exit 1; }
    [ -n "$CLOUDFLARE_ACCOUNT_ID" ] || { echo "Error: CLOUDFLARE_ACCOUNT_ID unset in environment"; exit 1; }
    echo "  ✓ cloudflare env vars set"

    require_gh_auth
    local actor
    actor=$(gh api user --jq .login)
    echo "  ✓ gh authenticated as $actor"
    # require_org_membership "$actor"

    local repo_info
    repo_info=$(gh api "repos/$AUTHOR_USER/$AUTHOR_REPO" 2>/dev/null) || {
        echo "Error: author repo not accessible: $AUTHOR_USER/$AUTHOR_REPO (must exist and be public)"
        exit 1
    }
    local visibility
    visibility=$(echo "$repo_info" | jq -r 'if .private then "private" else "public" end')
    [ "$visibility" = "public" ] || { echo "Error: author repo $AUTHOR_USER/$AUTHOR_REPO is $visibility (must be public)"; exit 1; }
    echo "  ✓ author repo $AUTHOR_USER/$AUTHOR_REPO is public"

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
    if [ "$target_exists" = "false" ]; then echo "  ○ target repo: does not exist → will create (private)"; else echo "  ✓ target repo: exists"; fi
    echo "  ○ secrets: will set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID (overwrite)"
    if [ "$main_seeded" = "false" ];   then echo "  ○ main: will seed from template/bare";              else echo "  ✓ main: already seeded (skip)"; fi
    if [ "$review_exists" = "false" ]; then echo "  ○ review: will create from author/main";            else echo "  ✓ review: exists (skip — use resync-author to refresh)"; fi
    if [ "$pr_open" = "false" ];       then echo "  ○ PR: will open review → main";                     else echo "  ✓ PR: already open (skip)"; fi
    echo ""

    confirm || { echo "Aborted."; exit 0; }

    # ----- execute -----
    if [ "$target_exists" = "false" ]; then
        echo "=== Creating $target_repo ==="
        gh repo create "$target_repo" --private --description "Review target for $AUTHOR_USER/$AUTHOR_REPO"
    fi

    echo "=== Setting secrets ==="
    gh secret set CLOUDFLARE_API_TOKEN  --repo "$target_repo" --body "$CLOUDFLARE_API_TOKEN"  >/dev/null && echo "  ✓ CLOUDFLARE_API_TOKEN"
    gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$target_repo" --body "$CLOUDFLARE_ACCOUNT_ID" >/dev/null && echo "  ✓ CLOUDFLARE_ACCOUNT_ID"

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
                git remote add author "https://github.com/$AUTHOR_USER/$AUTHOR_REPO.git" 2>/dev/null || true
                git fetch author main
                git checkout -B review origin/main
                git rm -rf .
                git checkout author/main -- .
                rm -rf .github/workflows
                git checkout origin/main -- .github/workflows/publish.yml
                git add -A
                git commit -m "Submission from $AUTHOR_USER/$AUTHOR_REPO

Original repository: $author_url"
                git push origin review
            )
        fi
    fi

    if [ "$pr_open" = "false" ]; then
        echo "=== Opening PR ==="
        gh api "repos/$target_repo/pulls" \
            --method POST \
            --field title="Submission: $AUTHOR_REPO" \
            --field head="review" \
            --field base="main" \
            --field body="Submitted by @$AUTHOR_USER

Original repository: $author_url

---

*This PR was created via the Impact Scholars submission workflow.*" \
            --jq '"  ✓ PR: " + .html_url'
    fi

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
        if gh api "repos/$target_repo/collaborators/$u" --method PUT --field permission=push >/dev/null 2>&1; then
            echo "  ✓ $u (push)"
        else
            echo "  ⚠️  $u — failed (may already be collaborator at this level)"
        fi
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
        if gh api "repos/$target_repo/collaborators/$u" --method PUT --field permission=push >/dev/null 2>&1; then
            echo "  ✓ $u (push)"
        else
            echo "  ⚠️  $u — failed"
        fi
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
    parse_github_url "$author_url"

    echo "=== Preflight: resync-author $target_repo ==="
    require_gh_auth
    repo_exists "$target_repo" || { echo "Error: $target_repo does not exist"; exit 1; }
    branch_exists "$target_repo" main || { echo "Error: $target_repo has no main branch (run create first)"; exit 1; }
    echo "  ✓ target repo + main exist"

    echo ""
    echo "=== Plan ==="
    echo "  ⚠️  WILL FORCE-PUSH review branch — wipes any existing commits on review"
    echo "  ○ rebuild review from $AUTHOR_USER/$AUTHOR_REPO@main on top of $target_repo@main"
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
        git remote add author "https://github.com/$AUTHOR_USER/$AUTHOR_REPO.git"
        git fetch author main
        git checkout -B review origin/main
        git rm -rf .
        git checkout author/main -- .
        rm -rf .github/workflows
        git checkout origin/main -- .github/workflows/publish.yml
        git add -A
        git commit -m "Resync from $AUTHOR_USER/$AUTHOR_REPO

Original repository: $author_url"
        git push --force origin review
    )

    echo ""
    echo "Done: https://github.com/$target_repo (review force-pushed)"
}

# ---------- arg parsing & dispatch ----------

ASSUME_YES=false
FORCE=false
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)   ASSUME_YES=true; shift ;;
        --force)    FORCE=true; shift ;;
        --help|-h)  usage ;;
        *)          ARGS+=("$1"); shift ;;
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
    *) echo "Unknown subcommand: $SUBCOMMAND" >&2; usage ;;
esac

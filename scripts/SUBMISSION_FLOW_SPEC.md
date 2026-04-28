# Impact Scholars Submission Flow Specification

Companion to `create-submission-target.sh`. Covers the design context and surrounding infrastructure — the script itself is the source of truth for operational details.

## Overview

Authors work in their own public GitHub repositories (created from a template) and submit via a script that opens a PR against a private review target repo in `impact-scholars/`. Collaborator access is added in stages: reviewers after the first preview deploys, authors only after review completes. Merging to `main` publishes to GitHub Pages.

```
┌─────────────┐    ┌──────────────┐    ┌──────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────┐
│  Template   │───▶│ Author repo  │───▶│  create  │───▶│add-reviewers │───▶│promote-authrs│───▶│  Merge  │
│ (main/bare) │    │ (from tmpl)  │    │  + PR    │    │ (after first │    │  (after      │    │ deploys │
│             │    │              │    │ (no ACL) │    │   preview)   │    │   review)    │    │ to Pages│
└─────────────┘    └──────────────┘    └──────────┘    └──────────────┘    └──────────────┘    └─────────┘
```

The script exposes four subcommands, each idempotent and gated by an interactive confirm (`--yes` to skip):

| Subcommand | Purpose | When to run |
|---|---|---|
| `create <author-url> [name]` | Create target repo, set secrets, seed `main`, build `review`, open PR | At submission time |
| `add-reviewers <target> <user>...` | Invite reviewers as `push` collaborators | After the first preview deploys |
| `promote-authors <target> <author-url>` | Invite author repo contributors as `push` | After review concludes |
| `resync-author <target> <author-url> --force` | Force-push fresh author content onto `review` | Only when the author needs to push updates mid-review (footgun: wipes existing review commits) |

## Repository Roles

### Template repo (`impact-scholars/isp-micropublication-template`)
- `main`: full author-facing template with examples and instructions
- `bare`: minimal skeleton (empty frontmatter, placeholder media, 3-line README) carrying the unified `publish.yml` workflow used by review targets

### Author repo
Forked via GitHub's "Use this template" button from `main`. **Must be public** — cross-repo operations (fetching content, contributor queries) require it.

### Review target repo (created by the script)
- `main`: single "startpoint" commit derived from `bare` — no template history
- `review`: author's content applied on top of startpoint; this is the PR branch
- No collaborators at creation. Access is granted in stages via `add-reviewers` and `promote-authors`.

Private during review so reviewer comments and preview URLs aren't public.

## CI/CD

Workflows live on the `bare` branch of the template and get inherited by every review target through `.github/workflows/publish.yml`.

### Trigger behavior

| Event | Jobs | Result |
|---|---|---|
| Pull request | `validate` → `preview` | Preview deployed to Cloudflare Pages, URL posted as sticky PR comment |
| Push to `main` | `validate` → `deploy` | Paper deployed to GitHub Pages |
| Workflow dispatch | `validate` → `deploy` | Manual deployment to GitHub Pages |

### Shared workflows (`impact-scholars/isp-actions-config`)

- **`validate-paper.yml`**: required files (`index.md`, `myst.yml`), frontmatter, thumbnail
- **`deploy-paper.yml`**: base + optional paper-specific conda env, builds exports (PDF, Typst) then HTML. `target` input selects deployment:
  - `pages` (default): uploads artifact and deploys to GitHub Pages; `base_url` defaults to `/${repo-name}`
  - `cloudflare`: deploys `_build/html` to Cloudflare Pages (single project `impact-scholars`, per-PR branch), posts sticky preview comment

### Secrets

Cloudflare credentials (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`) are set as **per-repo secrets** by the script. Org-level secrets would be simpler, but GitHub's free plan does not share org secrets with private repos, so each review target gets its own copy.

## Template `bare` vs `main`

| File | `main` (author template) | `bare` (review target seed) |
|---|---|---|
| `index.md` | Full example content | Empty frontmatter |
| `myst.yml` | 5 example authors | Empty `authors: []` |
| `bib.bib` | Example citation | Comment only |
| `figure.png`, `thumbnails/thumbnail.png` | 2MB examples | 1×1 transparent pixel |
| `README.md` | Full instructions | 3-line credit |
| Workflows | `validate.yml` + `deploy.yml` | `publish.yml` (unified review workflow) |

## Review & publish flow

1. **Submission** (`create`): repo created private, secrets set, `main` seeded from `bare`, `review` built from author content, PR opened. No collaborators yet — preview will deploy from the workflow on the bare-derived branch using injected secrets.
2. **First preview** lands on Cloudflare Pages, URL posted as a sticky PR comment.
3. **Reviewer onboarding** (`add-reviewers`): invite reviewers with `push` so they can comment, edit, and push fixes to `review`.
4. **Author updates mid-review** (optional, `resync-author --force`): force-push refreshed author content onto `review`. Wipes any review-side commits, hence the explicit `--force` and confirm prompt.
5. **Author onboarding** (`promote-authors`): once review is done, invite author repo contributors with `push` so they can publish errata and tag future versions.
6. **Merge** to `main` triggers GitHub Pages deployment — no tag required.
7. **Tag** → Zenodo archive (TODO).

The PR diff shows author additions vs bare skeleton; workflow differences (author repo's `validate.yml`/`deploy.yml` replaced by `bare`'s `publish.yml`) are expected.

## Security notes

1. Public author repos only (enforced by the script) — required for cross-repo ops
2. Review targets are private during review
3. **Staged access**: no collaborators at creation; reviewers added with `push` after first preview; authors added with `push` only after review completes
4. **Secret exposure caveat**: any collaborator who can push to a branch a workflow runs on can read repo secrets via that workflow. Accepted risk — the only secrets stored are scoped Cloudflare Pages credentials. If that ever changes, gate Cloudflare deploys behind a protected Environment with required reviewers.
5. `bare` contains no credentials; secrets are injected per-repo at creation time

## Future enhancements

- [ ] Tag-driven Zenodo archival
- [ ] Support private author repos (requires a bot collaborator invitation)
- [ ] Auto-detect GitHub usernames from `myst.yml` if schema supports it
- [ ] Webhook/GitHub Action version of script for self-service submission
- [ ] Archive/close target repos after publication
- [ ] Move Cloudflare deploys to a protected Environment if the secret blast radius widens

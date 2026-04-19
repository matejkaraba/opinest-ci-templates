# Opinest CI Templates

Reusable GitHub Actions composite actions and workflow templates for Opinest in-house apps.

## Goal

Žiadna Opinest apka v produkcii bez:
- Lint + tests + secret scan na každý PR (B gate)
- AI security review na každý PR
- Auth coverage check (žiadny URL bez auth gate alebo PUBLIC_URLS whitelist)
- Periodic E2E + SAST + DAST + Lighthouse (C gate)
- Auto deploy s post-deploy verifikáciou
- Sentry error tracking
- Server-side hardening (fail2ban, nginx rate limit, ModSecurity, UFW)
- UptimeRobot monitoring
- Slack notifikácie do `#claude-matej`

## Štruktúra

```
.github/actions/
  lint-django/        # ruff + mypy pre Django apky (OpiSys)
  lint-svelte/        # prettier + eslint + tsc pre SvelteKit (OpiReports frontend)
  lint-fastapi/       # ruff + mypy pre FastAPI (DodPDF)
  lint-node/          # eslint + prettier + tsc pre Node (ProTechSocial)
  secret-scan/        # gitleaks v CI (druhá vrstva po pre-commit)
  deps-audit/         # pip-audit / npm audit
  ai-code-review/     # Claude API security-reviewer
  auth-coverage/      # framework-specific auth gate check
  deploy-droplet/     # SSH deploy na DigitalOcean droplet
  post-deploy-verify/ # health check + smoke + anonymous auth crawl
  e2e-playwright/     # E2E tests proti live URL
  slack-notify/       # OpiSys Bot incoming webhook

workflow-templates/
  ci-django.yml       # B gate template pre Django apky
  ci-svelte.yml
  ci-fastapi.yml
  ci-node.yml
  strict.yml          # C gate (manual + cron + label trigger)
  deploy.yml          # auto deploy on push to main + post-deploy verify

scripts/
  harden-droplet.sh   # one-shot server hardening (fail2ban + nginx + ModSecurity + UFW + SSH harden)

docs/
  how-to-adopt.md     # step-by-step adoption guide pre existujúce apky
  how-to-new-app.md   # guide pre nové apky cez new-opinest-app skill
```

## Versioning

Composite actions sú versioned cez git tagy (`v1`, `v2`...). Apky `uses:` ich s pinned tag:

```yaml
- uses: matejkaraba/opinest-ci-templates/.github/actions/lint-django@v1
  with:
    python-version: "3.11"
```

Pri breaking change pridáme nový major tag (v2), apky postupne migrujú.

## Apps using these templates

| App | Status | Stack |
|---|---|---|
| OpiSys | pilot (Phase 2) | Django + Postgres + Docker |
| OpiReports | Phase 3 | Svelte + Python + Docker compose |
| DodPDF | Phase 3 | FastAPI + Postgres |
| ProTechSocial | Phase 3 | Node + Express + Meta API |

## Related

- Design spec: `~/Claude/docs/setup-roadmap/2026-04-19-deploy-security-pipeline-design.md`
- Roadmap: `~/Claude/docs/setup-roadmap/2026-04-19-claude-setup-roadmap.md`
- Owner: matej.karaba@opinest.com

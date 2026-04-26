#!/bin/bash
set -e

RETROFIT_DIR=/tmp/retrofit
BRANCH_NAME="chore/ci-scanners"

# Define scanners block per repo (special case: opireports has two Dockerfiles)
inject_scanners_block() {
  local repo=$1
  if [ "$repo" = "opireports" ]; then
    cat <<'EOF'
  scanners-backend:
    uses: matejkaraba/opinest-ci-templates/.github/workflows/scanners.yml@v1
    secrets: inherit
    with:
      dockerfile-path: Dockerfile.backend
      severity: "CRITICAL,HIGH"

  scanners-frontend:
    uses: matejkaraba/opinest-ci-templates/.github/workflows/scanners.yml@v1
    secrets: inherit
    with:
      dockerfile-path: Dockerfile.frontend
      severity: "CRITICAL,HIGH"
      semgrep-configs: "p/owasp-top-ten p/security-audit p/javascript p/typescript"

EOF
  else
    cat <<'EOF'
  scanners:
    uses: matejkaraba/opinest-ci-templates/.github/workflows/scanners.yml@v1
    secrets: inherit
    with:
      dockerfile-path: Dockerfile
      severity: "CRITICAL,HIGH"

EOF
  fi
}

hadolint_precommit_block() {
  cat <<'EOF'

  - repo: https://github.com/hadolint/hadolint
    rev: v2.13.0-beta
    hooks:
      - id: hadolint-docker
        args: ['--ignore', 'DL3008', '--ignore', 'DL3013', '--failure-threshold', 'warning']
EOF
}

for REPO in opireports opisys dodpdf protechsocial playvento; do
  echo "=============================="
  echo "=== Processing: $REPO"
  echo "=============================="
  cd "$RETROFIT_DIR/$REPO"
  BRANCH=$(cat default-branch.txt)

  # 1. Build modified ci.yml — insert scanners block right after "jobs:" line
  inject_scanners_block "$REPO" > scanners-block.yml
  python -c "
import sys
with open('ci.yml') as f:
    lines = f.read().split('\n')
with open('scanners-block.yml') as f:
    block_lines = f.read().rstrip('\n').split('\n')
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.rstrip() == 'jobs:':
        for bl in block_lines:
            out.append(bl)
        inserted = True
if not inserted:
    sys.stderr.write('ERROR: no jobs: line found\n')
    sys.exit(1)
with open('ci.modified.yml', 'w') as f:
    f.write('\n'.join(out))
"

  # 2. Build modified pre-commit — append hadolint block
  cp pre-commit.yaml pre-commit.modified.yaml
  hadolint_precommit_block >> pre-commit.modified.yaml

  # 3. Get current main SHA
  SHA=$(gh api "repos/matejkaraba/$REPO/git/refs/heads/$BRANCH" --jq '.object.sha')
  echo "  base sha: ${SHA:0:8}"

  # 4. Create feature branch
  gh api --method POST "repos/matejkaraba/$REPO/git/refs" \
    -f ref="refs/heads/$BRANCH_NAME" -f sha="$SHA" > /dev/null 2>&1 || \
    gh api --method PATCH "repos/matejkaraba/$REPO/git/refs/heads/$BRANCH_NAME" \
      -f sha="$SHA" -F force=true > /dev/null
  echo "  branch: $BRANCH_NAME"

  # 5. Upload ci.yml
  CI_SHA=$(gh api "repos/matejkaraba/$REPO/contents/.github/workflows/ci.yml" --jq '.sha')
  gh api --method PUT "repos/matejkaraba/$REPO/contents/.github/workflows/ci.yml" \
    -f message="feat(ci): add scanners job (hadolint + semgrep + trivy fs + trivy image)" \
    -f content="$(base64 -w0 ci.modified.yml)" \
    -f branch="$BRANCH_NAME" \
    -f sha="$CI_SHA" > /dev/null
  echo "  ci.yml: updated"

  # 6. Upload pre-commit
  PC_SHA=$(gh api "repos/matejkaraba/$REPO/contents/.pre-commit-config.yaml" --jq '.sha')
  gh api --method PUT "repos/matejkaraba/$REPO/contents/.pre-commit-config.yaml" \
    -f message="feat(pre-commit): add hadolint Dockerfile lint hook" \
    -f content="$(base64 -w0 pre-commit.modified.yaml)" \
    -f branch="$BRANCH_NAME" \
    -f sha="$PC_SHA" > /dev/null
  echo "  pre-commit: updated"

  # 7. Open PR
  PR_URL=$(gh pr create --repo "matejkaraba/$REPO" --head "$BRANCH_NAME" --base "$BRANCH" \
    --title "feat(ci): add B gate scanners (hadolint + semgrep + trivy)" \
    --body "## Čo pridáva

- **scanners** job v ci.yml → volá reusable workflow \`matejkaraba/opinest-ci-templates/.github/workflows/scanners.yml@v1\`
- **hadolint-docker** hook v .pre-commit-config.yaml

## Štyri paralelné kontroly po merge-i
1. **dockerfile-lint** (hadolint) — best practices v Dockerfile-i
2. **sast-scan** (Semgrep) — OWASP Top 10 + stack rulesets (python, django, js, ts, dockerfile)
3. **filesystem-scan** (Trivy fs) — CVE v deps (CRITICAL + HIGH, ignore-unfixed)
4. **container-scan** (Trivy image) — CVE v Docker image po build-e

## Prečo

Doteraz CI mal iba lint + secret-scan + test + build. Chýbali: CVE v deps, CVE v image, OWASP vulns v kóde, Dockerfile best practices. Playvento incident 2026-04-19 — 3 critical + 6 important bugs zistené 2 dni po deploye — ukázal cenu skippingu tejto vrstvy.

## Výhoda shared workflow

Scanners sú definované **raz** v \`opinest-ci-templates/scanners.yml\`. Update scannerov (nové rulesety, verzie tools) = 1× zmena + retag @v1 → propaguje sa do všetkých apiek automaticky. Jeden proces vsade.

## Čo očakávať pri prvom behu

Je možné že Semgrep/Trivy zachytia existujúce nálezy v kóde/deps. V tom prípade:
- **Critical CVE v deps** → update deps (Dependabot auto-PR pondelok)
- **False positive v Semgrep** → pridaj do \`.semgrepignore\`
- **Dockerfile warning** → zvyčajne rýchly fix (napr. \`--no-install-recommends\`)

CI môže zlyhať na prvom behu — to je očakávané a value, nie bug. Spolu si to doladíme v follow-up commitoch na túto branch pred merge.

## Secrets (voliteľné, CI zbehne aj bez nich)

- \`SEMGREP_APP_TOKEN\` — bez neho Semgrep zbehne local-only, findings iba v GHA logu" 2>&1)
  echo "  PR: $PR_URL"
done

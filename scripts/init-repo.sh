#!/usr/bin/env bash
# init-repo.sh
#
# One-shot: initialize local git repo, verify the tree is clean of secrets,
# create the public GitHub repo, and push. Only run this after all secrets
# are safely in SSM (not in the tree) and .gitignore has been reviewed.
#
# Idempotent: if the local repo is already initialized and pushed, it will
# not force anything — it just verifies state and prints a summary.
#
# Required tools: git, gh
# Required auth : gh auth login  (browser device flow) — done once
#
# Environment:
#   REPO_NAME    — default: smartops-lite
#   REPO_VIS     — default: public   (values: public|private)
#   REPO_OWNER   — default: whoever `gh` is authenticated as
#
# Usage:
#   bash scripts/init-repo.sh
#   bash scripts/init-repo.sh --dry-run    # print what it would do
set -euo pipefail

REPO_NAME="${REPO_NAME:-smartops-lite}"
REPO_VIS="${REPO_VIS:-public}"
DRY_RUN=0

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

# ---- 0. Sanity -------------------------------------------------------------

for t in git gh; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found in PATH. Run scripts/setup-wsl.sh first."
done

# Verify we're at repo root (Makefile + README.md are both present)
if [ ! -f Makefile ] || [ ! -f README.md ]; then
  die "Run this from the smartops-lite/ root directory."
fi

gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"

REPO_OWNER="${REPO_OWNER:-$(gh api user --jq '.login')}"
say "Repo target: ${REPO_OWNER}/${REPO_NAME} (visibility: $REPO_VIS)"

# ---- 1. Scan for likely secrets before committing --------------------------

say "Scanning working tree for likely secrets"
# Patterns that should never appear in git. This is a safety net, not a substitute
# for a proper secret scanner in CI.
BAD_PATTERNS=(
  'AKIA[0-9A-Z]{16}'                                        # AWS access key id
  'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+=]{35,}' # AWS secret
  'gsk_[A-Za-z0-9]{40,}'                                    # Groq API key
  'xox[baprs]-[0-9A-Za-z-]{10,}'                            # Slack tokens
  'hooks\.slack\.com/services/T[A-Z0-9]{8,}/B[A-Z0-9]{8,}'  # Slack webhook URL
  '-----BEGIN (RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY-----' # private keys
)

# Enumerate every file in the tree except obvious noise. We scan the working
# tree directly (not `git ls-files`) so this works even before `git init`.
# We also exclude files listed in .gitignore *by pattern* — .backend-values,
# .env, and scripts/.*.tmp — because those legitimately hold secrets but are
# git-ignored.
BAD_HITS=0
while IFS= read -r -d '' file; do
  for pat in "${BAD_PATTERNS[@]}"; do
    if grep -HEn "$pat" "$file" 2>/dev/null; then
      BAD_HITS=$((BAD_HITS+1))
    fi
  done
done < <(find . -type f \
    -not -path './.git/*' \
    -not -path './.terraform/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/.venv/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    -not -name '.backend-values' \
    -not -name '.env' \
    -not -name '.env.local' \
    -not -name '.env.*.local' \
    -not -name '*.tmp' \
    -not -name '*.log' \
    -print0)

if [ "$BAD_HITS" -gt 0 ]; then
  die "Secret-like content found. Fix and re-run. (${BAD_HITS} match(es) above.)"
fi
ok "No obvious secrets in the working tree"

# ---- 2. Initialize local git repo if needed -------------------------------

if [ ! -d .git ]; then
  say "Initializing local git repo (main branch)"
  [ "$DRY_RUN" -eq 0 ] && git init -b main
  ok "git init done"
else
  ok "Local git repo already initialized"
fi

# Configure user identity if not set globally
if ! git config user.email >/dev/null 2>&1 && ! git config --global user.email >/dev/null 2>&1; then
  warn "git user.email not configured. Set it before committing:"
  echo "     git config --global user.email 'you@example.com'"
  echo "     git config --global user.name  'Your Name'"
  exit 1
fi

# ---- 3. Stage + commit if there are changes -------------------------------

if [ -z "$(git status --porcelain)" ]; then
  ok "Working tree clean — nothing to commit"
else
  say "Staging and committing"
  if [ "$DRY_RUN" -eq 0 ]; then
    git add .
    git commit -m "chore(module-0): initial scaffold + local dev environment"
    ok "Committed"
  else
    warn "(dry-run) would git add . && git commit"
  fi
fi

# ---- 4. Create or verify GitHub repo --------------------------------------

if gh repo view "${REPO_OWNER}/${REPO_NAME}" >/dev/null 2>&1; then
  ok "GitHub repo ${REPO_OWNER}/${REPO_NAME} already exists"
else
  say "Creating GitHub repo ${REPO_OWNER}/${REPO_NAME} (${REPO_VIS})"
  if [ "$DRY_RUN" -eq 0 ]; then
    gh repo create "${REPO_OWNER}/${REPO_NAME}" \
      --"${REPO_VIS}" \
      --description "GenAI-assisted Kubernetes incident triage on AWS free tier"
    ok "Repo created"
  else
    warn "(dry-run) would gh repo create"
  fi
fi

# ---- 5. Wire remote + push ------------------------------------------------

if ! git remote get-url origin >/dev/null 2>&1; then
  say "Adding remote origin"
  [ "$DRY_RUN" -eq 0 ] && git remote add origin "git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
  ok "origin added (SSH URL)"
else
  ok "origin already configured: $(git remote get-url origin)"
fi

say "Pushing to origin/main"
if [ "$DRY_RUN" -eq 0 ]; then
  git push -u origin main
  ok "Pushed"
else
  warn "(dry-run) would git push -u origin main"
fi

echo ""
ok "Repo bootstrap complete."
echo ""
echo "Visit: https://github.com/${REPO_OWNER}/${REPO_NAME}"

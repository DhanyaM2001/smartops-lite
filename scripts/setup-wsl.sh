#!/usr/bin/env bash
# setup-wsl.sh
#
# One-shot idempotent installer for the SmartOps-Lite WSL toolchain
# (Ubuntu 24.04.1 LTS). Safe to re-run — each tool is skipped if
# already present at a compatible version.
#
# Installs: aws-cli v2, terraform (via tfenv, pinned 1.7.5), kubectl 1.29,
# helm 3, k3sup, gh, poetry (via pipx), jq, yq, unzip, python3-venv/pip/pipx.
#
# Never touches ~/.aws, ~/.kube, or any SSM parameter.
#
# Usage:
#   bash scripts/setup-wsl.sh

set -euo pipefail

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}✔${RESET} %s\n"  "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n"  "$*"; }
die()  { printf "${RED}✘${RESET} %s\n" "$*" >&2; exit 1; }

need_sudo() {
  if ! sudo -n true 2>/dev/null; then
    warn "sudo password may be prompted for apt/install steps"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# -------- 0. Sanity ----------------------------------------------------------

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  die "This script targets Ubuntu (WSL). Detected non-Ubuntu OS."
fi

DISTRO_VER=$(. /etc/os-release; echo "${VERSION_ID:-unknown}")
say "Distro: Ubuntu ${DISTRO_VER}"

need_sudo

# -------- 1. Base apt packages ----------------------------------------------

say "Installing base apt packages (git, curl, unzip, build tools, python venv/pipx, jq)"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git curl unzip build-essential make ca-certificates \
  python3 python3-venv python3-pip pipx \
  jq wget gnupg apt-transport-https software-properties-common
ok "base packages"

# -------- 2. AWS CLI v2 ------------------------------------------------------

if have aws && aws --version 2>&1 | grep -q 'aws-cli/2'; then
  ok "aws-cli already installed: $(aws --version 2>&1)"
else
  say "Installing AWS CLI v2"
  tmpdir=$(mktemp -d)
  ( cd "$tmpdir" && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && \
    unzip -q awscliv2.zip && \
    sudo ./aws/install --update )
  rm -rf "$tmpdir"
  ok "aws-cli installed: $(aws --version 2>&1)"
fi

# -------- 3. tfenv + Terraform 1.7.5 ----------------------------------------

if [ ! -d "$HOME/.tfenv" ]; then
  say "Cloning tfenv"
  git clone --depth=1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
fi

# Ensure PATH is set for current shell + future shells
if ! grep -q 'tfenv/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.tfenv/bin:$PATH"

if have terraform && terraform version | head -n1 | grep -q '1\.7\.5'; then
  ok "terraform 1.7.5 already installed"
else
  say "Installing Terraform 1.7.5 via tfenv"
  tfenv install 1.7.5 >/dev/null
  tfenv use 1.7.5
  ok "terraform installed: $(terraform version | head -n1)"
fi

# -------- 4. kubectl 1.29 ----------------------------------------------------

if have kubectl && kubectl version --client 2>/dev/null | grep -q 'v1.29'; then
  ok "kubectl 1.29 already installed"
else
  say "Installing kubectl 1.29"
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl"
  sudo install -m 0755 "$tmp" /usr/local/bin/kubectl
  rm -f "$tmp"
  ok "kubectl installed: $(kubectl version --client 2>/dev/null | head -n1)"
fi

# -------- 5. Helm 3 ----------------------------------------------------------

if have helm; then
  ok "helm already installed: $(helm version --short 2>/dev/null)"
else
  say "Installing Helm 3"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "helm installed: $(helm version --short 2>/dev/null)"
fi

# -------- 6. k3sup -----------------------------------------------------------

if have k3sup; then
  ok "k3sup already installed: $(k3sup version 2>/dev/null | head -n1)"
else
  say "Installing k3sup"
  # k3sup's installer drops ./k3sup in the current dir. Use a tempdir so we
  # never litter the caller's cwd (which may be the repo root).
  k3sup_tmp=$(mktemp -d)
  ( cd "$k3sup_tmp" && curl -sfLS https://get.k3sup.dev | sh )
  if [ -f "$k3sup_tmp/k3sup" ]; then
    sudo install -m 0755 "$k3sup_tmp/k3sup" /usr/local/bin/k3sup
  fi
  rm -rf "$k3sup_tmp"
  ok "k3sup installed: $(k3sup version 2>/dev/null | head -n1)"
fi

# -------- 7. GitHub CLI ------------------------------------------------------

if have gh; then
  ok "gh already installed: $(gh --version | head -n1)"
else
  say "Installing GitHub CLI (gh)"
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y gh
  ok "gh installed: $(gh --version | head -n1)"
fi

# -------- 8. Poetry (via pipx) ----------------------------------------------

pipx ensurepath >/dev/null 2>&1 || true
# Reload PATH from bashrc without spawning subshell for the tests below
export PATH="$HOME/.local/bin:$PATH"

if have poetry; then
  ok "poetry already installed: $(poetry --version 2>/dev/null)"
else
  say "Installing Poetry via pipx"
  pipx install poetry
  ok "poetry installed: $(poetry --version 2>/dev/null)"
fi

# -------- 9. yq --------------------------------------------------------------

if have yq; then
  ok "yq already installed: $(yq --version 2>/dev/null)"
else
  say "Installing yq"
  YQ_VERSION="v4.44.3"
  sudo curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
  sudo chmod +x /usr/local/bin/yq
  ok "yq installed: $(yq --version 2>/dev/null)"
fi

# -------- 10. kind (for `make local-up`) -------------------------------------
# Local kind cluster is the zero-cost, no-AWS demo path (scripts/local-up.sh).
# docs/INSTALL.md (Appendix A) tells users `kind` is installed by
# `make setup`, so it must be here too.

if have kind; then
  ok "kind already installed: $(kind --version 2>/dev/null)"
else
  say "Installing kind"
  KIND_VERSION="v0.23.0"
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  sudo install -m 0755 "$tmp" /usr/local/bin/kind
  rm -f "$tmp"
  ok "kind installed: $(kind --version 2>/dev/null)"
fi

# -------- 11. AWS Session Manager plugin (for `make kube-api-tunnel`) --------
# The K3s API has no public ingress; `aws ssm start-session` port-forwarding
# is the only way in, and it needs this plugin.

if have session-manager-plugin; then
  ok "session-manager-plugin already installed: $(session-manager-plugin --version 2>/dev/null)"
else
  say "Installing AWS Session Manager plugin"
  tmp=$(mktemp --suffix=.deb)
  curl -fsSL -o "$tmp" \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"
  sudo dpkg -i "$tmp"
  rm -f "$tmp"
  ok "session-manager-plugin installed: $(session-manager-plugin --version 2>/dev/null)"
fi

# -------- 12. Summary --------------------------------------------------------

echo ""
say "Version summary"
for cmd in aws terraform kubectl helm k3sup gh poetry python3 jq yq kind session-manager-plugin docker git make curl; do
  if have "$cmd"; then
    printf "  %-10s %s\n" "$cmd" "$($cmd --version 2>&1 | head -n1)"
  else
    printf "  %-10s ${RED}MISSING${RESET}\n" "$cmd"
  fi
done

echo ""
ok "WSL toolchain setup complete."
echo ""
echo "Next steps:"
echo "  1) gh auth login"
echo "  2) aws configure --profile smartops   (paste keys from IAM user smartops-cli)"
echo "  3) Bootstrap Terraform backend (S3 + DynamoDB): make bootstrap-backend  (see docs/INSTALL.md section 4)"
echo "  4) Put Slack + Groq secrets in SSM Parameter Store: make put-secrets    (see docs/INSTALL.md section 4)"

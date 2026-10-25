#!/usr/bin/env bash
# Render every Mermaid diagram (docs/*.mmd and the ```mermaid blocks in
# README.md) with mermaid-cli, so a syntax error fails CI instead of showing
# up as a broken diagram on GitHub. Needs node/npx; MERMAID_CLI_VERSION pins
# @mermaid-js/mermaid-cli. SVGs land in OUT_DIR (default: a temp dir).
set -euo pipefail

: "${MERMAID_CLI_VERSION:?set MERMAID_CLI_VERSION, e.g. 12.0.0}"
REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR=${OUT_DIR:-$(mktemp -d)}
mkdir -p "${OUT_DIR}"
cd "${REPO_DIR}"

# --no-sandbox: GitHub's ubuntu runners don't allow Chromium's user-namespace sandbox
mmdc() {
    npx --yes "@mermaid-js/mermaid-cli@${MERMAID_CLI_VERSION}" \
        --puppeteerConfigFile scripts/ci/puppeteer.json --quiet "$@"
}

for src in docs/*.mmd; do
    echo "==> ${src}"
    mmdc -i "${src}" -o "${OUT_DIR}/$(basename "${src}" .mmd).svg"
done

# Markdown input renders each mermaid block to README-<n>.svg
blocks=$(grep -c '^```mermaid' README.md || true)
echo "==> README.md (${blocks} mermaid block(s))"
mmdc -i README.md -o "${OUT_DIR}/README.md"
rendered=$(find "${OUT_DIR}" -name 'README-*.svg' | wc -l | tr -d ' ')
if [ "${rendered}" != "${blocks}" ]; then
    echo "ERROR: README.md has ${blocks} mermaid block(s) but ${rendered} rendered" >&2
    exit 1
fi

echo ""
echo "all diagrams render; SVGs in ${OUT_DIR}"

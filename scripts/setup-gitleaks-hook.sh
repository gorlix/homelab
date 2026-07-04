#!/usr/bin/env bash
# Setup gitleaks come pre-commit hook.
# Da eseguire una volta, dalla root del repo, dopo `git init`.
set -euo pipefail

if ! command -v gitleaks &> /dev/null; then
    echo "gitleaks non trovato. Installazione..."
    if command -v brew &> /dev/null; then
        brew install gitleaks
    else
        echo "Installa gitleaks manualmente: https://github.com/gitleaks/gitleaks#installing"
        exit 1
    fi
fi

mkdir -p .git/hooks

cat > .git/hooks/pre-commit << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Controllo segreti con gitleaks..."
if ! gitleaks protect --staged --verbose; then
    echo ""
    echo "❌ gitleaks ha rilevato un possibile segreto nello staged commit."
    echo "   Rimuovilo prima di committare (usa 1Password op:// invece del valore reale)."
    exit 1
fi
EOF

chmod +x .git/hooks/pre-commit

echo "✅ Pre-commit hook installato in .git/hooks/pre-commit"
echo "   Da questo momento ogni 'git commit' verrà scansionato da gitleaks."

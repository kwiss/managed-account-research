#!/bin/bash
# Setup script for ManagedAccount Research Project

set -e

echo "🚀 Setting up ManagedAccount Research Project..."

# Create project structure
mkdir -p docs/research-notes
mkdir -p repos
mkdir -p prototypes/{safe-zodiac,safe-7579,kernel}
mkdir -p analysis

# Move docs if they exist in current dir
[ -f "ManagedAccounts.pdf" ] && mv ManagedAccounts.pdf docs/
[ -f "managed-account-architecture-analysis.md" ] && mv managed-account-architecture-analysis.md docs/architecture-analysis.md

echo "📦 Cloning key repositories..."

cd repos

# Safe ecosystem
echo "  → safe-smart-account..."
git clone --depth 1 https://github.com/safe-global/safe-smart-account 2>/dev/null || echo "    (already exists)"

echo "  → safe-modules (includes Safe7579)..."
git clone --depth 1 https://github.com/safe-global/safe-modules 2>/dev/null || echo "    (already exists)"

# Rhinestone (ERC-7579 modules)
echo "  → rhinestone core-modules..."
git clone --depth 1 https://github.com/rhinestonewtf/core-modules 2>/dev/null || echo "    (already exists)"

echo "  → rhinestone modulekit..."
git clone --depth 1 https://github.com/rhinestonewtf/modulekit 2>/dev/null || echo "    (already exists)"

# ZeroDev Kernel
echo "  → zerodev kernel..."
git clone --depth 1 https://github.com/zerodevapp/kernel 2>/dev/null || echo "    (already exists)"

# Zodiac (Gnosis Guild)
echo "  → zodiac-modifier-roles..."
git clone --depth 1 https://github.com/gnosisguild/zodiac-modifier-roles 2>/dev/null || echo "    (already exists)"

echo "  → zodiac-module-delay..."
git clone --depth 1 https://github.com/gnosisguild/zodiac-module-delay 2>/dev/null || echo "    (already exists)"

# Pimlico
echo "  → pimlico alto bundler..."
git clone --depth 1 https://github.com/pimlicolabs/alto 2>/dev/null || echo "    (already exists)"

echo "  → permissionless.js..."
git clone --depth 1 https://github.com/pimlicolabs/permissionless.js 2>/dev/null || echo "    (already exists)"

# ERC-4337 reference
echo "  → account-abstraction (ERC-4337 reference)..."
git clone --depth 1 https://github.com/eth-infinitism/account-abstraction 2>/dev/null || echo "    (already exists)"

cd ..

echo ""
echo "✅ Project structure created:"
echo ""
find . -type d -maxdepth 3 | head -30
echo ""
echo "📝 Next steps:"
echo "   1. Add ManagedAccounts.pdf to docs/"
echo "   2. Add architecture-analysis.md to docs/"
echo "   3. Start researching with: claude"
echo ""
echo "🔍 Suggested first research commands:"
echo "   - Review Safe7579: cat repos/safe-modules/modules/4337/README.md"
echo "   - Review Kernel: cat repos/kernel/README.md"
echo "   - Review Zodiac Roles: cat repos/zodiac-modifier-roles/README.md"

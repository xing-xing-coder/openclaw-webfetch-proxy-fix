#!/usr/bin/env bash
set -euo pipefail

DIST_PATH="${1:-}"

if [ -z "$DIST_PATH" ]; then
  for candidate in \
    "$HOME/.npm-global/lib/node_modules/openclaw/dist" \
    "$HOME/.npm/lib/node_modules/openclaw/dist" \
    "$HOME/.local/share/npm/node_modules/openclaw/dist" \
    "$(npm root -g 2>/dev/null)/openclaw/dist" \
    "$HOME/.openclaw/node_modules/openclaw/dist"; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      DIST_PATH="$candidate"
      break
    fi
  done
fi

if [ -z "$DIST_PATH" ] || [ ! -d "$DIST_PATH" ]; then
  echo "[ERROR] Cannot find OpenClaw dist directory."
  echo ""
  echo "Try one of these:"
  echo "  ./patch-openclaw-proxy.sh ~/.npm-global/lib/node_modules/openclaw/dist"
  echo "  ./patch-openclaw-proxy.sh \"\$(npm root -g)/openclaw/dist\""
  echo ""
  echo "If using systemd --user, check:"
  echo "  systemctl --user cat openclaw-gateway"
  exit 1
fi

echo "============================================"
echo " OpenClaw web_fetch Proxy Patch"
echo "============================================"
echo "Target: $DIST_PATH"
echo "Compatible version: OpenClaw 2026.3.13"
echo

PATCHED=0
BACKUPS=0

backup_file() {
  local f="$1"
  if [ ! -f "${f}.bak_proxy_patch" ]; then
    cp "$f" "${f}.bak_proxy_patch"
    BACKUPS=$((BACKUPS + 1))
  fi
}

patch_with_python() {
  local file="$1"
  local mode="$2"

  backup_file "$file"

  FILE_PATH="$file" PATCH_MODE="$mode" python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["FILE_PATH"])
mode = os.environ["PATCH_MODE"]
text = path.read_text(encoding="utf-8")
orig = text
changed = False

if mode == "ac":
    text2 = re.sub(
        r'(timeoutSeconds:\s*params\.timeoutSeconds,\s*)(init:\s*\{\s*headers:\s*\{)',
        r'\1useEnvProxy: true,\n                    \2',
        text,
    )
    if text2 != text:
        text = text2
        changed = True

    text2 = re.sub(
        r'return await withWebToolsNetworkGuard\(params,\s*run\);',
        r'return await withWebToolsNetworkGuard({ ...params, useEnvProxy: true }, run);',
        text,
    )
    if text2 != text:
        text = text2
        changed = True

elif mode == "b":
    pattern = re.compile(
        r'''
        let\ dispatcher\ =\ null;\s*
        try\ \{\s*
        const\ pinned\ =\ await\ resolvePinnedHostnameWithPolicy\(parsedUrl\.hostname,\s*\{\s*
        lookupFn:\s*params\.lookupFn,\s*
        policy:\s*params\.policy\s*
        \}\);\s*
        if\ \(mode\ ===\ GUARDED_FETCH_MODE\.TRUSTED_ENV_PROXY\ &&\ hasProxyEnvConfigured\(\)\)\ dispatcher\ =\ new\ EnvHttpProxyAgent\(\);\s*
        else\ if\ \(params\.pinDns\ !==\ false\)\ dispatcher\ =\ createPinnedDispatcher\(pinned,\s*params\.dispatcherPolicy\);
        ''',
        re.X | re.S,
    )

    replacement = """let dispatcher = null;
            try {
                    if (mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured()) dispatcher = new EnvHttpProxyAgent();
                    else {
                            const pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {
                                    lookupFn: params.lookupFn,
                                    policy: params.policy
                            });
                            if (params.pinDns !== false) dispatcher = createPinnedDispatcher(pinned, params.dispatcherPolicy);
                    }"""

    text2, n = pattern.subn(replacement, text, count=1)
    if n:
        text = text2
        changed = True

if changed and text != orig:
    path.write_text(text, encoding="utf-8")
    print("PATCHED")
else:
    print("UNCHANGED")
PY
}

echo "[1/3] Patch A/C ..."
while IFS= read -r -d '' file; do
  if grep -q 'withWebToolsNetworkGuard' "$file"; then
    if [ "$(patch_with_python "$file" "ac" | tail -n1)" = "PATCHED" ]; then
      echo "  + $(basename "$file")"
      PATCHED=$((PATCHED + 1))
    fi
  fi
done < <(find "$DIST_PATH" -type f -name "*.js" ! -name "*.bak_proxy_patch*" -print0)

echo
echo "[2/3] Patch B ..."
while IFS= read -r -d '' file; do
  if grep -q 'resolvePinnedHostnameWithPolicy' "$file" && \
     grep -q 'EnvHttpProxyAgent' "$file" && \
     grep -q 'TRUSTED_ENV_PROXY' "$file"; then
    if [ "$(patch_with_python "$file" "b" | tail -n1)" = "PATCHED" ]; then
      echo "  + $(basename "$file")"
      PATCHED=$((PATCHED + 1))
    fi
  fi
done < <(find "$DIST_PATH" -type f -name "*.js" ! -name "*.bak_proxy_patch*" -print0)

echo
echo "[3/3] Restart ..."
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway

echo
echo "============================================"
echo "Done"
echo "============================================"
echo "Backups created: $BACKUPS"
echo "Files patched : $PATCHED"
echo
echo "Check only live files (exclude backups):"
echo "grep -R -n -C 6 --exclude='*.bak_proxy_patch*' 'TRUSTED_ENV_PROXY' '$DIST_PATH/plugin-sdk'"
echo
echo "Notes:"
echo "- Default proxy ports differ by client; verify your own HTTP/HTTPS proxy port."
echo "- Clash Verge Rev / Mihomo often uses 7897."
echo "- v2rayN often uses 10808."
echo "- Official fix may land in PR #40354 later; then this script may no longer be needed."

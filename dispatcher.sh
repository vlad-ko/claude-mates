#!/bin/bash
# Claude Mates Dispatcher
# Reads .claude-mates.yml and runs the requested mate(s)

set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-.claude-mates.yml}"
MATE_NAME="${MATE_NAME:-all}"
MATES_ROOT="${MATES_ROOT:-.}"

echo "=== Claude Mates Dispatcher ==="
echo "Mate: $MATE_NAME"
echo "Config: $CONFIG_PATH"
echo "Mates root: $MATES_ROOT"

# Check config exists
if [ ! -f "$CONFIG_PATH" ]; then
  echo "::warning::No .claude-mates.yml found at $CONFIG_PATH — using defaults"
fi

# Determine which mates to run
if [ "$MATE_NAME" = "all" ]; then
  MATES=("docs" "security" "dead-code" "tests" "logic")
else
  MATES=("$MATE_NAME")
fi

# Run each mate
RESULTS=()
for mate in "${MATES[@]}"; do
  MATE_DIR="$MATES_ROOT/mates/$mate"

  if [ ! -d "$MATE_DIR" ]; then
    echo "::warning::Mate '$mate' not found at $MATE_DIR — skipping"
    continue
  fi

  # Check if mate is enabled in config
  if [ -f "$CONFIG_PATH" ]; then
    ENABLED=$(python3 -c "
import yaml, sys
try:
    with open('$CONFIG_PATH') as f:
        config = yaml.safe_load(f)
    mate_config = config.get('mates', {}).get('$mate', {})
    print('true' if mate_config.get('enabled', True) else 'false')
except:
    print('true')
" 2>/dev/null || echo "true")

    if [ "$ENABLED" = "false" ]; then
      echo "Mate '$mate' is disabled in config — skipping"
      continue
    fi
  fi

  echo ""
  echo "=== Running mate: $mate ==="
  bash "$MATES_ROOT/runner.sh" "$mate" "$MATE_DIR" "$CONFIG_PATH" && \
    RESULTS+=("$mate:success") || \
    RESULTS+=("$mate:failure")
done

# Summary
echo ""
echo "=== Dispatcher Summary ==="
for result in "${RESULTS[@]}"; do
  echo "  $result"
done

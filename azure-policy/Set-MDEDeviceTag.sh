#!/bin/bash
# =============================================================================
# Set-MDEDeviceTag.sh
# Configures Microsoft Defender for Endpoint device tag on Linux
#
# This script creates/updates the MDE managed configuration file to apply
# a device tag. The tag is used by MDE to organize devices into Device Groups
# for applying differentiated security policies.
#
# Usage:
#   sudo bash Set-MDEDeviceTag.sh <TAG_VALUE>
#
# Example:
#   sudo bash Set-MDEDeviceTag.sh PRODUCTION
#
# Method:
#   Writes the edr.tags section in /etc/opt/microsoft/mdatp/managed/mdatp_managed.json
#   with key=GROUP and value=<TAG_VALUE>
#
# Supported distros:
#   Ubuntu 16.04+, RHEL 7.2+, CentOS 7.2+, Debian 9+, SLES 12+,
#   Oracle Linux 7.2+, Amazon Linux 2, Fedora 33+, Rocky 8.7+, Alma 8.4+
#
# Reference:
#   https://learn.microsoft.com/en-us/defender-endpoint/linux-preferences
#   https://learn.microsoft.com/en-us/defender-endpoint/machine-tags
#
# Notes:
#   - Requires root privileges (writes to /etc/opt/microsoft/mdatp/managed/)
#   - Requires Python 3 or Python 2.7+ (for JSON manipulation)
#   - Preserves existing mdatp_managed.json settings (antivirus, cloud, etc.)
#   - Uses atomic write (temp file + rename) to prevent corruption
#   - The tag syncs with MDE on the next agent check-in
# =============================================================================

set -euo pipefail

TAG_VALUE="${1:-}"

# --- Input Validation ---

if [ -z "$TAG_VALUE" ]; then
    echo "ERROR: Tag value is required"
    echo "Usage: sudo bash $0 <TAG_VALUE>"
    exit 1
fi

if [ ${#TAG_VALUE} -gt 200 ]; then
    echo "ERROR: Tag value exceeds maximum length of 200 characters"
    exit 1
fi

# --- Configuration ---

MANAGED_DIR="/etc/opt/microsoft/mdatp/managed"
MANAGED_FILE="${MANAGED_DIR}/mdatp_managed.json"

echo "Starting MDE device tag configuration: ${TAG_VALUE}"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

# --- Detect Python ---

PYTHON_CMD=""
if command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
fi

if [ -z "$PYTHON_CMD" ]; then
    echo "ERROR: Python is required but not found (tried python3, python)"
    exit 1
fi

echo "Using Python: $($PYTHON_CMD --version 2>&1)"

# --- Check MDE Agent ---

if command -v mdatp &> /dev/null; then
    echo "MDE agent detected: $(mdatp version 2>/dev/null || echo 'version check failed')"
    MDATP_HEALTH=$(mdatp health --field healthy 2>/dev/null || echo "unknown")
    echo "MDE agent health: ${MDATP_HEALTH}"
else
    echo "WARNING: mdatp command not found — MDE agent may not be installed yet"
    echo "Configuration will be pre-staged for when MDE is installed"
fi

# --- Create Directory ---

if [ ! -d "$MANAGED_DIR" ]; then
    echo "Creating directory: ${MANAGED_DIR}"
    mkdir -p "$MANAGED_DIR"
fi

# --- Create/Update Configuration ---
# Uses Python with sys.argv for safe argument passing (no shell interpolation)

echo "Configuring device tag via managed configuration file..."

# Temporarily disable exit-on-error for Python block so we can capture the exit code
set +e
$PYTHON_CMD -c '
import json, os, sys

managed_file = sys.argv[1]
tag_value = sys.argv[2]

config = {}

# Read existing configuration if present (preserve antivirus, cloud settings, etc.)
if os.path.exists(managed_file):
    try:
        with open(managed_file, "r") as f:
            content = f.read().strip()
            if content:
                config = json.loads(content)
    except (ValueError, IOError) as e:
        print("WARNING: Could not parse existing config, creating new: {}".format(e))
        config = {}

# Ensure edr section exists (preserves groupIds and other edr settings)
if "edr" not in config:
    config["edr"] = {}

# Set the GROUP tag
config["edr"]["tags"] = [{"key": "GROUP", "value": tag_value}]

# Write atomically: write to temp file, then rename to prevent corruption
temp_file = managed_file + ".tmp"
try:
    with open(temp_file, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.rename(temp_file, managed_file)
    print("Configuration written to: {}".format(managed_file))
except IOError as e:
    print("ERROR: Failed to write configuration: {}".format(e))
    if os.path.exists(temp_file):
        os.remove(temp_file)
    sys.exit(1)
' "$MANAGED_FILE" "$TAG_VALUE"

WRITE_STATUS=$?
# Re-enable exit-on-error
set -e
if [ $WRITE_STATUS -ne 0 ]; then
    echo "ERROR: Failed to update configuration file"
    exit 1
fi

# --- Set Permissions ---
# File must be readable by the mdatp service (runs as mdatp user)

chmod 644 "$MANAGED_FILE"
echo "File permissions set: 644"

# --- Verify Configuration ---

echo "Verifying configuration..."

CURRENT_TAG=$($PYTHON_CMD -c '
import json, sys

managed_file = sys.argv[1]
try:
    with open(managed_file, "r") as f:
        config = json.load(f)
    tags = config.get("edr", {}).get("tags", [])
    for tag in tags:
        if tag.get("key") == "GROUP":
            print(tag.get("value", ""))
            break
except Exception as e:
    sys.exit(1)
' "$MANAGED_FILE" 2>/dev/null)

if [ "$CURRENT_TAG" = "$TAG_VALUE" ]; then
    echo "✓ MDE device tag configured successfully: ${TAG_VALUE}"
    echo "Configuration file: ${MANAGED_FILE}"
    echo "The tag will synchronize with MDE on the next agent check-in."
    echo "You can view the tag in the Microsoft Defender portal under Device > Device tags"
    exit 0
else
    echo "ERROR: Tag verification failed (expected: '${TAG_VALUE}', got: '${CURRENT_TAG}')"
    exit 1
fi

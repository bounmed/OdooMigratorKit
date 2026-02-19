#!/bin/bash
# Author: Mohamed Bouzahir
# run-migration.sh
set -e

# Function to execute SQL files
show_execution_time() {
    local start_time=$1
    total_seconds=$(($(date +%s) - start_time))
    minutes=$((total_seconds / 60))
    seconds=$((total_seconds % 60))
    echo "Migration process completed in ${minutes} minutes and ${seconds} seconds."
}
echo "========================================"
echo "OpenUpgrade Migration Container"
echo "========================================"

# Substitute environment variables in the config file
if [ -f "/migration/openupgrade.conf.template" ]; then
    echo "Processing configuration template..."
    envsubst < /migration/openupgrade.conf.template > /opt/openupgrade/openupgrade.conf
fi

# Change to OpenUpgrade directory
cd /opt/openupgrade

if [ "$1" = "migrate" ]; then
    shift
    start_time=$(date +%s)
    echo "Starting migration process..."
    echo "Working directory: $(pwd)"
    echo "Python path: $PYTHONPATH"
    echo "Addons path check:"
    #ls -la odoo/addons/ 2>/dev/null | head -5

    # Execute pre-migration.sh files
    if [ "$SKIP_PRE_MIGRATION" != "true" ] && [ "$SKIP_PRE_MIGRATION" != "1" ]; then
        # Execute pre-migration.sh files
        find /migration -name "pre-migration.sh" -type f | while read -r file; do
            chmod +x "$file"  # Make sure the script is executable
            "$file"           # Execute the script
        done
    else
        echo "Skipping pre-migration scripts (SKIP_PRE_MIGRATION=$SKIP_PRE_MIGRATION)"
    fi
    # Execute post-migration.sh files
    find /migration -name "post-migration.sh" -type f | while read -r file; do
        chmod +x "$file"  # Make sure the script is executable
        "$file"           # Execute the script
    done
    show_execution_time $start_time
elif [ "$1" = "shell" ] || [ "$1" = "bash" ]; then
    echo "Starting interactive shell..."
    exec /bin/bash

elif [ "$1" = "test" ]; then
    echo "Testing OpenUpgrade installation..."
    python3 -c "import sys; print('Python:', sys.version)"
    python3 /opt/odoo/odoo-bin --help 2>&1 | head -10
    exit 0

else
    # Default: show help
    echo "Available commands:"
    echo "  migrate          - Run OpenUpgrade migration"
    echo "  shell / bash     - Open interactive shell"
    echo "  test             - Test installation"
    echo "  --help           - Show OpenUpgrade help"
    echo ""
    echo "Examples:"
    echo "  docker run --rm openupgrade migrate"
    echo "  docker run -it --rm openupgrade shell"
    echo ""
    exit 0
fi
#!/bin/bash
# Author: Mohamed Bouzahir
# Post-migration script to reset admin password
# Function to execute SQL files
execute_sql_file() {
    local sql_file=$1
    if [ -f "$sql_file" ]; then
        echo "Executing $sql_file... db : ${DB_PORT} ${DB_USER} ${DB_PASSWORD}"
        # Add your database connection command here
        PGPASSWORD="${DB_PASSWORD}" psql -h "db" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -f "$sql_file"
    else
        echo "Warning: $sql_file not found"
    fi
}

# Execute post.sql files
find /migration -name "post.sql" -type f | while read -r file; do
    execute_sql_file "$file"
done

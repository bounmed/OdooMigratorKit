UPDATE "ir_ui_view"
SET "active" = '0'
WHERE CAST("arch_db" AS text) LIKE '%attrs%'
    OR CAST("arch_db" AS text) LIKE '%states%';
-- Disable problematic base module views known to cause issues
UPDATE "ir_ui_view"
SET "active" = '0'
WHERE "model" IN ('ir.cron', 'ir.actions.server')
    AND CAST("arch_db" AS text) LIKE '%button%';
-- Disable views with invalid button references
UPDATE "ir_ui_view"
SET "active" = '0'
WHERE CAST("arch_db" AS text) LIKE '%<button%name="create_action"%'
    OR CAST("arch_db" AS text) LIKE '%<button%name="unlink_action"%';
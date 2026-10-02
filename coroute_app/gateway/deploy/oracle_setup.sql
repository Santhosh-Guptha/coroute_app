-- Run ONCE as ADMIN in Database Actions > SQL on the Autonomous Database.
-- Creates a dedicated, least-privilege schema for the gateway and enables ORDS/SODA on it.
-- The mobile app never talks to the database; only the gateway (with these credentials) does.

CREATE USER coroute IDENTIFIED BY "<strong-password>"
  DEFAULT TABLESPACE data QUOTA UNLIMITED ON data;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE, CREATE JOB TO coroute;
GRANT SODA_APP TO coroute;          -- SODA collections (create / query / index)
GRANT CONNECT, RESOURCE TO coroute;

-- Expose the schema through ORDS under the URL path "coroute"
BEGIN
  ORDS_ADMIN.ENABLE_SCHEMA(
    p_enabled             => TRUE,
    p_schema              => 'COROUTE',
    p_url_mapping_type    => 'BASE_PATH',
    p_url_mapping_pattern => 'coroute',
    p_auto_rest_auth      => TRUE);
  COMMIT;
END;
/

-- The SODA endpoint becomes:
--   https://<adb-host>.adb.<region>.oraclecloudapps.com/ords/coroute/soda/latest
-- Authenticate with COROUTE / <strong-password> (HTTP Basic, over TLS only).
-- Afterwards, revoke any leftover REST access on ADMIN that the old app used:
--   BEGIN ORDS_ADMIN.ENABLE_SCHEMA(p_enabled => FALSE, p_schema => 'ADMIN'); COMMIT; END;
-- and ROTATE the ADMIN password, because the old APK contained it.

-- Run as a database administrator on the target database before the first migration.
-- Provision the two login passwords separately.
\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'open_erp_owner') THEN
        CREATE ROLE open_erp_owner LOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'open_erp_runtime') THEN
        CREATE ROLE open_erp_runtime LOGIN;
    END IF;
    IF pg_has_role('open_erp_runtime', 'open_erp_owner', 'MEMBER') THEN
        RAISE EXCEPTION 'open_erp_runtime must not be a member of open_erp_owner';
    END IF;
END;
$$;

ALTER ROLE open_erp_owner NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE open_erp_runtime NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

REVOKE CREATE ON SCHEMA public FROM PUBLIC, open_erp_runtime;
GRANT USAGE, CREATE ON SCHEMA public TO open_erp_owner;
GRANT USAGE ON SCHEMA public TO open_erp_runtime;

CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION open_erp_owner;
ALTER SCHEMA audit OWNER TO open_erp_owner;
REVOKE ALL ON SCHEMA audit FROM PUBLIC, open_erp_runtime;
GRANT USAGE ON SCHEMA audit TO open_erp_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE open_erp_owner IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO open_erp_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE open_erp_owner IN SCHEMA audit
    GRANT SELECT ON TABLES TO open_erp_runtime;

COMMIT;

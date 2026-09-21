#!/usr/bin/env bash
# Applies the Onlook migrations to a plain PostgreSQL database, standing in for
# Supabase. Usage: setup-db.sh <repo dir> <database url>
set -euo pipefail
REPO="$1"; URL="$2"
psql -v ON_ERROR_STOP=1 -q "$URL" <<'SQL'
-- Stand-ins for what Supabase provides and the migrations refer to.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text NOT NULL,
  email_confirmed_at timestamp,
  raw_user_meta_data jsonb
);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END $$;
SQL
for f in "$REPO"/apps/backend/supabase/migrations/*.sql; do
  case "$(basename "$f")" in
    0007_*|0008_*|0012_*) echo "skip  $(basename "$f") (Supabase realtime or storage)"; continue;;
  esac
  echo "apply $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -q "$URL" -f "$f"
done

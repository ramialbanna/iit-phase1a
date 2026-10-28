-- 006_base44_rpc_role.sql — D-2 option (c): the narrow PostgREST RPC path for Base44 (owner decision, 28 Oct 2026).
-- Creates the dedicated PostgREST role `iit_base44` and grants it exactly: USAGE on schema iit + EXECUTE on the 27 staff-facing
-- functions of 001–005. Nothing else: no table privileges (and RLS has no policies), no helper functions, no Worker functions,
-- no sequences. PostgREST assumes this role from the JWT `role` claim of the server-side credential Base44 holds; for that,
-- `authenticator` (Supabase's PostgREST login role) must be a member of iit_base44 — granted here when that role exists.
-- NOT a credential, NOT schema exposure (those are Supabase configuration steps — docs/d2-deployment-package.md), NOT applied.

-- As in 001: the CREATEROLE executor gets ADMIN on iit_base44 and nothing more (no SET, no INHERIT); that ADMIN is what lets it
-- grant iit_base44 to authenticator below, which iit_owner could not.
SET createrole_self_grant = '';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iit_base44') THEN CREATE ROLE iit_base44 NOLOGIN NOINHERIT; END IF;
END $$;
RESET createrole_self_grant;
-- PostgREST switches to the JWT role with SET ROLE, which requires membership from its login role (`authenticator` on Supabase).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN EXECUTE 'GRANT iit_base44 TO authenticator'; END IF;
END $$;

-- Schema, function and default-privilege grants on iit objects are the owner's: the executor holds no inherited owner
-- privileges, so on Supabase they fail with 42501 unless issued as iit_owner.
SET ROLE iit_owner;
GRANT USAGE ON SCHEMA iit TO iit_base44;
-- the approved RPC manifest (docs/migrations/006.md §1): every staff-facing entry point of 001–005, nothing else
GRANT EXECUTE ON FUNCTION
  iit.set_staff_identity(text,text,text,text), iit.set_staff_role(uuid,text,boolean,text), iit.deactivate_staff(text,text),
  iit.record_decision(uuid,text,text,text), iit.request_reaudit(uuid,text,text),
  iit.validate_report(uuid,text,text,jsonb,text,text), iit.waive_report(uuid,text,text,text), iit.revoke_waiver(uuid,text,text),
  iit.begin_report_upload(uuid,text,text,uuid,uuid,text,timestamptz,uuid,text), iit.finish_report_upload(uuid,bigint,text,text), iit.authorize_report_access(uuid,text),
  iit.set_source_channel(uuid,text,text), iit.release_deal(uuid,text), iit.correct_field(uuid,text,jsonb,text,text), iit.amend_field(uuid,text,jsonb,text,text),
  iit.rebind_hold(uuid,text,text), iit.resolve_flag(uuid,text,text,text), iit.resolve_work_item(uuid,text,text), iit.cancel_deal(uuid,text,text),
  iit.set_seller_party(uuid,text,int,jsonb,text), iit.correct_party(uuid,text,int,jsonb,text,text), iit.amend_party(uuid,uuid,jsonb,text,text),
  iit.create_manual_deal(text,text,text,text), iit.set_deal_fact(uuid,text,jsonb,text), iit.resolve_restart(uuid,text,text,text),
  iit.resolve_unknown_outcome(uuid,text,jsonb,text,text), iit.set_consignment(uuid,uuid,numeric,text,text)
TO iit_base44;
-- explicit, for the record: no table, sequence or other function privileges (none were ever granted; this documents the intent)
REVOKE ALL ON ALL TABLES IN SCHEMA iit FROM iit_base44;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA iit FROM iit_base44;
-- default privileges for objects iit_owner creates later: nothing to iit_base44 (grants are always explicit, per function)
ALTER DEFAULT PRIVILEGES FOR ROLE iit_owner IN SCHEMA iit REVOKE ALL ON FUNCTIONS FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------------------------------
-- Genuine per-credential revocation (Codex D-2 package P1). A JWT cannot be withdrawn before `exp`, and revoking the role's
-- membership then re-granting it would re-enable a compromised token. So every iit_base44 token must carry a `jti`, and
-- require_role() refuses any jti listed here — independent of the role, immediately, and permanently. The owner revokes by
-- inserting the jti (SQL editor, as postgres); no RPC can revoke or un-revoke. Rows are never deleted (history-covered).
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE iit.revoked_credentials (
  jti text PRIMARY KEY,
  revoked_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL
);
SELECT iit.attach_history('iit.revoked_credentials', 'jti');        -- no DELETE (reject_delete)
CREATE OR REPLACE FUNCTION iit.require_role(p_actor_base44_user_id text, p_required_role text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE v_user uuid; v_origin text; v_claims text; v_role text; v_jti text;
BEGIN
  -- Credential enforcement is keyed to the ORIGINATING role (the SET ROLE in force when the call began — the same signal
  -- record_history.origin_role records), never to what the claims say about themselves (Codex D-2 rev 2 P1):
  --   origin iit_base44  → claims must exist, claims.role must be iit_base44, jti must be present and unrevoked;
  --   origin anything else (owner SQL, Worker, local tests) with claims naming iit_base44 → identity mismatch, refused;
  --   origin anything else without such claims → unchanged claim-less behaviour.
  v_origin := nullif(pg_catalog.current_setting('role', true), 'none');
  v_claims := nullif(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_role := v_claims::jsonb ->> 'role'; v_jti := v_claims::jsonb ->> 'jti';
  IF v_origin = 'iit_base44' THEN
    IF v_claims IS NULL THEN RAISE EXCEPTION 'CREDENTIAL_NO_CLAIMS' USING ERRCODE = '28000'; END IF;
    IF v_role IS DISTINCT FROM 'iit_base44' THEN RAISE EXCEPTION 'CREDENTIAL_ROLE_MISMATCH' USING ERRCODE = '28000'; END IF;
    IF v_jti IS NULL OR v_jti = '' THEN RAISE EXCEPTION 'CREDENTIAL_NO_JTI' USING ERRCODE = '28000'; END IF;
    IF EXISTS (SELECT 1 FROM iit.revoked_credentials r WHERE r.jti = v_jti) THEN RAISE EXCEPTION 'CREDENTIAL_REVOKED' USING ERRCODE = '28000'; END IF;
  ELSIF v_role = 'iit_base44' THEN
    RAISE EXCEPTION 'CREDENTIAL_ROLE_MISMATCH' USING ERRCODE = '28000';
  END IF;
  IF p_actor_base44_user_id IS NULL OR p_actor_base44_user_id = '' THEN RAISE EXCEPTION 'ACTOR_REQUIRED' USING ERRCODE = '28000'; END IF;
  SELECT si.user_id INTO v_user
    FROM iit.staff_identities si JOIN iit.users u ON u.id = si.user_id
   WHERE si.base44_user_id = p_actor_base44_user_id AND si.active AND u.active;
  IF v_user IS NULL THEN RAISE EXCEPTION 'ACTOR_UNKNOWN_OR_INACTIVE' USING ERRCODE = '28000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM iit.user_roles ur WHERE ur.user_id = v_user AND ur.role = p_required_role) THEN
    RAISE EXCEPTION 'ROLE_MISSING: %', p_required_role USING ERRCODE = '42501';
  END IF;
  RETURN v_user;
END $$;
REVOKE ALL ON FUNCTION iit.require_role(text,text) FROM PUBLIC;
RESET ROLE;

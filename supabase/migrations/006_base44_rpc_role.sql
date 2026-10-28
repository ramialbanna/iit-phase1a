-- 006_base44_rpc_role.sql — D-2 option (c): the narrow PostgREST RPC path for Base44 (owner decision, 28 Oct 2026).
-- Creates the dedicated PostgREST role `iit_base44` and grants it exactly: USAGE on schema iit + EXECUTE on the 27 staff-facing
-- functions of 001–005. Nothing else: no table privileges (and RLS has no policies), no helper functions, no Worker functions,
-- no sequences. PostgREST assumes this role from the JWT `role` claim of the server-side credential Base44 holds; for that,
-- `authenticator` (Supabase's PostgREST login role) must be a member of iit_base44 — granted here when that role exists.
-- NOT a credential, NOT schema exposure (those are Supabase configuration steps — docs/d2-deployment-package.md), NOT applied.
BEGIN;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iit_base44') THEN CREATE ROLE iit_base44 NOLOGIN NOINHERIT; END IF;
END $$;
-- PostgREST switches to the JWT role with SET ROLE, which requires membership from its login role (`authenticator` on Supabase).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN EXECUTE 'GRANT iit_base44 TO authenticator'; END IF;
END $$;

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
COMMIT;

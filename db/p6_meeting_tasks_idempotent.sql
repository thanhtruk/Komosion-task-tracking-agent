-- ============================================================================
-- p6_meeting_tasks_idempotent.sql
-- Adds public.upsert_meeting_task RPC so n8n inserts into meeting_tasks
-- never throw duplicate-key errors when a meeting is re-processed.
--
-- Safe to run multiple times (CREATE OR REPLACE; no schema changes).
-- PK meeting_tasks_pkey (meeting_id, wip_task_id) is LEFT UNTOUCHED.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.upsert_meeting_task(
  p_meeting_id  uuid,
  p_wip_task_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.meeting_tasks (meeting_id, wip_task_id)
    VALUES (p_meeting_id, p_wip_task_id)
    ON CONFLICT (meeting_id, wip_task_id) DO NOTHING;
END;
$$;

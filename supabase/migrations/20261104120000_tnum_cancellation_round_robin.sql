CREATE TABLE IF NOT EXISTS public.tnum_cancellation_scheduler_state (
  id boolean PRIMARY KEY DEFAULT true CHECK (id = true),
  last_deadline_at timestamptz,
  last_activation_id uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.tnum_cancellation_scheduler_state (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;

REVOKE ALL ON TABLE public.tnum_cancellation_scheduler_state
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.tnum_get_cancellation_batch(
  p_limit integer DEFAULT 4
)
RETURNS SETOF public.tnum_activations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_last_deadline_at timestamptz;
  v_last_activation_id uuid;
  v_limit integer;
BEGIN
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 4), 1), 20);

  SELECT last_deadline_at, last_activation_id
  INTO v_last_deadline_at, v_last_activation_id
  FROM public.tnum_cancellation_scheduler_state
  WHERE id = true
  FOR UPDATE;

  RETURN QUERY
  WITH eligible AS MATERIALIZED (
    SELECT
      a.id,
      a.deadline_at,
      CASE
        WHEN v_last_deadline_at IS NULL
          OR (a.deadline_at, a.id) >
             (v_last_deadline_at, v_last_activation_id)
        THEN 0
        ELSE 1
      END AS cycle_order
    FROM public.tnum_activations a
    WHERE a.provider_operation_id IS NOT NULL
      AND a.status = 'expiration_pending'
      AND a.cancellation_state IN (
        'not_requested',
        'retry',
        'uncertain'
      )
      AND a.deadline_at <= now()
      AND (
        a.next_retry_at IS NULL
        OR a.next_retry_at <= now()
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.tnum_activation_sms s
        WHERE s.activation_id = a.id
      )
  ),
  picked AS MATERIALIZED (
    SELECT id, deadline_at, cycle_order
    FROM eligible
    ORDER BY cycle_order, deadline_at, id
    LIMIT v_limit
  ),
  last_picked AS (
    SELECT id, deadline_at
    FROM picked
    ORDER BY cycle_order DESC, deadline_at DESC, id DESC
    LIMIT 1
  ),
  cursor_updated AS (
    UPDATE public.tnum_cancellation_scheduler_state s
    SET
      last_deadline_at = p.deadline_at,
      last_activation_id = p.id,
      updated_at = now()
    FROM last_picked p
    WHERE s.id = true
    RETURNING s.id
  )
  SELECT a.*
  FROM public.tnum_activations a
  JOIN picked p ON p.id = a.id
  CROSS JOIN cursor_updated
  ORDER BY p.cycle_order, p.deadline_at, p.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.tnum_get_cancellation_batch(integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tnum_get_cancellation_batch(integer)
TO service_role;
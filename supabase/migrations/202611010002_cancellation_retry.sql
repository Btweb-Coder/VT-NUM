
-- T-NUM cancellation retry support.
-- An SMS can win a race with cancellation while the provider outcome is pending.

CREATE OR REPLACE FUNCTION public.tnum_validate_activation_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF new.status = old.status THEN
        RETURN new;
    END IF;

    IF old.status IN ('completed', 'expired', 'cancelled', 'failed') THEN
        RAISE EXCEPTION 'TERMINAL_ACTIVATION';
    END IF;

    IF NOT (
        (old.status = 'reserved'
            AND new.status IN ('purchase_pending', 'failed'))
        OR
        (old.status = 'purchase_pending'
            AND new.status IN (
                'active',
                'provider_outcome_uncertain',
                'failed',
                'expiration_pending'
            ))
        OR
        (old.status = 'provider_outcome_uncertain'
            AND new.status IN (
                'active',
                'failed',
                'expiration_pending'
            ))
        OR
        (old.status = 'active'
            AND new.status IN (
                'sms_received',
                'completion_pending',
                'completed',
                'expiration_pending'
            ))
        OR
        (old.status = 'sms_received'
            AND new.status IN (
                'completion_pending',
                'completed',
                'expiration_pending'
            ))
        OR
        (old.status = 'completion_pending'
            AND new.status IN (
                'sms_received',
                'completed',
                'expiration_pending'
            ))
        OR
        (old.status = 'expiration_pending'
            AND new.status IN (
                'sms_received',
                'completion_pending',
                'completed',
                'expired',
                'cancelled'
            ))
    ) THEN
        RAISE EXCEPTION 'INVALID_ACTIVATION_TRANSITION';
    END IF;

    RETURN new;
END;
$$;


-- Atomically claim one cancellation attempt.
-- The provider worker must still confirm the outcome before funds are released.
CREATE OR REPLACE FUNCTION public.tnum_claim_activation_cancellation(
    p_activation uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    claimed uuid;
    operation_claimed uuid;
BEGIN
    -- Lock the activation first so competing workers cannot claim it twice.
    UPDATE public.tnum_activations
    SET
        cancellation_state = 'pending',
        cancellation_attempts = cancellation_attempts + 1,
        next_retry_at = NULL
    WHERE id = p_activation
      AND provider_operation_id IS NOT NULL
      AND deadline_at <= now()
      AND status = 'expiration_pending'
      AND cancellation_state IN ('not_requested', 'retry', 'uncertain')
      AND (next_retry_at IS NULL OR next_retry_at <= now())
    RETURNING id INTO claimed;

    IF claimed IS NULL THEN
        RETURN false;
    END IF;

    UPDATE public.tnum_provider_operations
    SET
        operation = 'close',
        state = 'sending',
        attempts = attempts + 1,
        next_attempt_at = NULL,
        updated_at = now()
    WHERE activation_id = p_activation
      AND operation IN ('purchase', 'poll', 'close')
      AND state <> 'sending'
    RETURNING activation_id INTO operation_claimed;

    IF operation_claimed IS NULL THEN
        -- Roll back the claim state if the provider operation cannot be claimed.
        UPDATE public.tnum_activations
        SET
            cancellation_state = 'retry',
            next_retry_at = now() + interval '10 seconds'
        WHERE id = p_activation
          AND cancellation_state = 'pending';

        RETURN false;
    END IF;

    RETURN true;
END;
$$;


-- Schedule another attempt after a failed or uncertain provider response.
CREATE OR REPLACE FUNCTION public.tnum_retry_activation_cancellation(
    p_activation uuid,
    p_error text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_attempts integer;
    delay_seconds integer;
    claimed uuid;
BEGIN
    SELECT cancellation_attempts
    INTO current_attempts
    FROM public.tnum_activations
    WHERE id = p_activation
      AND status = 'expiration_pending'
      AND cancellation_state = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    -- Bounded exponential backoff: 10, 20, 40, then 60 seconds.
    delay_seconds := LEAST(
        60,
        GREATEST(
            10,
            10 * power(
                2::numeric,
                LEAST(GREATEST(current_attempts - 1, 0), 3)
            )::integer
        )
    );

    UPDATE public.tnum_activations
    SET
        cancellation_state = 'retry',
        next_retry_at = now() + make_interval(secs => delay_seconds),
        failure_code = left(p_error, 100),
        last_provider_check_at = now()
    WHERE id = p_activation
      AND status = 'expiration_pending'
      AND cancellation_state = 'pending'
    RETURNING id INTO claimed;

    IF claimed IS NULL THEN
        RETURN false;
    END IF;

    UPDATE public.tnum_provider_operations
    SET
        operation = 'close',
        state = 'retry',
        next_attempt_at = now() + make_interval(secs => delay_seconds),
        last_error_code = left(p_error, 100),
        updated_at = now()
    WHERE activation_id = p_activation;

    RETURN true;
END;
$$;


REVOKE ALL ON FUNCTION public.tnum_claim_activation_cancellation(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.tnum_retry_activation_cancellation(uuid, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tnum_claim_activation_cancellation(uuid)
TO service_role;

GRANT EXECUTE ON FUNCTION public.tnum_retry_activation_cancellation(uuid, text)
TO service_role;

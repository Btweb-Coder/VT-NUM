CREATE OR REPLACE FUNCTION public.tnum_finalize_activation_cancellation(
    p_activation uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    a public.tnum_activations;
BEGIN
    SELECT *
    INTO a
    FROM public.tnum_activations
    WHERE id = p_activation
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    -- Never refund an activation that has already received an SMS.
    IF EXISTS (
        SELECT 1
        FROM public.tnum_activation_sms
        WHERE activation_id = p_activation
    ) THEN
        UPDATE public.tnum_activations
        SET
            status = 'sms_received',
            cancellation_state = 'uncertain',
            next_retry_at = NULL
        WHERE id = p_activation
          AND status = 'expiration_pending';

        RETURN false;
    END IF;

    IF a.status <> 'expiration_pending'
       OR a.cancellation_state <> 'pending' THEN
        RETURN false;
    END IF;

    -- Release the wallet reservation exactly once.
    IF NOT EXISTS (
        SELECT 1
        FROM public.tnum_wallet_ledger
        WHERE idempotency_key = 'release:' || a.id
    ) THEN
        UPDATE public.tnum_wallets
        SET
            available_cents = available_cents + a.customer_price_cents,
            reserved_cents = reserved_cents - a.customer_price_cents,
            updated_at = now()
        WHERE user_id = a.user_id
          AND reserved_cents >= a.customer_price_cents;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'WALLET_INVARIANT';
        END IF;

        INSERT INTO public.tnum_wallet_ledger (
            user_id,
            activation_id,
            kind,
            amount_cents,
            idempotency_key
        )
        VALUES (
            a.user_id,
            a.id,
            'release',
            a.customer_price_cents,
            'release:' || a.id
        );
    END IF;

    UPDATE public.tnum_activations
    SET
        status = 'expired',
        cancellation_state = 'confirmed',
        provider_terminal_at = now(),
        next_retry_at = NULL,
        failure_code = NULL
    WHERE id = p_activation;

    UPDATE public.tnum_provider_operations
    SET
        operation = 'close',
        state = 'confirmed',
        next_attempt_at = NULL,
        last_error_code = NULL,
        updated_at = now()
    WHERE activation_id = p_activation;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.tnum_finalize_activation_cancellation(uuid)
FROM public, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tnum_finalize_activation_cancellation(uuid)
TO service_role;

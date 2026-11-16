CREATE OR REPLACE FUNCTION public.tnum_save_activation_sms(
    p_activation uuid,
    p_provider_message_key text,
    p_message_text text,
    p_code text,
    p_provider_status text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    a public.tnum_activations;
    has_message boolean;
    is_answered boolean;
BEGIN
    -- Lock the activation so SMS persistence and cancellation
    -- finalization cannot race against each other.
    SELECT *
    INTO a
    FROM public.tnum_activations
    WHERE id = p_activation
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    -- Never modify a terminal activation.
    IF a.status IN ('completed', 'expired', 'cancelled', 'failed') THEN
        RETURN false;
    END IF;

    has_message :=
        p_provider_message_key IS NOT NULL
        AND length(trim(p_provider_message_key)) > 0
        AND p_message_text IS NOT NULL
        AND length(trim(p_message_text)) > 0;

    is_answered := p_provider_status = 'TZ_NUM_ANSWER';

    -- Do not mark an activation as answered without either
    -- an actual message or an explicit answered provider status.
    IF NOT has_message AND NOT is_answered THEN
        RETURN false;
    END IF;

    -- Persist actual messages idempotently.
    IF has_message THEN
        INSERT INTO public.tnum_activation_sms (
            activation_id,
            provider_message_key,
            message_text,
            code
        )
        VALUES (
            p_activation,
            p_provider_message_key,
            p_message_text,
            p_code
        )
        ON CONFLICT (activation_id, provider_message_key)
        DO NOTHING;
    END IF;

    -- Never downgrade a completion already claimed by the customer.
    IF a.status <> 'completion_pending' THEN
        UPDATE public.tnum_activations
        SET
            status = 'sms_received',
            provider_status = p_provider_status,
            cancellation_state = 'uncertain',
            last_provider_check_at = now()
        WHERE id = p_activation;
    ELSE
        UPDATE public.tnum_activations
        SET
            provider_status = p_provider_status,
            last_provider_check_at = now()
        WHERE id = p_activation;
    END IF;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.tnum_save_activation_sms(
    uuid, text, text, text, text
) FROM public, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tnum_save_activation_sms(
    uuid, text, text, text, text
) TO service_role;

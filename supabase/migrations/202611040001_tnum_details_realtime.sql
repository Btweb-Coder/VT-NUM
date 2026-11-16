begin;

-- Retain the provider's last reported remaining time so the details screen can
-- refresh its local view without polling OnlineSim itself.
alter table public.tnum_activations
  add column if not exists provider_time_remaining_seconds integer
    check (provider_time_remaining_seconds is null or provider_time_remaining_seconds >= 0);

-- Both tables already have authenticated owner-only SELECT policies. Publish
-- their changes so the Flutter details view can receive status and SMS updates.
do $$
begin
  if exists (
    select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime'
  ) then
    if not exists (
      select 1 from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'tnum_activations'
    ) then
      alter publication supabase_realtime add table public.tnum_activations;
    end if;

    if not exists (
      select 1 from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'tnum_activation_sms'
    ) then
      alter publication supabase_realtime add table public.tnum_activation_sms;
    end if;
  end if;
end;
$$;

commit;

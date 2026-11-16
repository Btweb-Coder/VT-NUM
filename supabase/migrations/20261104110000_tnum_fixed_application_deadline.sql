begin;

update public.tnum_runtime_config
set activation_timeout_seconds = 360,
    updated_at = now()
where id = true;

alter table public.tnum_runtime_config
  drop constraint if exists tnum_pricing_rules_activation_timeout_seconds_check;

alter table public.tnum_runtime_config
  add constraint tnum_runtime_config_activation_timeout_seconds_check
  check (activation_timeout_seconds = 360);

commit;

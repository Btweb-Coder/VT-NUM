-- Enregistrement de l'acceptation des CGU.

begin;

alter table public.profiles
  add column if not exists terms_accepted boolean not null default false,
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_version text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_terms_acceptance_consistency'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_terms_acceptance_consistency
      check (
        (
          terms_accepted = false
          and terms_accepted_at is null
          and terms_version is null
        )
        or
        (
          terms_accepted = true
          and terms_accepted_at is not null
          and terms_version is not null
          and length(trim(terms_version)) > 0
        )
      );
  end if;
end
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  accepted_terms boolean;
  accepted_version text;
begin
  if tg_op = 'INSERT' then
    accepted_terms :=
      coalesce(new.raw_user_meta_data ->> 'terms_accepted', 'false') = 'true';

    accepted_version :=
      nullif(trim(new.raw_user_meta_data ->> 'terms_version'), '');

    if not accepted_terms or accepted_version is null then
      raise exception 'TERMS_ACCEPTANCE_REQUIRED';
    end if;

    insert into public.profiles (
      user_id,
      email,
      email_verified_at,
      terms_accepted,
      terms_accepted_at,
      terms_version
    )
    values (
      new.id,
      coalesce(new.email, ''),
      new.email_confirmed_at,
      true,
      now(),
      accepted_version
    )
    on conflict (user_id) do update
      set email = excluded.email,
          email_verified_at = excluded.email_verified_at,
          updated_at = now();
  else
    update public.profiles
    set email = coalesce(new.email, ''),
        email_verified_at = new.email_confirmed_at
    where user_id = new.id;
  end if;

  return new;
end;
$$;

commit;

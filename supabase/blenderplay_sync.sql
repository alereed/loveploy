-- Blender Play (app de Mac): respaldo y sincronización entre las Mac de una persona.
-- Todo lo de Blender Play en este proyecto lleva "blenderplay" en el nombre.
-- Los datos llegan cifrados desde la Mac; el servidor solo guarda texto cifrado,
-- identificado por el hash de una llave de acceso. Sin acceso directo a la tabla.

create table public.blenderplay_sync (
  account    text        not null check (account ~ '^[0-9a-f]{64}$'),
  kind       text        not null check (kind ~ '^[a-z]{2,20}(:[A-Za-z0-9-]{1,64})?$'),
  payload    text        not null check (length(payload) <= 8000000),
  device     text        not null default '' check (length(device) <= 64),
  updated_at timestamptz not null default now(),
  primary key (account, kind)
);

comment on table public.blenderplay_sync is
  'Blender Play: respaldo cifrado (en la Mac) de grupos, proyectos, tiempo y tokens, atajos y preferencias. Solo por blenderplay_sync_put/get/delete.';

alter table public.blenderplay_sync enable row level security;
revoke all on table public.blenderplay_sync from anon, authenticated;

create or replace function public.blenderplay_sync_put(p_key text, p_kind text, p_payload text, p_device text default '')
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account text;
  v_at timestamptz := now();
begin
  if p_key is null or length(p_key) < 32 or length(p_key) > 256 then
    raise exception 'blenderplay: llave inválida';
  end if;
  v_account := encode(extensions.digest(p_key, 'sha256'), 'hex');
  if p_kind is null or p_kind !~ '^[a-z]{2,20}(:[A-Za-z0-9-]{1,64})?$' then
    raise exception 'blenderplay: tipo inválido';
  end if;
  if p_payload is null or length(p_payload) > 8000000 then
    raise exception 'blenderplay: contenido inválido';
  end if;
  if (select count(*) from public.blenderplay_sync where account = v_account and kind <> p_kind) >= 60 then
    raise exception 'blenderplay: demasiados tipos de datos';
  end if;
  insert into public.blenderplay_sync as s (account, kind, payload, device, updated_at)
  values (v_account, p_kind, p_payload, left(coalesce(p_device, ''), 64), v_at)
  on conflict (account, kind) do update
    set payload = excluded.payload, device = excluded.device, updated_at = excluded.updated_at;
  return v_at;
end;
$$;

create or replace function public.blenderplay_sync_get(p_key text, p_since timestamptz default null)
returns table (kind text, payload text, device text, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_key is null or length(p_key) < 32 or length(p_key) > 256 then
    raise exception 'blenderplay: llave inválida';
  end if;
  return query
    select s.kind, s.payload, s.device, s.updated_at
    from public.blenderplay_sync s
    where s.account = encode(extensions.digest(p_key, 'sha256'), 'hex')
      and (p_since is null or s.updated_at > p_since)
    order by s.kind;
end;
$$;

create or replace function public.blenderplay_sync_delete(p_key text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_key is null or length(p_key) < 32 or length(p_key) > 256 then
    raise exception 'blenderplay: llave inválida';
  end if;
  delete from public.blenderplay_sync where account = encode(extensions.digest(p_key, 'sha256'), 'hex');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.blenderplay_sync_put(text, text, text, text) from public, anon, authenticated;
revoke all on function public.blenderplay_sync_get(text, timestamptz) from public, anon, authenticated;
revoke all on function public.blenderplay_sync_delete(text) from public, anon, authenticated;
grant execute on function public.blenderplay_sync_put(text, text, text, text) to anon, authenticated;
grant execute on function public.blenderplay_sync_get(text, timestamptz) to anon, authenticated;
grant execute on function public.blenderplay_sync_delete(text) to anon, authenticated;

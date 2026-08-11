-- Lexus Representações — camada de produção
-- Execute uma vez no SQL Editor do Supabase.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null default '',
  role text not null default 'vendedor' check (role in ('admin','vendedor','financeiro','leitura')),
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.profiles (id,nome,role)
select id,coalesce(raw_user_meta_data->>'name',split_part(email,'@',1)),'admin'
from auth.users
on conflict (id) do nothing;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,nome,role)
  values(new.id,coalesce(new.raw_user_meta_data->>'name',split_part(new.email,'@',1)),'vendedor')
  on conflict(id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.current_role() returns text
language sql stable security definer set search_path=public
as $$ select coalesce((select role from public.profiles where id=auth.uid() and ativo),'leitura') $$;

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  tabela text not null,
  registro_id text,
  acao text not null check (acao in ('INSERT','UPDATE','DELETE')),
  anterior jsonb,
  novo jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.importacoes (
  id uuid primary key default gen_random_uuid(),
  arquivo text not null,
  hash text,
  status text not null default 'processando' check(status in ('processando','concluida','parcial','falhou','desfeita')),
  resumo jsonb not null default '{}'::jsonb,
  erros jsonb not null default '[]'::jsonb,
  user_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create table if not exists public.recebimentos (
  id uuid primary key default gen_random_uuid(),
  pedido_id text not null,
  representada_id text,
  competencia text not null,
  valor_previsto numeric(14,2) not null default 0,
  valor_recebido numeric(14,2) not null default 0,
  vencimento date,
  recebido_em date,
  status text not null default 'pendente' check(status in ('pendente','parcial','recebido','atrasado','cancelado')),
  observacao text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(pedido_id,competencia)
);

create table if not exists public.fechamentos (
  competencia text primary key,
  fechado_em timestamptz not null default now(),
  fechado_por uuid references auth.users(id) on delete set null default auth.uid(),
  resumo jsonb not null default '{}'::jsonb
);

create table if not exists public.anexos (
  id uuid primary key default gen_random_uuid(),
  entidade text not null check(entidade in ('pedido','processo','cliente','representada')),
  entidade_id text not null,
  nome text not null,
  caminho text not null,
  tipo text,
  tamanho bigint,
  user_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_registro on public.audit_log(tabela,registro_id,created_at desc);
create index if not exists idx_receb_competencia on public.recebimentos(competencia,status);
create index if not exists idx_importacoes_created on public.importacoes(created_at desc);
create index if not exists idx_anexos_entidade on public.anexos(entidade,entidade_id);

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.audit_log(user_id,tabela,registro_id,acao,anterior,novo)
  values(auth.uid(),tg_table_name,coalesce(new.id::text,old.id::text),tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new,old);
end $$;

do $$ declare t text;
begin
  foreach t in array array['clientes','grupos','forn','produtos','pedidos','recebimentos'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists trg_audit_%I on public.%I',t,t);
      execute format('create trigger trg_audit_%I after insert or update or delete on public.%I for each row execute function public.audit_row()',t,t);
    end if;
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.audit_log enable row level security;
alter table public.importacoes enable row level security;
alter table public.recebimentos enable row level security;
alter table public.fechamentos enable row level security;
alter table public.anexos enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (id=auth.uid() or public.current_role()='admin');
drop policy if exists profiles_admin on public.profiles;
create policy profiles_admin on public.profiles for all to authenticated using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated using(public.current_role() in ('admin','financeiro'));

do $$ declare t text;
begin
  foreach t in array array['importacoes','recebimentos','fechamentos','anexos'] loop
    execute format('drop policy if exists %I_read on public.%I',t,t);
    execute format('create policy %I_read on public.%I for select to authenticated using(true)',t,t);
    execute format('drop policy if exists %I_write on public.%I',t,t);
    execute format('create policy %I_write on public.%I for all to authenticated using(public.current_role() in (''admin'',''financeiro'',''vendedor'')) with check(public.current_role() in (''admin'',''financeiro'',''vendedor''))',t,t);
  end loop;
end $$;

-- Protege as tabelas operacionais existentes. Leitura exige login; escrita respeita o perfil.
do $$ declare t text;
begin
  foreach t in array array['clientes','grupos','forn','produtos','pedidos','hist'] loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I enable row level security',t);
      execute format('drop policy if exists %I_read_auth on public.%I',t,t);
      execute format('create policy %I_read_auth on public.%I for select to authenticated using(true)',t,t);
      execute format('drop policy if exists %I_write_roles on public.%I',t,t);
      execute format('create policy %I_write_roles on public.%I for all to authenticated using(public.current_role() in (''admin'',''financeiro'',''vendedor'')) with check(public.current_role() in (''admin'',''financeiro'',''vendedor''))',t,t);
    end if;
  end loop;
end $$;

-- Bucket privado para documentos. A aplicação guarda apenas metadados em public.anexos.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('lexus-documentos','lexus-documentos',false,10485760,array['application/pdf','image/png','image/jpeg','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict(id) do nothing;

drop policy if exists lexus_docs_read on storage.objects;
create policy lexus_docs_read on storage.objects for select to authenticated using(bucket_id='lexus-documentos');
drop policy if exists lexus_docs_write on storage.objects;
create policy lexus_docs_write on storage.objects for all to authenticated
using(bucket_id='lexus-documentos' and public.current_role() in ('admin','financeiro','vendedor'))
with check(bucket_id='lexus-documentos' and public.current_role() in ('admin','financeiro','vendedor'));

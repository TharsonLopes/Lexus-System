-- Lexus Representações — CRM centralizado no Supabase
-- Execute uma vez no SQL Editor do projeto Supabase.

create extension if not exists pgcrypto;

create table if not exists public.crm_interacoes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cliente_id bigint not null,
  contato_em date not null default current_date,
  canal text not null default 'WhatsApp',
  responsavel text not null default '',
  assunto text not null default '',
  etapa text not null default 'Primeiro contato',
  nota text not null default '',
  retorno date,
  prioridade text not null default 'Normal',
  status text not null default 'aberto' check (status in ('aberto','concluido','cancelado')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists crm_interacoes_cliente_idx on public.crm_interacoes(cliente_id);
create index if not exists crm_interacoes_retorno_idx on public.crm_interacoes(retorno) where status = 'aberto';
create index if not exists crm_interacoes_user_idx on public.crm_interacoes(user_id);

alter table public.crm_interacoes enable row level security;

drop policy if exists "crm_select_own" on public.crm_interacoes;
create policy "crm_select_own" on public.crm_interacoes for select to authenticated
using (user_id = auth.uid());

drop policy if exists "crm_insert_own" on public.crm_interacoes;
create policy "crm_insert_own" on public.crm_interacoes for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists "crm_update_own" on public.crm_interacoes;
create policy "crm_update_own" on public.crm_interacoes for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "crm_delete_own" on public.crm_interacoes;
create policy "crm_delete_own" on public.crm_interacoes for delete to authenticated
using (user_id = auth.uid());

create or replace function public.set_crm_updated_at()
returns trigger language plpgsql security invoker set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists crm_interacoes_updated_at on public.crm_interacoes;
create trigger crm_interacoes_updated_at before update on public.crm_interacoes
for each row execute function public.set_crm_updated_at();

grant select, insert, update, delete on public.crm_interacoes to authenticated;

comment on table public.crm_interacoes is
'Fonte oficial do CRM Lexus. Dados operacionais não devem depender de localStorage.';

-- Lexus Representações — evolução operacional completa
-- Supabase é a fonte oficial. Script idempotente.

create extension if not exists unaccent;

alter table public.pedidos add column if not exists numero_representada text;
alter table public.pedidos add column if not exists faturado_em date;
alter table public.pedidos add column if not exists competencia_comissao date;
alter table public.pedidos add column if not exists status_comissao text not null default 'prevista';
alter table public.pedidos add column if not exists valor_recebido numeric(14,2) not null default 0;
alter table public.pedidos add column if not exists recebido_em date;
alter table public.pedidos add column if not exists deleted_at timestamptz;
alter table public.pedidos add column if not exists updated_at timestamptz not null default now();
alter table public.pedidos add column if not exists updated_by uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='pedidos_status_comissao_check') then
    alter table public.pedidos add constraint pedidos_status_comissao_check
    check (status_comissao in ('prevista','confirmada','vencida','recebida','conciliada'));
  end if;
end $$;

create index if not exists pedidos_competencia_comissao_idx on public.pedidos(competencia_comissao);
create index if not exists pedidos_faturado_em_idx on public.pedidos(faturado_em);
create index if not exists pedidos_status_comissao_idx on public.pedidos(status_comissao);
create index if not exists pedidos_deleted_at_idx on public.pedidos(deleted_at);

-- Converte os campos históricos que estavam em observações.
update public.pedidos
set numero_representada = nullif(substring(obs from '(?i)Fornecedor:\s*([^|·—]+)'), '')
where numero_representada is null and obs ~* 'Fornecedor:';

update public.pedidos
set faturado_em = substring(obs from '(?i)Faturamento:\s*(\d{4}-\d{2}-\d{2})')::date
where faturado_em is null and obs ~* 'Faturamento:\s*\d{4}-\d{2}-\d{2}';

update public.pedidos p set competencia_comissao = make_date(
  extract(year from coalesce(p.faturado_em,p.data,current_date))::int,
  case lower(unaccent(p.mes_com))
    when 'janeiro' then 1 when 'fevereiro' then 2 when 'marco' then 3
    when 'abril' then 4 when 'maio' then 5 when 'junho' then 6
    when 'julho' then 7 when 'agosto' then 8 when 'setembro' then 9
    when 'outubro' then 10 when 'novembro' then 11 when 'dezembro' then 12
  end, 1)
where p.competencia_comissao is null and coalesce(p.mes_com,'')<>'';

create table if not exists public.crm_contatos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cliente_id bigint not null,
  nome text not null,
  cargo text not null default '',
  telefone text not null default '',
  whatsapp text not null default '',
  email text not null default '',
  principal boolean not null default false,
  observacao text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.crm_interacoes add column if not exists contato_id uuid references public.crm_contatos(id) on delete set null;
alter table public.crm_interacoes add column if not exists concluido_em timestamptz;
alter table public.crm_interacoes add column if not exists motivo_perda text not null default '';
alter table public.crm_interacoes add column if not exists valor_oportunidade numeric(14,2) not null default 0;
alter table public.crm_interacoes add column if not exists anexos jsonb not null default '[]'::jsonb;

create index if not exists crm_contatos_cliente_idx on public.crm_contatos(cliente_id);
alter table public.crm_contatos enable row level security;
drop policy if exists "crm_contatos_own" on public.crm_contatos;
create policy "crm_contatos_own" on public.crm_contatos for all to authenticated
using (user_id=auth.uid()) with check (user_id=auth.uid());
grant select,insert,update,delete on public.crm_contatos to authenticated;

create table if not exists public.lexus_backups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  origem text not null default 'manual',
  payload jsonb not null
);
alter table public.lexus_backups enable row level security;
drop policy if exists "lexus_backups_own" on public.lexus_backups;
create policy "lexus_backups_own" on public.lexus_backups for all to authenticated
using (user_id=auth.uid()) with check (user_id=auth.uid());
grant select,insert,delete on public.lexus_backups to authenticated;

create or replace function public.lexus_set_updated_at()
returns trigger language plpgsql security invoker set search_path=public as $$
begin new.updated_at=now(); new.updated_by=auth.uid(); return new; end $$;

drop trigger if exists pedidos_updated_at on public.pedidos;
create trigger pedidos_updated_at before update on public.pedidos
for each row execute function public.lexus_set_updated_at();

comment on column public.pedidos.competencia_comissao is 'Primeiro dia do mês/ano em que a comissão deve ser recebida.';
comment on column public.pedidos.faturado_em is 'Data real de faturamento do pedido.';
comment on column public.pedidos.numero_representada is 'Número oficial do pedido ou processo na representada.';

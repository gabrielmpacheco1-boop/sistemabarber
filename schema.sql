-- ============================================================
-- AgendaBarber — Schema Supabase
-- Execute no SQL Editor do Supabase
-- ============================================================

-- Habilitar extensão para UUIDs
create extension if not exists "pgcrypto";

-- ============================================================
-- BARBEARIAS
-- ============================================================
create table barbearias (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,
  nome        text not null,
  telefone_dono      text,
  whatsapp_dono      text not null,
  criado_em   timestamptz default now()
);

-- ============================================================
-- BARBEIROS
-- ============================================================
create table barbeiros (
  id              uuid primary key default gen_random_uuid(),
  barbearia_id    uuid not null references barbearias(id) on delete cascade,
  nome            text not null,
  telefone_whatsapp text,
  foto_url        text,
  ativo           boolean default true,
  criado_em       timestamptz default now()
);

-- ============================================================
-- SERVIÇOS
-- ============================================================
create table servicos (
  id              uuid primary key default gen_random_uuid(),
  barbearia_id    uuid not null references barbearias(id) on delete cascade,
  nome            text not null,
  preco           numeric(10,2) not null,
  duracao_minutos integer not null,
  ativo           boolean default true,
  criado_em       timestamptz default now()
);

-- ============================================================
-- HORÁRIOS POR BARBEIRO (dias da semana: 0=Dom, 6=Sáb)
-- ============================================================
create table horarios (
  id          uuid primary key default gen_random_uuid(),
  barbeiro_id uuid not null references barbeiros(id) on delete cascade,
  dia_semana  smallint not null check (dia_semana between 0 and 6),
  hora_inicio time not null,
  hora_fim    time not null,
  unique (barbeiro_id, dia_semana)
);

-- ============================================================
-- AGENDAMENTOS
-- ============================================================
create table agendamentos (
  id                  uuid primary key default gen_random_uuid(),
  barbearia_id        uuid not null references barbearias(id) on delete cascade,
  barbeiro_id         uuid not null references barbeiros(id),
  servico_id          uuid not null references servicos(id),
  cliente_nome        text not null,
  cliente_telefone    text not null,
  data_hora           timestamptz not null,
  status              text not null default 'confirmado' check (status in ('confirmado','cancelado')),
  token_cancelamento  text unique not null default encode(gen_random_bytes(24), 'hex'),
  criado_em           timestamptz default now()
);

-- ============================================================
-- ÍNDICES
-- ============================================================
create index idx_barbeiros_barbearia   on barbeiros(barbearia_id);
create index idx_servicos_barbearia    on servicos(barbearia_id);
create index idx_horarios_barbeiro     on horarios(barbeiro_id);
create index idx_agendamentos_barbearia on agendamentos(barbearia_id);
create index idx_agendamentos_barbeiro  on agendamentos(barbeiro_id);
create index idx_agendamentos_data_hora on agendamentos(data_hora);
create index idx_agendamentos_token     on agendamentos(token_cancelamento);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table barbearias  enable row level security;
alter table barbeiros   enable row level security;
alter table servicos    enable row level security;
alter table horarios    enable row level security;
alter table agendamentos enable row level security;

-- Leitura pública de barbearias (para lookup por slug)
create policy "barbearias_select_public"
  on barbearias for select using (true);

-- Leitura pública de barbeiros ativos
create policy "barbeiros_select_public"
  on barbeiros for select using (ativo = true);

-- Leitura pública de serviços ativos
create policy "servicos_select_public"
  on servicos for select using (ativo = true);

-- Leitura pública de horários
create policy "horarios_select_public"
  on horarios for select using (true);

-- Leitura pública de agendamentos confirmados (para calcular disponibilidade)
create policy "agendamentos_select_public"
  on agendamentos for select using (status = 'confirmado');

-- Inserção pública de agendamentos (clientes agendando)
create policy "agendamentos_insert_public"
  on agendamentos for insert with check (true);

-- ============================================================
-- POLÍTICAS ADMIN (service_role key ignora RLS automaticamente)
-- As políticas abaixo são para o painel admin usar anon key com auth
-- ============================================================

-- Admin pode ver todos os agendamentos da sua barbearia
-- (Implemente via service_role no backend ou via claims JWT customizados)

-- ============================================================
-- FUNÇÕES AUXILIARES
-- ============================================================

-- Função: retorna horários disponíveis de um barbeiro em uma data
-- Parâmetros: p_barbeiro_id, p_servico_id, p_data (YYYY-MM-DD)
create or replace function get_horarios_disponiveis(
  p_barbeiro_id uuid,
  p_servico_id  uuid,
  p_data        date
)
returns table (horario time)
language plpgsql
as $$
declare
  v_dia_semana  smallint;
  v_hora_inicio time;
  v_hora_fim    time;
  v_duracao     integer;
  v_slot        time;
  v_agora       timestamptz;
begin
  v_dia_semana := extract(dow from p_data)::smallint;
  v_agora      := now() at time zone 'America/Sao_Paulo';

  -- Busca horário de funcionamento do barbeiro naquele dia
  select h.hora_inicio, h.hora_fim
    into v_hora_inicio, v_hora_fim
    from horarios h
   where h.barbeiro_id = p_barbeiro_id
     and h.dia_semana  = v_dia_semana;

  if not found then
    return; -- barbeiro não trabalha neste dia
  end if;

  -- Busca duração do serviço
  select s.duracao_minutos into v_duracao
    from servicos s where s.id = p_servico_id;

  -- Gera slots a cada duração do serviço
  v_slot := v_hora_inicio;
  while v_slot + (v_duracao || ' minutes')::interval <= v_hora_fim loop

    -- Verifica se o slot está no futuro
    if (p_data + v_slot)::timestamptz at time zone 'America/Sao_Paulo' > v_agora then

      -- Verifica se não há agendamento conflitante
      if not exists (
        select 1 from agendamentos a
        join servicos s2 on s2.id = a.servico_id
        where a.barbeiro_id = p_barbeiro_id
          and a.status      = 'confirmado'
          and date(a.data_hora at time zone 'America/Sao_Paulo') = p_data
          and (a.data_hora at time zone 'America/Sao_Paulo')::time < v_slot + (v_duracao || ' minutes')::interval
          and (a.data_hora at time zone 'America/Sao_Paulo')::time + (s2.duracao_minutos || ' minutes')::interval > v_slot
      ) then
        horario := v_slot;
        return next;
      end if;
    end if;

    v_slot := v_slot + (v_duracao || ' minutes')::interval;
  end loop;
end;
$$;

-- ============================================================
-- DADOS DE EXEMPLO (remova antes de ir para produção)
-- ============================================================
/*
insert into barbearias (slug, nome, whatsapp_dono) values
  ('demo', 'Barbearia Demo', '5511999999999');

insert into barbeiros (barbearia_id, nome, telefone_whatsapp) values
  ((select id from barbearias where slug='demo'), 'João Silva', '5511888888888'),
  ((select id from barbearias where slug='demo'), 'Carlos Mendes', '5511777777777');

insert into servicos (barbearia_id, nome, preco, duracao_minutos) values
  ((select id from barbearias where slug='demo'), 'Corte Degradê', 45.00, 30),
  ((select id from barbearias where slug='demo'), 'Barba', 25.00, 20),
  ((select id from barbearias where slug='demo'), 'Corte + Barba', 65.00, 50);

insert into horarios (barbeiro_id, dia_semana, hora_inicio, hora_fim)
select b.id, d.dia, '09:00'::time, '18:00'::time
from barbeiros b
cross join (values(1),(2),(3),(4),(5),(6)) as d(dia)
where b.barbearia_id = (select id from barbearias where slug='demo');
*/

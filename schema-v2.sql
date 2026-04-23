-- ============================================================
-- AgendaBarber — MIGRATION v2 (Marketplace)
-- Execute no SQL Editor do Supabase após a v1 (schema.sql)
-- ============================================================

-- ============================================================
-- 1. ALTERAR tabela barbearias (+ metadados para marketplace)
-- ============================================================
alter table barbearias add column if not exists logo_url     text;
alter table barbearias add column if not exists capa_url     text;
alter table barbearias add column if not exists descricao    text;
alter table barbearias add column if not exists cidade       text;
alter table barbearias add column if not exists estado       text;
alter table barbearias add column if not exists endereco     text;
alter table barbearias add column if not exists latitude     numeric(10,7);
alter table barbearias add column if not exists longitude    numeric(10,7);
alter table barbearias add column if not exists nota_media   numeric(3,2) default 0;
alter table barbearias add column if not exists total_avaliacoes integer default 0;
alter table barbearias add column if not exists publica      boolean default true;
  -- Se publica=false, barbearia não aparece no marketplace (só via link direto)

create index if not exists idx_barbearias_cidade on barbearias(cidade);
create index if not exists idx_barbearias_publica on barbearias(publica) where publica = true;


-- ============================================================
-- 2. TABELA clientes (login de usuário final)
-- ============================================================
create table if not exists clientes (
  id           uuid primary key default gen_random_uuid(),
  telefone     text unique not null,
  nome         text not null,
  email        text,
  senha_hash   text not null,
  endereco     text,
  cidade       text,
  latitude     numeric(10,7),
  longitude    numeric(10,7),
  criado_em    timestamptz default now()
);

create index if not exists idx_clientes_telefone on clientes(telefone);


-- ============================================================
-- 3. TABELA favoritos
-- ============================================================
create table if not exists favoritos (
  cliente_id   uuid not null references clientes(id) on delete cascade,
  barbearia_id uuid not null references barbearias(id) on delete cascade,
  criado_em    timestamptz default now(),
  primary key (cliente_id, barbearia_id)
);

create index if not exists idx_favoritos_cliente on favoritos(cliente_id);


-- ============================================================
-- 4. TABELA avaliações (cliente avalia, dono responde)
-- ============================================================
create table if not exists avaliacoes (
  id              uuid primary key default gen_random_uuid(),
  barbearia_id    uuid not null references barbearias(id) on delete cascade,
  cliente_id      uuid not null references clientes(id) on delete cascade,
  agendamento_id  uuid references agendamentos(id) on delete set null,
  nota            smallint not null check (nota between 1 and 5),
  comentario      text,
  resposta_dono   text,
  respondida_em   timestamptz,
  criado_em       timestamptz default now(),
  unique (agendamento_id)
);

create index if not exists idx_avaliacoes_barbearia on avaliacoes(barbearia_id);
create index if not exists idx_avaliacoes_cliente   on avaliacoes(cliente_id);


-- ============================================================
-- 5. TABELA banners (promoções do dono da barbearia)
-- ============================================================
create table if not exists banners (
  id            uuid primary key default gen_random_uuid(),
  barbearia_id  uuid not null references barbearias(id) on delete cascade,
  titulo        text not null,
  imagem_url    text,
  link          text,
  ativo         boolean default true,
  ordem         integer default 0,
  criado_em     timestamptz default now()
);

create index if not exists idx_banners_barbearia on banners(barbearia_id, ativo);


-- ============================================================
-- 6. ALTERAR agendamentos (+ cliente_id opcional)
-- ============================================================
alter table agendamentos add column if not exists cliente_id uuid references clientes(id) on delete set null;

create index if not exists idx_agendamentos_cliente on agendamentos(cliente_id);


-- ============================================================
-- 7. ROW LEVEL SECURITY (novas tabelas)
-- ============================================================
alter table clientes    enable row level security;
alter table favoritos   enable row level security;
alter table avaliacoes  enable row level security;
alter table banners     enable row level security;

-- clientes: leitura/escrita via service_role (auth customizada via API)
drop policy if exists "clientes_block_anon" on clientes;
create policy "clientes_block_anon"
  on clientes for all using (false);

-- favoritos: via API (service_role)
drop policy if exists "favoritos_block_anon" on favoritos;
create policy "favoritos_block_anon"
  on favoritos for all using (false);

-- avaliações: leitura pública
drop policy if exists "avaliacoes_select_public" on avaliacoes;
create policy "avaliacoes_select_public"
  on avaliacoes for select using (true);

-- banners: leitura pública dos ativos
drop policy if exists "banners_select_public" on banners;
create policy "banners_select_public"
  on banners for select using (ativo = true);


-- ============================================================
-- 8. FUNÇÃO: atualizar nota_media automaticamente
-- ============================================================
create or replace function atualizar_nota_media()
returns trigger language plpgsql as $$
begin
  update barbearias
     set nota_media = coalesce((
           select avg(nota)::numeric(3,2)
             from avaliacoes
            where barbearia_id = coalesce(new.barbearia_id, old.barbearia_id)
         ), 0),
         total_avaliacoes = (
           select count(*) from avaliacoes
            where barbearia_id = coalesce(new.barbearia_id, old.barbearia_id)
         )
   where id = coalesce(new.barbearia_id, old.barbearia_id);
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_avaliacoes_nota on avaliacoes;
create trigger trg_avaliacoes_nota
  after insert or update or delete on avaliacoes
  for each row execute function atualizar_nota_media();


-- ============================================================
-- 9. FUNÇÃO: buscar barbearias (nome / cidade / próximas)
-- ============================================================
create or replace function buscar_barbearias(
  p_termo   text default null,
  p_cidade  text default null,
  p_lat     numeric default null,
  p_lng     numeric default null,
  p_limit   integer default 30
)
returns table (
  id uuid, slug text, nome text, logo_url text, capa_url text,
  cidade text, estado text, nota_media numeric, total_avaliacoes integer,
  distancia_km numeric
) language plpgsql as $$
begin
  return query
    select b.id, b.slug, b.nome, b.logo_url, b.capa_url,
           b.cidade, b.estado, b.nota_media, b.total_avaliacoes,
           case
             when p_lat is not null and p_lng is not null and b.latitude is not null and b.longitude is not null
             then round(
               (6371 * acos(
                 cos(radians(p_lat)) * cos(radians(b.latitude)) *
                 cos(radians(b.longitude) - radians(p_lng)) +
                 sin(radians(p_lat)) * sin(radians(b.latitude))
               ))::numeric, 2)
             else null
           end as distancia_km
      from barbearias b
     where b.publica = true
       and (p_termo  is null or b.nome ilike '%' || p_termo || '%')
       and (p_cidade is null or b.cidade ilike '%' || p_cidade || '%')
  order by
    case when p_lat is not null and p_lng is not null and b.latitude is not null then
      (6371 * acos(
        cos(radians(p_lat)) * cos(radians(b.latitude)) *
        cos(radians(b.longitude) - radians(p_lng)) +
        sin(radians(p_lat)) * sin(radians(b.latitude))
      ))
    else 999999 end,
    b.nota_media desc
     limit p_limit;
end;
$$;


-- ============================================================
-- FIM — confere:
-- ============================================================
-- select * from barbearias limit 1;   -- deve ter colunas novas
-- select * from clientes;              -- tabela criada vazia
-- select * from avaliacoes;            -- idem
-- select * from buscar_barbearias();   -- lista barbearias públicas

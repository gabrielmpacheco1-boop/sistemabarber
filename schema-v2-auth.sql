-- ============================================================
-- AgendaBarber — Patch de Autenticação de Clientes
-- Execute DEPOIS do schema-v2.sql
-- ============================================================

-- Remover senha_hash (vamos usar Supabase Auth nativo)
alter table clientes drop column if exists senha_hash;

-- ID do cliente = auth.users.id (link direto com Supabase Auth)
alter table clientes alter column id drop default;

-- RLS: cliente autenticado vê/edita apenas seus próprios dados
drop policy if exists "clientes_block_anon"  on clientes;
drop policy if exists "clientes_select_own"  on clientes;
drop policy if exists "clientes_insert_own"  on clientes;
drop policy if exists "clientes_update_own"  on clientes;

create policy "clientes_select_own" on clientes
  for select using (auth.uid() = id);

create policy "clientes_insert_own" on clientes
  for insert with check (auth.uid() = id);

create policy "clientes_update_own" on clientes
  for update using (auth.uid() = id);

-- Favoritos: cliente gerencia só os seus
drop policy if exists "favoritos_block_anon"  on favoritos;
drop policy if exists "favoritos_select_own"  on favoritos;
drop policy if exists "favoritos_write_own"   on favoritos;

create policy "favoritos_select_own" on favoritos
  for select using (auth.uid() = cliente_id);

create policy "favoritos_write_own" on favoritos
  for all using (auth.uid() = cliente_id) with check (auth.uid() = cliente_id);

-- Avaliações: cliente insere só como ele próprio; leitura pública já existe
drop policy if exists "avaliacoes_insert_own" on avaliacoes;
create policy "avaliacoes_insert_own" on avaliacoes
  for insert with check (auth.uid() = cliente_id);

-- Agendamentos: cliente autenticado vê os seus
drop policy if exists "agendamentos_select_own" on agendamentos;
create policy "agendamentos_select_own" on agendamentos
  for select using (
    (auth.uid() is not null and auth.uid() = cliente_id)
    or status = 'confirmado'  -- público para disponibilidade
  );

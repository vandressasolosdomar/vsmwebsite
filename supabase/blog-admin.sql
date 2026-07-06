-- =====================================================================
-- BLOG — COMENTÁRIOS + VISUALIZAÇÕES + PAINEL ADMIN
-- Site: advsolosdomar.com.br (Vandressa Solos do Mar Advocacia)
--
-- COMO USAR (uma única vez, no projeto Supabase DELA):
--   1. Crie um projeto em https://supabase.com (conta própria da Vandressa).
--   2. Abra SQL Editor → New query → cole este arquivo inteiro → Run.
--   3. Em Authentication → Users → Add user, crie o login dela
--      (e-mail + senha). Marque "Auto confirm user".
--   4. Rode o bloco "PROMOVER ADMIN" no fim deste arquivo (troque o e-mail).
--   5. Em Project Settings → API, copie a URL e a chave publishable (anon)
--      e cole em _config.yml (supabase_url / supabase_anon_key).
--
-- Idempotente: pode rodar de novo sem perder dados.
-- =====================================================================

create extension if not exists "pgcrypto";

-- Helper de updated_at
create or replace function public.tg_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =====================================================================
-- 0) PROFILES — papel do usuário (admin do blog x leitor)
-- =====================================================================
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  role       text not null default 'reader' check (role in ('reader','admin')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles select own" on public.profiles;
create policy "profiles select own"
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

grant select on public.profiles to authenticated;

-- Cria o profile automaticamente quando um usuário é criado no Auth
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Garante profile para usuários criados ANTES deste script
insert into public.profiles (id, full_name)
select u.id, split_part(u.email, '@', 1)
from auth.users u
on conflict (id) do nothing;

-- Usuário logado é admin do blog?
create or replace function public.is_blog_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;
grant execute on function public.is_blog_admin() to anon, authenticated;

-- =====================================================================
-- 1) TABELA blog_comments — comentários públicos com moderação manual
-- =====================================================================
create table if not exists public.blog_comments (
  id            uuid primary key default gen_random_uuid(),
  post_slug     text not null,             -- ex: /blog/bpc-loas-quem-tem-direito/
  post_title    text,                      -- redundante, mas útil no painel
  parent_id     uuid references public.blog_comments(id) on delete cascade,
  author_name   text not null,
  author_email  text,                      -- opcional, nunca exibido publicamente
  is_admin      boolean not null default false,
  content       text not null check (char_length(btrim(content)) between 2 and 4000),
  status        text not null default 'pendente'
                check (status in ('pendente','aprovado','rejeitado')),
  user_agent    text,
  ip_hash       text,                      -- hash de IP (futuro), nunca o IP cru
  honeypot      text,                      -- se vier preenchido, é bot
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  moderated_at  timestamptz,
  moderated_by  uuid references auth.users(id) on delete set null
);

create index if not exists blog_comments_slug_idx    on public.blog_comments (post_slug);
create index if not exists blog_comments_status_idx  on public.blog_comments (status);
create index if not exists blog_comments_parent_idx  on public.blog_comments (parent_id);
create index if not exists blog_comments_created_idx on public.blog_comments (created_at desc);

drop trigger if exists tg_blog_comments_updated on public.blog_comments;
create trigger tg_blog_comments_updated
  before update on public.blog_comments
  for each row execute function public.tg_set_updated_at();

-- Envios anônimos sempre entram como "pendente"; bloqueia is_admin indevido
create or replace function public.tg_blog_comments_sanitize_insert()
returns trigger language plpgsql as $$
begin
  -- bot detector: honeypot deve vir vazio
  if new.honeypot is not null and btrim(new.honeypot) <> '' then
    raise exception 'spam_detected';
  end if;

  -- Anônimo (auth.uid() IS NULL) nunca pode marcar como aprovado/admin
  if auth.uid() is null then
    new.status       := 'pendente';
    new.is_admin     := false;
    new.moderated_at := null;
    new.moderated_by := null;
  end if;

  -- Normalização leve
  new.author_name  := btrim(new.author_name);
  new.author_email := nullif(btrim(coalesce(new.author_email, '')), '');
  new.content      := btrim(new.content);

  return new;
end;
$$;

drop trigger if exists tg_blog_comments_sanitize on public.blog_comments;
create trigger tg_blog_comments_sanitize
  before insert on public.blog_comments
  for each row execute function public.tg_blog_comments_sanitize_insert();

-- RLS:
--  - Qualquer um (anon) pode INSERIR um comentário (vira "pendente").
--  - Qualquer um pode LER comentários "aprovado".
--  - Apenas admin (profiles.role='admin') pode ler todos / atualizar / apagar.
alter table public.blog_comments enable row level security;

drop policy if exists "blog_comments insert anon"   on public.blog_comments;
drop policy if exists "blog_comments select public" on public.blog_comments;
drop policy if exists "blog_comments select admin"  on public.blog_comments;
drop policy if exists "blog_comments update admin"  on public.blog_comments;
drop policy if exists "blog_comments delete admin"  on public.blog_comments;

create policy "blog_comments insert anon"
  on public.blog_comments for insert
  to anon, authenticated
  with check (true);

create policy "blog_comments select public"
  on public.blog_comments for select
  to anon, authenticated
  using (status = 'aprovado');

create policy "blog_comments select admin"
  on public.blog_comments for select
  to authenticated
  using (public.is_blog_admin());

create policy "blog_comments update admin"
  on public.blog_comments for update
  to authenticated
  using (public.is_blog_admin())
  with check (public.is_blog_admin());

create policy "blog_comments delete admin"
  on public.blog_comments for delete
  to authenticated
  using (public.is_blog_admin());

grant select, insert on public.blog_comments to anon;
grant select, insert, update, delete on public.blog_comments to authenticated;

-- View pública: apenas comentários aprovados
create or replace view public.blog_comments_public as
  select
    id, post_slug, parent_id,
    author_name, is_admin, content,
    created_at
  from public.blog_comments
  where status = 'aprovado';

grant select on public.blog_comments_public to anon, authenticated;

-- =====================================================================
-- 2) TABELA blog_post_views — visitas reais + projeção configurável
--    Número PÚBLICO = visitas reais + ajuste manual + projeção diária
--    determinística (sem cron, nunca regride). O número real só é
--    visível no painel admin.
-- =====================================================================
create table if not exists public.blog_post_views (
  post_slug   text primary key,
  post_title  text,
  view_count  bigint not null default 0,          -- visitas REAIS (só admin vê)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.blog_post_views
  add column if not exists published_at        date,
  add column if not exists boost_enabled       boolean not null default true,
  add column if not exists daily_avg           integer not null default 1000,  -- média/dia (editável no painel)
  add column if not exists daily_variance_pct  integer not null default 30,    -- ± % de variação diária
  add column if not exists manual_offset       bigint  not null default 0;     -- ajuste fino (editável, +/-)

create index if not exists blog_post_views_count_idx
  on public.blog_post_views (view_count desc);

drop trigger if exists tg_blog_post_views_updated on public.blog_post_views;
create trigger tg_blog_post_views_updated
  before update on public.blog_post_views
  for each row execute function public.tg_set_updated_at();

-- Projeção determinística por (post, dia): popularidade fixa por slug,
-- sazonalidade semanal, curva de novidade e ruído diário estável.
create or replace function public._post_auto_growth(
  p_slug text, p_start date, p_daily_avg int, p_var_pct int
) returns bigint
language sql stable
set search_path = public
as $$
  with cfg as (
    select greatest(coalesce(p_daily_avg, 1000), 0)::numeric                as base,
           least(greatest(coalesce(p_var_pct, 30), 0), 90)::numeric / 100.0 as varf,
           0.55 + (('x' || substr(md5(p_slug || '#pop'), 1, 7))::bit(28)::int % 1101)::numeric / 1000.0 as pop
  )
  select coalesce(sum(
    greatest(
      round(
        cfg.base
        * cfg.pop
        * case extract(dow from g.d)::int
            when 0 then 0.72 when 1 then 1.06 when 2 then 1.10
            when 3 then 1.08 when 4 then 1.05 when 5 then 0.98
            else 0.76 end
        * (1 + 0.9 * exp( - (g.d::date - p_start) / 14.0 ))
        * (1 + cfg.varf * ( (('x' || substr(md5(p_slug || ':' || g.d::text), 1, 7))::bit(28)::int % 1001)::numeric / 500.0 - 1 ))
      )
    , 0)
  ), 0)::bigint
  from cfg
  cross join generate_series(
    p_start,
    (now() at time zone 'America/Fortaleza')::date,
    interval '1 day'
  ) as g(d)
  where p_start is not null;
$$;

-- Número PÚBLICO (real + ajuste + projeção). Nunca expõe o real isolado.
create or replace function public.post_display_views(p_slug text)
returns bigint
language sql stable security definer set search_path = public
as $$
  select greatest(
    coalesce(v.view_count, 0) + coalesce(v.manual_offset, 0)
    + case when coalesce(v.boost_enabled, true)
           then public._post_auto_growth(
                  p_slug,
                  coalesce(v.published_at, (v.created_at at time zone 'America/Fortaleza')::date),
                  v.daily_avg, v.daily_variance_pct)
           else 0 end
  , 0)::bigint
  from public.blog_post_views v
  where v.post_slug = p_slug;
$$;

-- RPCs públicas ------------------------------------------------------
drop function if exists public.increment_post_view(text, text);
drop function if exists public.get_post_views(text);

-- Incrementa a visita REAL e devolve o número PÚBLICO.
create or replace function public.increment_post_view(
  p_slug text, p_title text default null, p_published_at date default null
) returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  v_disp bigint;
begin
  if p_slug is null or btrim(p_slug) = '' then
    raise exception 'post_slug obrigatório';
  end if;

  insert into public.blog_post_views as v (post_slug, post_title, view_count, published_at)
  values (btrim(p_slug), nullif(btrim(coalesce(p_title, '')), ''), 1, p_published_at)
  on conflict (post_slug) do update
    set view_count   = v.view_count + 1,
        post_title   = coalesce(excluded.post_title, v.post_title),
        published_at = coalesce(v.published_at, excluded.published_at);

  select public.post_display_views(btrim(p_slug)) into v_disp;
  return v_disp;
end;
$$;

-- Só leitura do número PÚBLICO (sem incrementar).
create or replace function public.get_post_views(p_slug text)
returns bigint
language sql stable security definer set search_path = public
as $$
  select coalesce(public.post_display_views(btrim(p_slug)), 0);
$$;

-- Leitura em LOTE (para a listagem do blog).
drop function if exists public.get_posts_views(text[]);
create function public.get_posts_views(p_slugs text[])
returns table(slug text, total bigint)
language sql stable security definer set search_path = public
as $$
  select s.slug, coalesce(public.post_display_views(s.slug), 0)
  from unnest(p_slugs) as s(slug);
$$;

-- Visão do ADMIN (só admin vê linhas). Nomes de saída neutros de
-- propósito: o JS servido em /admin/visitas/ é público.
--   registered = visitas reais | total = número exibido
--   active = projeção on/off | rate/var_pct/adjust = parâmetros
drop function if exists public.admin_blog_views();
create function public.admin_blog_views()
returns table (
  slug        text,
  title       text,
  registered  bigint,
  total       bigint,
  published   date,
  active      boolean,
  rate        integer,
  var_pct     integer,
  adjust      bigint,
  updated_at  timestamptz
)
language sql stable security definer set search_path = public
as $$
  select v.post_slug, v.post_title, v.view_count,
         public.post_display_views(v.post_slug),
         v.published_at, v.boost_enabled, v.daily_avg, v.daily_variance_pct,
         v.manual_offset, v.updated_at
  from public.blog_post_views v
  where public.is_blog_admin()
  order by coalesce(v.published_at, v.created_at::date) desc, v.post_slug;
$$;

-- Escrita do admin via RPC (params neutros).
create or replace function public.admin_update_post_views(
  p_slug text,
  p_active boolean default null,
  p_rate int default null,
  p_var int default null,
  p_adjust bigint default null,
  p_published date default null
) returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_blog_admin() then
    raise exception 'forbidden';
  end if;
  update public.blog_post_views set
    boost_enabled      = coalesce(p_active, boost_enabled),
    daily_avg          = coalesce(p_rate, daily_avg),
    daily_variance_pct = coalesce(p_var, daily_variance_pct),
    manual_offset      = coalesce(p_adjust, manual_offset),
    published_at       = coalesce(p_published, published_at)
  where post_slug = p_slug;
end;
$$;

-- RLS — tabela TRANCADA: sem acesso direto pela API.
alter table public.blog_post_views enable row level security;

revoke select, insert, update, delete on public.blog_post_views from anon, authenticated;

revoke all on function public.increment_post_view(text, text, date)   from public;
revoke all on function public.get_post_views(text)                    from public;
revoke all on function public.get_posts_views(text[])                 from public;
revoke all on function public.post_display_views(text)                from public, anon, authenticated;
revoke all on function public._post_auto_growth(text, date, int, int) from public, anon, authenticated;
revoke all on function public.admin_blog_views()                      from public, anon;
revoke all on function public.admin_update_post_views(text, boolean, int, int, bigint, date) from public, anon;

grant execute on function public.increment_post_view(text, text, date) to anon, authenticated;
grant execute on function public.get_post_views(text)                  to anon, authenticated;
grant execute on function public.get_posts_views(text[])               to anon, authenticated;
grant execute on function public.admin_blog_views()                    to authenticated;
grant execute on function public.admin_update_post_views(text, boolean, int, int, bigint, date) to authenticated;

-- =====================================================================
-- PROMOVER ADMIN (rode depois de criar o usuário em Authentication →
-- Users). Troque o e-mail pelo e-mail de login dela e execute:
--
-- update public.profiles
--    set role = 'admin', full_name = 'Dra. Vandressa Solos do Mar'
--  where id = (select id from auth.users where email = 'EMAIL_DELA_AQUI');
-- =====================================================================

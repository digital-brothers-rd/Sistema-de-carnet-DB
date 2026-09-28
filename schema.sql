-- =====================================================
-- Digital Brothers RD · Sistema de carnets con roles
-- Ejecutar completo en Supabase → SQL Editor, en orden.
-- =====================================================

-- 1. Tabla de carnets
create table if not exists public.empleados_carnets (
  id              uuid primary key default gen_random_uuid(),
  id_unico        text unique,                       -- lo asigna el trigger
  nombre_completo text not null check (length(trim(nombre_completo)) > 0),
  cargo           text not null check (length(trim(cargo)) > 0),
  fecha_emision   date not null default current_date,
  estado          text not null default 'Activo'
                  check (estado in ('Activo', 'Inactivo')),
  user_id         uuid references auth.users(id) on delete set null, -- colaborador dueño del carnet
  created_at      timestamptz not null default now()
);

-- 2. Perfiles: vincula cada login con su rol (admin / colaborador)
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  email           text not null,
  nombre_completo text not null,
  rol             text not null default 'colaborador' check (rol in ('admin', 'colaborador')),
  created_at      timestamptz not null default now()
);

-- Columna de estado de acceso (independiente del estado del carnet).
-- Con "add column if not exists" es seguro volver a correr este script.
alter table public.profiles add column if not exists acceso text not null default 'Activo';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_acceso_check') then
    alter table public.profiles add constraint profiles_acceso_check check (acceso in ('Activo', 'Suspendido'));
  end if;
end $$;

-- 3. Contador de correlativo por año
create table if not exists public.carnets_contador (
  anio   int primary key,
  ultimo int not null default 0
);

-- 4. Función que genera DBRD-AAAA-001, 002, ...
create or replace function public.asignar_id_unico()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_anio int := extract(year from coalesce(new.fecha_emision, current_date));
  v_num  int;
begin
  insert into public.carnets_contador (anio, ultimo)
  values (v_anio, 1)
  on conflict (anio) do update set ultimo = carnets_contador.ultimo + 1
  returning ultimo into v_num;

  new.id_unico := 'DBRD-' || v_anio || '-' || lpad(v_num::text, 3, '0');
  return new;
end;
$$;

drop trigger if exists trg_asignar_id_unico on public.empleados_carnets;
create trigger trg_asignar_id_unico
before insert on public.empleados_carnets
for each row execute function public.asignar_id_unico();

-- 5. Función auxiliar: ¿el usuario que llama es admin?
create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and rol = 'admin'
  );
$$;

-- 6. Seguridad (RLS)
alter table public.empleados_carnets enable row level security;
alter table public.profiles          enable row level security;
alter table public.carnets_contador  enable row level security; -- sin políticas: nadie lo toca desde el cliente

-- Carnets: un admin ve y gestiona todo; un colaborador solo ve el suyo
drop policy if exists "carnets_select" on public.empleados_carnets;
drop policy if exists "carnets_insert" on public.empleados_carnets;
drop policy if exists "carnets_update" on public.empleados_carnets;

create policy "carnets_select" on public.empleados_carnets
  for select to authenticated
  using (public.is_admin() or user_id = auth.uid());

create policy "carnets_insert_admin" on public.empleados_carnets
  for insert to authenticated
  with check (public.is_admin());

create policy "carnets_update_admin" on public.empleados_carnets
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- No hay política de DELETE a propósito: los carnets se revocan, no se borran.

-- Perfiles: cada quien ve el suyo; el admin ve y edita todos
create policy "profiles_select" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

create policy "profiles_update_admin" on public.profiles
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- No hay política de INSERT: los perfiles solo se crean desde la Edge Function
-- (con la service role key), nunca directo desde el navegador.

-- =====================================================
-- 7. Bootstrap del primer administrador (ejecutar UNA sola vez)
-- =====================================================
-- a) Ve a Authentication → Users → Add user y crea la cuenta del admin
--    (correo + contraseña, marca "Auto Confirm User").
-- b) Copia su UUID y ejecuta esto, reemplazando los valores:
--
-- insert into public.profiles (id, email, nombre_completo, rol)
-- values ('UUID-DEL-ADMIN', 'admin@digitalbrothersrd.com', 'Admin Principal', 'admin')
-- on conflict (id) do update set rol = 'admin';
--
-- A partir de aquí, el admin crea a todos los demás colaboradores
-- desde el propio panel (usa la Edge Function "crear-colaborador").

-- Didi's Dogs admin: one-time setup.
-- Paste all of this into Supabase > SQL Editor > New query, then tap Run.
-- The FIRST person to create an account becomes the owner (admin).
-- Everyone after that waits for the owner to approve them.

-- ========== People (owner + workers) ==========
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  email text,
  phone text,
  role text not null default 'pending' check (role in ('admin','crew','pending','removed')),
  pay_rate numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.is_worker() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('admin','crew'));
$$;

-- New sign-up -> profile. First one ever is the owner.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from public.profiles where role = 'admin') then 'pending' else 'admin' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Workers can change their own name/phone only. Never leave zero owners.
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.role := old.role;
    new.pay_rate := old.pay_rate;
    new.email := old.email;
  end if;
  if old.role = 'admin' and new.role <> 'admin'
     and (select count(*) from public.profiles where role = 'admin') <= 1 then
    raise exception 'There must always be at least one owner';
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

alter table public.profiles enable row level security;
drop policy if exists "see self or admin" on public.profiles;
create policy "see self or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
drop policy if exists "edit self or admin" on public.profiles;
create policy "edit self or admin" on public.profiles
  for update to authenticated using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- ========== Inventory ==========
create table if not exists public.inventory_items (
  id bigint generated always as identity primary key,
  name text not null,
  category text not null default 'Other',
  unit text not null default '',
  qty numeric not null default 0 check (qty >= 0),
  low_at numeric not null default 0 check (low_at >= 0),
  on_list boolean not null default false,
  notes text,
  updated_at timestamptz not null default now()
);

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists inventory_touch on public.inventory_items;
create trigger inventory_touch before update on public.inventory_items
  for each row execute function public.touch_updated_at();

alter table public.inventory_items enable row level security;
drop policy if exists "owner manages inventory" on public.inventory_items;
create policy "owner manages inventory" on public.inventory_items
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ========== Worker hours ==========
create table if not exists public.shifts (
  id bigint generated always as identity primary key,
  worker_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  work_date date not null,
  start_time time not null,
  end_time time not null,
  hours numeric(5,2) not null default 0,
  rate numeric(10,2) not null default 0,
  note text,
  paid boolean not null default false,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- Works out hours (handles shifts past midnight), locks in pay rate,
-- and stops workers from marking themselves paid or editing paid shifts.
create or replace function public.shifts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare mins numeric;
begin
  if new.end_time = new.start_time then
    raise exception 'Start and end time cannot be the same';
  end if;
  mins := extract(epoch from (new.end_time - new.start_time)) / 60;
  if mins < 0 then mins := mins + 1440; end if;
  new.hours := round(mins / 60, 2);

  if tg_op = 'INSERT' then
    new.rate := coalesce((select pay_rate from public.profiles where id = new.worker_id), 0);
  end if;

  if not public.is_admin() then
    if tg_op = 'INSERT' then
      new.paid := false; new.paid_at := null;
    else
      if old.paid then raise exception 'This shift was already paid'; end if;
      new.paid := old.paid; new.paid_at := old.paid_at;
      new.rate := old.rate; new.worker_id := old.worker_id;
    end if;
  else
    if new.paid and new.paid_at is null then new.paid_at := now(); end if;
    if not new.paid then new.paid_at := null; end if;
  end if;
  return new;
end $$;

drop trigger if exists shifts_guard on public.shifts;
create trigger shifts_guard before insert or update on public.shifts
  for each row execute function public.shifts_guard();

alter table public.shifts enable row level security;
drop policy if exists "see own or admin" on public.shifts;
create policy "see own or admin" on public.shifts
  for select to authenticated using (worker_id = auth.uid() or public.is_admin());
drop policy if exists "add own or admin" on public.shifts;
create policy "add own or admin" on public.shifts
  for insert to authenticated
  with check ((worker_id = auth.uid() and public.is_worker()) or public.is_admin());
drop policy if exists "edit own unpaid or admin" on public.shifts;
create policy "edit own unpaid or admin" on public.shifts
  for update to authenticated
  using ((worker_id = auth.uid() and not paid) or public.is_admin())
  with check (worker_id = auth.uid() or public.is_admin());
drop policy if exists "delete own unpaid or admin" on public.shifts;
create policy "delete own unpaid or admin" on public.shifts
  for delete to authenticated
  using ((worker_id = auth.uid() and not paid) or public.is_admin());

-- ========== Access ==========
revoke all on public.profiles, public.inventory_items, public.shifts from anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.inventory_items, public.shifts to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ========== Starter inventory (edit or delete anything in the app) ==========
insert into public.inventory_items (name, category, unit)
select v.name, v.category, v.unit from (values
  ('Hot dogs','Meat','pack'),
  ('Jumbo hot dogs','Meat','pack'),
  ('Spicy dogs','Meat','pack'),
  ('Beef sausages','Meat','pack'),
  ('Pastrami','Meat','lb'),
  ('Veggie dogs','Meat','pack'),
  ('Hot dog buns','Buns','pack'),
  ('Jumbo buns','Buns','pack'),
  ('Gluten-free buns','Buns','pack'),
  ('Sauerkraut','Toppings','jar'),
  ('Onions','Toppings','bag'),
  ('Crispy fried onions','Toppings','container'),
  ('Pickles','Toppings','jar'),
  ('Relish','Toppings','jar'),
  ('Jalapeños','Toppings','jar'),
  ('Tomatoes','Toppings','lb'),
  ('Coleslaw','Toppings','container'),
  ('Chili','Toppings','can'),
  ('Ketchup','Sauces','bottle'),
  ('Yellow mustard','Sauces','bottle'),
  ('Deli mustard','Sauces','bottle'),
  ('Mayo','Sauces','jar'),
  ('BBQ sauce','Sauces','bottle'),
  ('Hot sauce','Sauces','bottle'),
  ('Sriracha','Sauces','bottle'),
  ('Tahini','Sauces','bottle'),
  ('Amba','Sauces','bottle'),
  ('French fries','Sides','bag'),
  ('Potato knishes','Sides','box'),
  ('Chips','Sides','box'),
  ('Salt','Seasonings','container'),
  ('Pepper','Seasonings','container'),
  ('Fry seasoning','Seasonings','container'),
  ('Soda cans','Drinks','case'),
  ('Water bottles','Drinks','case'),
  ('Seltzer','Drinks','case'),
  ('Juice boxes','Drinks','case'),
  ('Frying oil','Cooking','jug'),
  ('Propane tank','Cooking','tank'),
  ('Cooking spray','Cooking','can'),
  ('Aluminum foil','Cooking','roll'),
  ('Hot dog trays','Serving','pack'),
  ('Fry cups','Serving','pack'),
  ('Napkins','Serving','pack'),
  ('Plates','Serving','pack'),
  ('Forks','Serving','box'),
  ('Cups','Serving','pack'),
  ('Condiment cups & lids','Serving','pack'),
  ('Gloves','Cleaning','box'),
  ('Hairnets','Cleaning','box'),
  ('Paper towels','Cleaning','pack'),
  ('Sanitizer','Cleaning','bottle'),
  ('Degreaser','Cleaning','bottle'),
  ('Dish soap','Cleaning','bottle'),
  ('Trash bags','Cleaning','box'),
  ('Ice','Cooking','bag')
) as v(name, category, unit)
where not exists (select 1 from public.inventory_items);

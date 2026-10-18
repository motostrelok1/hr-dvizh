-- HR CRM / ATS — миграция 001: схема и RLS для этапа 1A
-- Целевая БД: PostgreSQL 15+ (self-hosted Supabase)

create extension if not exists pgcrypto;

-- =========================================================
-- 1. ТИПЫ
-- =========================================================
create type org_role as enum ('owner', 'admin', 'hr_lead', 'recruiter', 'hiring_manager', 'interviewer');
create type vacancy_role as enum ('recruiter', 'hiring_manager', 'interviewer');
create type vacancy_status as enum ('draft', 'open', 'paused', 'closed');
create type stage_kind as enum ('normal', 'hired', 'rejected', 'reserve');
create type note_visibility as enum ('hr_only', 'team');
create type task_status as enum ('open', 'done', 'cancelled');

-- =========================================================
-- 2. ДОСТУП И ОРГАНИЗАЦИИ
-- =========================================================
create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  settings jsonb not null default jsonb_build_object('interviewer_sees_contacts', false),
  created_at timestamptz not null default now()
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text,
  created_at timestamptz not null default now()
);

create table memberships (
  org_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role org_role not null,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index on memberships (user_id);

create table platform_admins (
  user_id uuid primary key references profiles(id) on delete cascade
);

-- =========================================================
-- 3. ПОДБОР
-- =========================================================
create table sources (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  unique (org_id, name)
);

create table rejection_reasons (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  unique (org_id, name)
);

create table vacancies (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  title text not null,
  description text,
  requirements text,
  status vacancy_status not null default 'draft',
  owner_id uuid references profiles(id),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on vacancies (org_id, status);

create table vacancy_members (
  vacancy_id uuid not null references vacancies(id) on delete cascade,
  org_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role vacancy_role not null,
  primary key (vacancy_id, user_id)
);
create index on vacancy_members (user_id);
create index on vacancy_members (org_id);

create table pipelines (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  vacancy_id uuid not null unique references vacancies(id) on delete cascade
);

create table pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  pipeline_id uuid not null references pipelines(id) on delete cascade,
  name text not null,
  position int not null,
  kind stage_kind not null default 'normal',
  sla_hours int,
  unique (pipeline_id, position) deferrable initially deferred
);
create index on pipeline_stages (pipeline_id);

create table candidates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  full_name text not null,
  phone text,
  email text,
  source_id uuid references sources(id),
  external_ids jsonb not null default '{}'::jsonb,   -- {"hh": "..."}
  consent_at timestamptz,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on candidates (org_id);
create index on candidates (org_id, phone);
create index on candidates (org_id, lower(email));

create table applications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  candidate_id uuid not null references candidates(id) on delete cascade,
  vacancy_id uuid not null references vacancies(id) on delete cascade,
  stage_id uuid not null references pipeline_stages(id),
  assignee_id uuid references profiles(id),
  next_action text,
  next_action_due timestamptz,
  rejection_reason_id uuid references rejection_reasons(id),
  stage_entered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (candidate_id, vacancy_id)
);
create index on applications (org_id, vacancy_id, stage_id);
create index on applications (assignee_id);

-- =========================================================
-- 4. ИСТОРИЯ
-- =========================================================
create table application_events (
  id bigint generated always as identity primary key,
  org_id uuid not null references organizations(id) on delete cascade,
  application_id uuid not null references applications(id) on delete cascade,
  actor_id uuid references profiles(id),
  type text not null,                -- 'created','stage_changed','assigned','rejected',...
  from_stage_id uuid references pipeline_stages(id),
  to_stage_id uuid references pipeline_stages(id),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index on application_events (application_id, created_at);

create table notes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  application_id uuid not null references applications(id) on delete cascade,
  author_id uuid not null references profiles(id),
  body text not null,
  visibility note_visibility not null default 'hr_only',
  created_at timestamptz not null default now()
);
create index on notes (application_id);

create table audit_log (
  id bigint generated always as identity primary key,
  org_id uuid references organizations(id) on delete cascade,
  actor_id uuid,
  action text not null,
  entity text not null,
  entity_id text,
  diff jsonb,
  created_at timestamptz not null default now()
);
create index on audit_log (org_id, created_at);

-- =========================================================
-- 5. ЗАДАЧИ, ФАЙЛЫ
-- =========================================================
create table tasks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  application_id uuid references applications(id) on delete cascade,
  title text not null,
  assignee_id uuid references profiles(id),
  due_at timestamptz,
  status task_status not null default 'open',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index on tasks (org_id, assignee_id, status);

create table files (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  application_id uuid references applications(id) on delete cascade,
  candidate_id uuid references candidates(id) on delete cascade,
  storage_path text not null,
  file_name text not null,
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

-- =========================================================
-- 6. КОММУНИКАЦИИ (внутренний чат и уведомления)
-- =========================================================
create table notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  type text not null,
  payload jsonb not null default '{}'::jsonb,
  dedup_key text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, dedup_key)
);
create index on notifications (user_id, read_at);

create table conversations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  application_id uuid references applications(id) on delete cascade,
  vacancy_id uuid references vacancies(id) on delete cascade,
  title text,
  created_at timestamptz not null default now()
);

create table conversation_members (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  primary key (conversation_id, user_id)
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  author_id uuid not null references profiles(id),
  body text not null,
  created_at timestamptz not null default now()
);
create index on messages (conversation_id, created_at);

-- =========================================================
-- 7. ФУНКЦИИ ДОСТУПА (security definer, чтобы не зацикливать RLS)
-- =========================================================
create or replace function is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;

create or replace function org_role_of(p_org uuid) returns org_role
language sql stable security definer set search_path = public as $$
  select role from memberships where org_id = p_org and user_id = auth.uid();
$$;

create or replace function is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select org_role_of(p_org) is not null;
$$;

-- Админ-уровень: видит и меняет всё в организации
create or replace function is_org_manager(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(org_role_of(p_org) in ('owner','admin','hr_lead'), false);
$$;

-- Рекрутер, владелец и т.д. — полноправная работа с вакансиями
create or replace function can_access_vacancy(p_vacancy uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from vacancies v
    where v.id = p_vacancy
      and (
        is_org_manager(v.org_id)
        or v.owner_id = auth.uid()
        or exists (select 1 from vacancy_members vm
                   where vm.vacancy_id = v.id and vm.user_id = auth.uid())
      )
  );
$$;

-- Роль пользователя именно в рамках вакансии
create or replace function vacancy_role_of(p_vacancy uuid) returns vacancy_role
language sql stable security definer set search_path = public as $$
  select role from vacancy_members where vacancy_id = p_vacancy and user_id = auth.uid();
$$;

-- «HR-доступ» к вакансии: менеджер организации, владелец или рекрутер вакансии
create or replace function is_vacancy_hr(p_vacancy uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from vacancies v
    where v.id = p_vacancy
      and (
        is_org_manager(v.org_id)
        or v.owner_id = auth.uid()
        or exists (select 1 from vacancy_members vm
                   where vm.vacancy_id = v.id and vm.user_id = auth.uid() and vm.role = 'recruiter')
      )
  );
$$;

create or replace function app_vacancy(p_application uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select vacancy_id from applications where id = p_application;
$$;

-- =========================================================
-- 8. ВКЛЮЧЕНИЕ RLS
-- =========================================================
alter table organizations        enable row level security;
alter table profiles             enable row level security;
alter table memberships          enable row level security;
alter table platform_admins      enable row level security;
alter table sources              enable row level security;
alter table rejection_reasons    enable row level security;
alter table vacancies            enable row level security;
alter table vacancy_members      enable row level security;
alter table pipelines            enable row level security;
alter table pipeline_stages      enable row level security;
alter table candidates           enable row level security;
alter table applications         enable row level security;
alter table application_events   enable row level security;
alter table notes                enable row level security;
alter table audit_log            enable row level security;
alter table tasks                enable row level security;
alter table files                enable row level security;
alter table notifications        enable row level security;
alter table conversations        enable row level security;
alter table conversation_members enable row level security;
alter table messages             enable row level security;

-- =========================================================
-- 9. ПОЛИТИКИ
-- =========================================================
-- organizations
create policy org_select on organizations for select using (is_member(id));
create policy org_update on organizations for update
  using (org_role_of(id) in ('owner','admin')) with check (org_role_of(id) in ('owner','admin'));

-- profiles: свой профиль и профили коллег по организации
create policy profiles_select on profiles for select using (
  id = auth.uid()
  or exists (select 1 from memberships a join memberships b on a.org_id = b.org_id
             where a.user_id = auth.uid() and b.user_id = profiles.id)
);
create policy profiles_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- memberships
create policy mem_select on memberships for select using (is_member(org_id));
create policy mem_write on memberships for all
  using (org_role_of(org_id) in ('owner','admin'))
  with check (org_role_of(org_id) in ('owner','admin'));

-- platform_admins: только через серверные функции (политик нет)

-- справочники
create policy sources_select on sources for select using (is_member(org_id));
create policy sources_write on sources for all using (is_org_manager(org_id)) with check (is_org_manager(org_id));
create policy reasons_select on rejection_reasons for select using (is_member(org_id));
create policy reasons_write on rejection_reasons for all using (is_org_manager(org_id)) with check (is_org_manager(org_id));

-- vacancies
create policy vac_select on vacancies for select using (can_access_vacancy(id));
create policy vac_insert on vacancies for insert with check (
  org_role_of(org_id) in ('owner','admin','hr_lead','recruiter')
);
create policy vac_update on vacancies for update using (is_vacancy_hr(id)) with check (is_vacancy_hr(id));
create policy vac_delete on vacancies for delete using (is_org_manager(org_id));

-- vacancy_members
create policy vm_select on vacancy_members for select using (can_access_vacancy(vacancy_id));
create policy vm_write on vacancy_members for all
  using (is_vacancy_hr(vacancy_id)) with check (is_vacancy_hr(vacancy_id));

-- pipelines / stages
create policy pl_select on pipelines for select using (can_access_vacancy(vacancy_id));
create policy pl_write on pipelines for all using (is_vacancy_hr(vacancy_id)) with check (is_vacancy_hr(vacancy_id));
create policy ps_select on pipeline_stages for select using (is_member(org_id));
create policy ps_write on pipeline_stages for all using (is_org_manager(org_id)) with check (is_org_manager(org_id));

-- candidates: HR видит кандидатов своих вакансий; менеджер — всех
create policy cand_select on candidates for select using (
  is_org_manager(org_id)
  or exists (select 1 from applications a
             where a.candidate_id = candidates.id and can_access_vacancy(a.vacancy_id))
  or created_by = auth.uid()
);
create policy cand_insert on candidates for insert with check (
  org_role_of(org_id) in ('owner','admin','hr_lead','recruiter')
);
create policy cand_update on candidates for update using (
  is_org_manager(org_id)
  or exists (select 1 from applications a
             where a.candidate_id = candidates.id and is_vacancy_hr(a.vacancy_id))
) with check (
  is_org_manager(org_id)
  or exists (select 1 from applications a
             where a.candidate_id = candidates.id and is_vacancy_hr(a.vacancy_id))
);

-- applications: читать — все участники вакансии; менять — только через функции/HR
create policy app_select on applications for select using (can_access_vacancy(vacancy_id));
create policy app_insert on applications for insert with check (is_vacancy_hr(vacancy_id));
create policy app_update on applications for update using (is_vacancy_hr(vacancy_id)) with check (is_vacancy_hr(vacancy_id));
create policy app_delete on applications for delete using (is_org_manager(org_id));

-- application_events: чтение по доступу; запись только через функции; без UPDATE/DELETE
create policy ev_select on application_events for select using (can_access_vacancy(app_vacancy(application_id)));

-- notes: hr_only — только HR вакансии; team — все участники вакансии
create policy notes_select on notes for select using (
  is_vacancy_hr(app_vacancy(application_id))
  or (visibility = 'team' and can_access_vacancy(app_vacancy(application_id)))
);
create policy notes_insert on notes for insert with check (
  author_id = auth.uid() and can_access_vacancy(app_vacancy(application_id))
  and (visibility = 'team' or is_vacancy_hr(app_vacancy(application_id)))
);
create policy notes_update on notes for update using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy notes_delete on notes for delete using (author_id = auth.uid() or is_org_manager(org_id));

-- audit_log: читают админы
create policy audit_select on audit_log for select using (org_role_of(org_id) in ('owner','admin'));

-- tasks
create policy tasks_select on tasks for select using (
  assignee_id = auth.uid() or created_by = auth.uid()
  or is_org_manager(org_id)
  or (application_id is not null and is_vacancy_hr(app_vacancy(application_id)))
);
create policy tasks_insert on tasks for insert with check (
  is_member(org_id) and created_by = auth.uid()
);
create policy tasks_update on tasks for update using (
  assignee_id = auth.uid() or created_by = auth.uid() or is_org_manager(org_id)
) with check (is_member(org_id));
create policy tasks_delete on tasks for delete using (created_by = auth.uid() or is_org_manager(org_id));

-- files
create policy files_select on files for select using (
  is_org_manager(org_id)
  or (application_id is not null and can_access_vacancy(app_vacancy(application_id)))
);
create policy files_insert on files for insert with check (
  uploaded_by = auth.uid()
  and (application_id is null or is_vacancy_hr(app_vacancy(application_id)))
  and is_member(org_id)
);
create policy files_delete on files for delete using (uploaded_by = auth.uid() or is_org_manager(org_id));

-- notifications: только свои
create policy notif_select on notifications for select using (user_id = auth.uid());
create policy notif_update on notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- чат
create or replace function in_conversation(p_conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_members where conversation_id = p_conv and user_id = auth.uid());
$$;

create policy conv_select on conversations for select using (in_conversation(id));
create policy convm_select on conversation_members for select using (in_conversation(conversation_id));
create policy msg_select on messages for select using (in_conversation(conversation_id));
create policy msg_insert on messages for insert with check (
  author_id = auth.uid() and in_conversation(conversation_id)
);

-- =========================================================
-- 10. ПРЕДСТАВЛЕНИЕ КАНДИДАТОВ С УЧЁТОМ ОГРАНИЧЕНИЯ КОНТАКТОВ
--     (используется клиентом вместо прямого чтения таблицы)
-- =========================================================
create or replace function can_see_contacts(p_candidate uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from candidates c
    where c.id = p_candidate
      and (
        is_org_manager(c.org_id)
        or org_role_of(c.org_id) = 'recruiter'
        or (
          coalesce((select (settings->>'interviewer_sees_contacts')::boolean
                    from organizations o where o.id = c.org_id), false)
          and exists (select 1 from applications a where a.candidate_id = c.id and can_access_vacancy(a.vacancy_id))
        )
        or (
          -- нанимающий руководитель вакансии контакты видит всегда
          exists (select 1 from applications a
                  where a.candidate_id = c.id and vacancy_role_of(a.vacancy_id) = 'hiring_manager')
        )
      )
  );
$$;

-- =========================================================
-- 10b. VIEW КАНДИДАТОВ И ПРАВА НА КОЛОНКИ
--      Контакты (phone, email) недоступны напрямую из таблицы:
--      читаются только через candidates_safe, где действует can_see_contacts().
-- =========================================================
create or replace function can_see_candidate(p_candidate uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from candidates c
    where c.id = p_candidate
      and (
        is_org_manager(c.org_id)
        or c.created_by = auth.uid()
        or exists (select 1 from applications a
                   where a.candidate_id = c.id and can_access_vacancy(a.vacancy_id))
      )
  );
$$;

-- view выполняется от владельца (обходит RLS), строки фильтруются явно
create or replace view candidates_safe as
select
  c.id, c.org_id, c.full_name, c.source_id, c.external_ids, c.consent_at,
  c.created_at, c.updated_at,
  case when can_see_contacts(c.id) then c.phone end as phone,
  case when can_see_contacts(c.id) then c.email end as email
from candidates c
where can_see_candidate(c.id);

revoke select on candidates from authenticated, anon;
grant select (id, org_id, full_name, source_id, external_ids, consent_at,
              created_by, created_at, updated_at) on candidates to authenticated;
grant select on candidates_safe to authenticated;
-- Запись phone/email выполняется через INSERT/UPDATE (политики выше);
-- чтение контактов клиент делает только из candidates_safe.

-- =========================================================
-- 11. ФУНКЦИЯ ПЕРЕМЕЩЕНИЯ ПО ЭТАПАМ
-- =========================================================
create or replace function move_application(
  p_application uuid,
  p_to_stage uuid,
  p_rejection_reason uuid default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_app applications%rowtype;
  v_stage pipeline_stages%rowtype;
begin
  select * into v_app from applications where id = p_application for update;
  if not found then raise exception 'application not found'; end if;
  if not is_vacancy_hr(v_app.vacancy_id) then raise exception 'forbidden'; end if;

  select * into v_stage from pipeline_stages where id = p_to_stage;
  if not found or v_stage.org_id <> v_app.org_id then raise exception 'invalid stage'; end if;
  if not exists (select 1 from pipelines p where p.id = v_stage.pipeline_id and p.vacancy_id = v_app.vacancy_id)
    then raise exception 'stage does not belong to vacancy pipeline'; end if;
  if v_stage.kind = 'rejected' and p_rejection_reason is null
    then raise exception 'rejection reason required'; end if;

  update applications
     set stage_id = p_to_stage,
         stage_entered_at = now(),
         rejection_reason_id = case when v_stage.kind = 'rejected' then p_rejection_reason else null end,
         updated_at = now()
   where id = p_application;

  insert into application_events (org_id, application_id, actor_id, type, from_stage_id, to_stage_id, payload)
  values (v_app.org_id, p_application, auth.uid(),
          case when v_stage.kind = 'rejected' then 'rejected' else 'stage_changed' end,
          v_app.stage_id, p_to_stage,
          jsonb_build_object('rejection_reason_id', p_rejection_reason));
end;
$$;

-- Прямое изменение этапа в обход функции запрещено триггером
create or replace function guard_stage_change() returns trigger
language plpgsql as $$
begin
  if new.stage_id is distinct from old.stage_id
     and coalesce(current_setting('app.moving', true), '') <> 'on'
     and current_user not in ('postgres','service_role','supabase_admin') then
    -- security definer функция выполняется от владельца, поэтому current_user = владелец
    raise exception 'use move_application()';
  end if;
  return new;
end;
$$;
create trigger trg_guard_stage before update on applications
  for each row execute function guard_stage_change();

-- Запись события о создании отклика
create or replace function log_application_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into application_events (org_id, application_id, actor_id, type, to_stage_id)
  values (new.org_id, new.id, auth.uid(), 'created', new.stage_id);
  return new;
end;
$$;
create trigger trg_app_created after insert on applications
  for each row execute function log_application_created();

-- updated_at
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
create trigger trg_vac_touch before update on vacancies for each row execute function touch_updated_at();
create trigger trg_cand_touch before update on candidates for each row execute function touch_updated_at();
create trigger trg_app_touch before update on applications for each row execute function touch_updated_at();
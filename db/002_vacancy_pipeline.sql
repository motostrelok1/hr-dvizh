-- HR Движ! / этап 1A: автосоздание воронки вакансии
-- Выполнить после 001_core_schema.sql.
-- Безопасно повторять: триггер пересоздаётся.
create or replace function public.init_vacancy_pipeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pipeline uuid;
begin
  insert into public.pipelines(org_id,vacancy_id)
  values (new.org_id,new.id)
  returning id into v_pipeline;

  insert into public.pipeline_stages(org_id,pipeline_id,name,position,kind,sla_hours)
  values
    (new.org_id,v_pipeline,'Новые',0,'normal',48),
    (new.org_id,v_pipeline,'Скрининг',1,'normal',48),
    (new.org_id,v_pipeline,'Интервью',2,'normal',72),
    (new.org_id,v_pipeline,'Оффер',3,'normal',72),
    (new.org_id,v_pipeline,'Нанят',4,'hired',null),
    (new.org_id,v_pipeline,'Отказ',5,'rejected',null),
    (new.org_id,v_pipeline,'Резерв',6,'reserve',null);
  return new;
end;
$$;

drop trigger if exists trg_vacancy_pipeline on public.vacancies;
create trigger trg_vacancy_pipeline
after insert on public.vacancies
for each row execute function public.init_vacancy_pipeline();

-- Backfill для вакансий, которые существовали до 002.
do $$
declare v record; v_pipeline uuid;
begin
  for v in select id,org_id from public.vacancies
    where not exists (select 1 from public.pipelines p where p.vacancy_id=vacancies.id)
  loop
    insert into public.pipelines(org_id,vacancy_id)
      values(v.org_id,v.id) returning id into v_pipeline;
    insert into public.pipeline_stages(org_id,pipeline_id,name,position,kind,sla_hours)
    values
      (v.org_id,v_pipeline,'Новые',0,'normal',48),
      (v.org_id,v_pipeline,'Скрининг',1,'normal',48),
      (v.org_id,v_pipeline,'Интервью',2,'normal',72),
      (v.org_id,v_pipeline,'Оффер',3,'normal',72),
      (v.org_id,v_pipeline,'Нанят',4,'hired',null),
      (v.org_id,v_pipeline,'Отказ',5,'rejected',null),
      (v.org_id,v_pipeline,'Резерв',6,'reserve',null);
  end loop;
end;
$$;

-- Права выполнения: функции, изменяющие данные, доступны только залогиненным.
revoke all on function public.init_vacancy_pipeline() from public, anon, authenticated;

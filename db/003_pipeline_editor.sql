-- 003: customizable vacancy pipeline, preserving historical stage references.
alter table public.pipeline_stages add column if not exists is_archived boolean not null default false;

create or replace function public.configure_pipeline_stage(
  p_vacancy uuid,
  p_action text,
  p_stage uuid default null,
  p_name text default null,
  p_kind public.stage_kind default 'normal',
  p_sla_hours integer default null,
  p_direction integer default 0
) returns void
language plpgsql security definer set search_path=public
as $$
declare
  v_pipeline uuid;
  v_position integer;
  v_old integer;
  v_neighbor uuid;
  v_stage public.pipeline_stages%rowtype;
begin
  if auth.uid() is null or not public.is_vacancy_hr(p_vacancy)
    then raise exception 'not authorized to configure this vacancy'; end if;
  select id into v_pipeline from public.pipelines where vacancy_id=p_vacancy for update;
  if v_pipeline is null then raise exception 'pipeline not found'; end if;
  if p_action in ('create','update') then
    if length(trim(coalesce(p_name,''))) not between 1 and 80 then raise exception 'invalid stage name'; end if;
    if p_sla_hours is not null and (p_sla_hours < 1 or p_sla_hours > 8760)
      then raise exception 'SLA must be from 1 to 8760 hours'; end if;
  end if;
  if p_action='create' then
    select coalesce(max(position),-1)+1 into v_position from public.pipeline_stages where pipeline_id=v_pipeline;
    insert into public.pipeline_stages (org_id,pipeline_id,name,position,kind,sla_hours)
    select org_id,v_pipeline,trim(p_name),v_position,p_kind,p_sla_hours
      from public.vacancies where id=p_vacancy;
  elsif p_action in ('update','archive','up','down') then
    select * into v_stage from public.pipeline_stages
     where id=p_stage and pipeline_id=v_pipeline for update;
    if not found then raise exception 'stage does not belong to this vacancy'; end if;
    if p_action='update' then
      if v_stage.is_archived then raise exception 'archived stage cannot be edited'; end if;
      update public.pipeline_stages
        set name=trim(p_name),kind=p_kind,sla_hours=p_sla_hours where id=p_stage;
    elsif p_action='archive' then
      if v_stage.is_archived then raise exception 'already archived'; end if;
      if exists(select 1 from public.applications where stage_id=p_stage)
        then raise exception 'move all candidates from this stage before archiving'; end if;
      if (select count(*) from public.pipeline_stages where pipeline_id=v_pipeline and not is_archived) <= 1
        then raise exception 'cannot archive the last stage'; end if;
      update public.pipeline_stages set is_archived=true where id=p_stage;
    else
      select id,position into v_neighbor,v_position from public.pipeline_stages
        where pipeline_id=v_pipeline and not is_archived
        and (case when p_action='up' then position<v_stage.position else position>v_stage.position end)
        order by case when p_action='up' then -position else position end
        limit 1 for update;
      if v_neighbor is not null then
        -- Position uniqueness is DEFERRABLE INITIALLY DEFERRED (migration 001).
        update public.pipeline_stages set position=v_position where id=p_stage;
        update public.pipeline_stages set position=v_stage.position where id=v_neighbor;
      end if;
    end if;
  else
    raise exception 'unknown stage action';
  end if;
end;
$$;
revoke all on function public.configure_pipeline_stage(uuid,text,uuid,text,public.stage_kind,integer,integer) from public,anon;
grant execute on function public.configure_pipeline_stage(uuid,text,uuid,text,public.stage_kind,integer,integer) to authenticated;

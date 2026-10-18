(function(){
function api(){return window.hrPipelineApi}
async function change(action,stage,values={}){
 const {state,vacancy,stagesFor,persist,uid}=api(),v=vacancy(state.vacancy),p=state.data.pipelines.find(x=>x.vacancy_id===v.id);
 if(state.mode==='demo'){
   if(action==='create')state.data.stages.push({id:uid(),org_id:v.org_id,pipeline_id:p.id,is_archived:false,position:Math.max(-1,...state.data.stages.filter(x=>x.pipeline_id===p.id).map(x=>x.position))+1,...values});
   if(action==='update')Object.assign(stage,values);
   if(action==='archive'){if(stagesFor(v.id).length<=1)throw Error('Последний этап нельзя удалить');stage.is_archived=true}
   if(action==='up'||action==='down'){const a=stagesFor(v.id),n=a[a.findIndex(x=>x.id===stage.id)+(action==='up'?-1:1)];if(n){const pos=n.position;n.position=stage.position;stage.position=pos}}
   persist();return;
 }
 const r=await state.client.rpc('configure_pipeline_stage',{p_vacancy:v.id,p_action:action,p_stage:stage?.id||null,p_name:values.name||null,p_kind:values.kind||'normal',p_sla_hours:values.sla_hours??null});
 if(r.error)throw r.error;
}
function editForm(stage){
 const {dialog,field,opt,refresh,toast}=api();
 const d=dialog(stage?'Настроить этап':'Новый этап',
 field('name','Название этапа','text',stage?.name||'','required maxlength="80"')+
 opt('kind','Тип',[['normal','Обычный'],['hired','Нанят'],['rejected','Отказ'],['reserve','Резерв']],stage?.kind||'normal')+
 field('sla_hours','Срок SLA, часов (пусто — отключён)','number',stage?.sla_hours||'','min="1" max="8760"'),'Сохранить');
 d.querySelector('form').onsubmit=async e=>{e.preventDefault();const v=Object.fromEntries(new FormData(e.target));try{await change(stage?'update':'create',stage,{name:v.name.trim(),kind:v.kind,sla_hours:v.sla_hours?Number(v.sla_hours):null});d.close();await refresh();open();toast('Этап сохранён')}catch(err){toast(err.message)}};
}
function open(){
 const {state,vacancy,stagesFor,dialog,esc,refresh,toast}=api(),v=vacancy(state.vacancy),ss=stagesFor(v.id);
 const html='<p class="muted full">Добавляйте этапы, меняйте их порядок, назначение и SLA. При удалении этап архивируется: история кандидатов остаётся.</p><div class="stage-settings full">'+ss.map((s,i)=>'<div class="stage-setting"><div><b>'+esc(s.name)+'</b> <span class="tag">'+esc(s.kind)+'</span><div class="muted">SLA: '+(s.sla_hours?s.sla_hours+' ч':'выключен')+'</div></div><div class="actions"><button type="button" class="btn alt small" data-op="up" data-id="'+s.id+'" '+(i===0?'disabled':'')+'>↑</button><button type="button" class="btn alt small" data-op="down" data-id="'+s.id+'" '+(i===ss.length-1?'disabled':'')+'>↓</button><button type="button" class="btn alt small" data-op="edit" data-id="'+s.id+'">Изменить</button><button type="button" class="btn danger small" data-op="archive" data-id="'+s.id+'">Убрать</button></div></div>').join('')+'</div><button id="stageAdd" type="button" class="btn lime full">+ Добавить этап</button>';
 const d=dialog('Этапы · '+esc(v.title),html,'Закрыть');
 d.querySelector('form').onsubmit=e=>{e.preventDefault();d.close()};
 d.querySelector('#stageAdd').onclick=()=>{d.close();editForm(null)};
 d.querySelectorAll('[data-op]').forEach(b=>b.onclick=async()=>{
 const s=ss.find(x=>x.id===b.dataset.id),op=b.dataset.op;
 if(op==='edit'){d.close();editForm(s);return}
 if(op==='archive'){if(state.data.applications.some(a=>a.stage_id===s.id)){toast('Сначала перенесите всех кандидатов с этапа');return}if(!confirm('Убрать этап «'+s.name+'»? История сохранится.'))return}
 try{await change(op,s);d.close();await refresh();open()}catch(err){toast(err.message)}
 });
}
window.openPipelineEditor=open;
})();
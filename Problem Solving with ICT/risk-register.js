'use strict';
(() => {
  const rows = [
    {id:1,description:'Само Мария публикува сайта; при отсъствие обновяването може да се забави с два дни.',p:3,i:3,owner:'Елена',action:'Мария обучава Петър и той прави пробно публикуване до края на седмица 1.',review:'',status:'Наблюдава се'},
    {id:2,description:'Графикът зависи от външно потвърждение; то може да закъснее и да отложи старта с три дни.',p:4,i:4,owner:'Петър',action:'Петър иска потвърждение от учителя до сряда на седмица 1.',review:'',status:'Мярка в изпълнение'},
    {id:3,description:'Общият компютър може да е зает; тестът на сайта може да се забави с няколко часа.',p:2,i:1,owner:'Мария',action:'Елена съгласува предварително час за използване на компютъра.',review:'',status:'Наблюдава се'}
  ];
  let nextId = 4;
  const tbody = document.getElementById('risk-rows');
  const filter = document.getElementById('priority-filter');
  const sort = document.getElementById('sort-order');
  const summary = document.getElementById('register-summary');
  const statuses = ['Наблюдава се','Мярка в изпълнение','Настъпил','Закрит'];
  const level = score => score >= 10 ? 'high' : score >= 5 ? 'medium' : 'low';
  const names = {high:'Висок',medium:'Среден',low:'Нисък'};
  const active = r => r.status !== 'Закрит' && r.status !== 'Настъпил';
  function updateSummary() {
    summary.textContent = `Записи: ${rows.length}. Активни заплахи с висок приоритет: ${rows.filter(r => active(r) && level(r.p*r.i)==='high').length}. Видими записи: ${tbody.children.length}.`;
  }
  function field(row, key, label, options) {
    const el = document.createElement(options ? 'select' : key === 'description' || key === 'action' ? 'textarea' : 'input');
    el.setAttribute('aria-label', `${label}, риск ${row.id}`);
    el.dataset.key = key;
    if (options) for (const value of options) {
      const opt = document.createElement('option'); opt.value = value; opt.textContent = value; el.append(opt);
    }
    else if (key === 'review') el.type = 'date';
    else if (el.tagName === 'INPUT') el.type = 'text';
    el.value = row[key];
    if (el.tagName === 'TEXTAREA') {el.rows=3; el.style.minWidth='240px';}
    else if (key === 'owner') el.style.minWidth='130px';
    el.addEventListener('input', () => {
      row[key] = key === 'p' || key === 'i' ? Number(el.value) : el.value;
      const tr = el.closest('tr');
      const score = row.p * row.i;
      const cell = tr.querySelector('[data-score]');
      cell.textContent = `${score} — ${names[level(score)]}`;
      cell.className = `risk-${level(score)}`;
      updateSummary();
    });
    // Re-render after selection changes to apply current sorting and filtering.
    if (options) el.addEventListener('change', () => {
      const id=row.id; render();
      const target=tbody.querySelector(`tr[data-id="${id}"] [data-key="${key}"]`);
      if (target) target.focus(); else filter.focus();
    });
    return el;
  }
  function render() {
    tbody.replaceChildren();
    const visible=rows.filter(r => filter.value==='all' || level(r.p*r.i)===filter.value);
    visible.sort((a,b) => sort.value==='score' ? b.p*b.i-a.p*a.i || a.id-b.id : a.id-b.id);
    for (const row of visible) {
      const tr=document.createElement('tr'); tr.dataset.id=row.id;
      const add=child => {const td=document.createElement('td'); if(typeof child==='string')td.textContent=child;else td.append(child);tr.append(td);return td;};
      add(`R${String(row.id).padStart(2,'0')}`);
      add(field(row,'description','Описание'));
      add(field(row,'p','Вероятност',[1,2,3,4,5]));
      add(field(row,'i','Влияние',[1,2,3,4,5]));
      const score=row.p*row.i, cell=add(`${score} — ${names[level(score)]}`);
      cell.dataset.score='';cell.className=`risk-${level(score)}`;
      add(field(row,'owner','Отговорник'));
      add(field(row,'action','Мярка и изпълнител'));
      add(field(row,'review','Дата за преглед'));
      add(field(row,'status','Статус',statuses));
      const remove=document.createElement('button'); remove.type='button';remove.textContent='Премахни';remove.setAttribute('aria-label',`Премахни риск ${row.id}`);
      remove.addEventListener('click',()=>{rows.splice(rows.indexOf(row),1);render();document.getElementById('add-risk').focus();});add(remove);
      tbody.append(tr);
    }
    updateSummary();
  }
  filter.addEventListener('change',render);sort.addEventListener('change',render);
  document.getElementById('add-risk').addEventListener('click',()=>{
    const row={id:nextId++,description:'',p:1,i:1,owner:'',action:'',review:'',status:'Наблюдава се'};
    rows.push(row);filter.value='all';render();
    tbody.querySelector(`tr[data-id="${row.id}"] textarea`).focus();
  });
  function csvCell(value) {
    let text=String(value);
    // Keep user text from being interpreted as a spreadsheet formula.
    if (/^[\s]*[=+@-]/.test(text)) text="'"+text;
    return '"'+text.replace(/"/g,'""')+'"';
  }
  document.getElementById('export-csv').addEventListener('click',()=>{
    const header=['№','Риск','Вероятност','Влияние','Оценка','Приоритет','Отговорник','Мярка и изпълнител','Дата за преглед','Статус'];
    const data=rows.map(r=>[r.id,r.description,r.p,r.i,r.p*r.i,names[level(r.p*r.i)],r.owner,r.action,r.review,r.status]);
    const csv='\uFEFF'+[header,...data].map(r=>r.map(csvCell).join(';')).join('\r\n')+'\r\n';
    const url=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8;'}));
    const link=document.createElement('a');link.href=url;link.download='13_Risk_Register.csv';document.body.append(link);link.click();link.remove();
    setTimeout(()=>URL.revokeObjectURL(url),1000);
  });
  render();
})();

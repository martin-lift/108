(() => {
  'use strict';
  const root = document.getElementById('input-events-demo');
  if (!root) return;
  const find = id => root.querySelector('#' + id);
  const keyboard = find('demo-keyboard');
  const zone = find('demo-mouse-zone');
  if (!keyboard && !zone) return;
  const dot = find('demo-mouse-dot');
  const log = find('demo-log');
  const pause = find('demo-pause');
  const clear = find('demo-clear');
  const status = find('demo-status');
  const count = find('demo-count');
  const recordMovement = find('demo-record-movement');
  const holdScroll = find('demo-hold-scroll');
  const limit = 120;
  const runningStatus = keyboard && zone ? 'Записът е включен — работи в тестовите полета.'
    : keyboard ? 'Записът е включен — пиши в полето за клавиатура.'
    : 'Записът е включен — използвай зоната за мишка и скрол.';
  let paused = false;
  let total = 0;
  let started = performance.now();
  let lastMovement = -Infinity;
  const set = (id, value) => { find(id).textContent = String(value); };
  const quoted = value => JSON.stringify(value == null ? null : value);
  const unicode = value => value && Array.from(value).length === 1
    ? 'U+' + value.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
    : '— (не е единичен символ)';
  const modifiers = event => ['Shift', 'Control', 'Alt', 'Meta', 'CapsLock']
    .filter(name => event.getModifierState && event.getModifierState(name)).join(', ') || 'няма';
  const showCount = () => { count.textContent = `Показани: ${log.children.length} от ${total} записа`; };
  function add(event, details) {
    if (paused) return;
    total += 1;
    const row = document.createElement('li');
    const heading = document.createElement('strong');
    heading.textContent = `#${total} · +${(performance.now() - started).toFixed(1)} ms · ${event.type}`;
    const data = document.createElement('code');
    data.textContent = details;
    row.append(heading, data);
    // Keep the row being read in place if a student has scrolled into the log.
    const previousTop = log.scrollTop;
    const previousHeight = log.scrollHeight;
    log.prepend(row);
    if (log.children.length > limit) log.lastElementChild.remove();
    if (previousTop > 0) log.scrollTop = previousTop + log.scrollHeight - previousHeight;
    showCount();
  }
  function keyboardEvent(event) {
    if (paused) return;
    set('demo-key-event', event.type);
    set('demo-key', quoted(event.key));
    set('demo-code', event.code || '— (не е предоставен)');
    set('demo-unicode', unicode(event.key));
    const locations = ['стандартен', 'ляв', 'десен', 'цифров блок'];
    set('demo-location', `${event.location} (${locations[event.location] || 'друг'})`);
    set('demo-repeat', String(event.repeat));
    set('demo-modifiers', modifiers(event));
    add(event, `key=${quoted(event.key)}; code=${quoted(event.code)}; ${unicode(event.key)}; location=${event.location}; repeat=${event.repeat}; modifiers=${modifiers(event)}; isComposing=${event.isComposing}`);
  }
  if (keyboard) {
    keyboard.addEventListener('keydown', keyboardEvent);
    keyboard.addEventListener('keyup', keyboardEvent);
    for (const type of ['beforeinput', 'input']) {
      keyboard.addEventListener(type, event => {
        if (paused) return;
        set('demo-text-event', `${event.type}: data=${quoted(event.data)}, inputType=${event.inputType || '—'}`);
        add(event, `data=${quoted(event.data)}; inputType=${quoted(event.inputType)}; isComposing=${event.isComposing}`);
      });
    }
    for (const type of ['compositionstart', 'compositionupdate', 'compositionend']) {
      keyboard.addEventListener(type, event => add(event, `data=${quoted(event.data)}`));
    }
  }
  function mouseEvent(event) {
    if (paused) return;
    const box = zone.getBoundingClientRect();
    const x = Math.round(event.clientX - box.left - zone.clientLeft);
    const y = Math.round(event.clientY - box.top - zone.clientTop);
    set('demo-mouse-event', event.type);
    set('demo-position', `x=${x}, y=${y}`);
    set('demo-client-position', `clientX=${event.clientX}, clientY=${event.clientY}`);
    set('demo-buttons', `${event.buttons} (0b${event.buttons.toString(2).padStart(5, '0')})`);
    set('demo-button', event.type === 'mousemove' ? '— (виж buttons)' : event.button);
    set('demo-mouse-modifiers', modifiers(event));
    dot.style.display = 'block';
    dot.style.left = Math.max(0, Math.min(zone.clientWidth, x)) + 'px';
    dot.style.top = Math.max(0, Math.min(zone.clientHeight, y)) + 'px';
    if (event.type === 'mousemove') {
      if (!recordMovement.checked || performance.now() - lastMovement < 100) return;
      lastMovement = performance.now();
    }
    add(event, `clientX=${event.clientX}; clientY=${event.clientY}; zoneX=${x}; zoneY=${y}; button=${event.button}; buttons=${event.buttons}; modifiers=${modifiers(event)}`);
  }
  if (zone) {
    // Capture keeps a drag's final release visible even if it occurs outside the zone.
    zone.addEventListener('pointerdown', event => {
      if (event.pointerType === 'mouse') zone.setPointerCapture(event.pointerId);
    });
    zone.addEventListener('mousedown', event => {
      zone.focus({ preventScroll: true });
      if (event.button === 1) event.preventDefault(); // Avoid middle-button auto-scroll in this exercise.
    });
    for (const type of ['mousemove', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu']) {
      zone.addEventListener(type, mouseEvent);
    }
    zone.addEventListener('contextmenu', event => event.preventDefault());
    zone.addEventListener('wheel', event => {
      if (holdScroll.checked) event.preventDefault();
      if (paused) return;
      const units = ['пиксели', 'редове', 'страници'];
      const unit = units[event.deltaMode] || 'други единици';
      set('demo-mouse-event', 'wheel');
      set('demo-wheel', `deltaX=${event.deltaX}; deltaY=${event.deltaY}; deltaZ=${event.deltaZ}; deltaMode=${event.deltaMode} (${unit})`);
      set('demo-mouse-modifiers', modifiers(event));
      add(event, `deltaX=${event.deltaX}; deltaY=${event.deltaY}; deltaZ=${event.deltaZ}; deltaMode=${event.deltaMode} (${unit}); modifiers=${modifiers(event)}`);
    }, { passive: false });
  }
  pause.addEventListener('click', () => {
    paused = !paused;
    pause.setAttribute('aria-pressed', String(paused));
    pause.textContent = paused ? 'Продължи записа' : 'Пауза';
    status.textContent = paused ? 'Пауза — показанията и дневникът са замразени.' : runningStatus;
  });
  clear.addEventListener('click', () => {
    log.replaceChildren();
    total = 0;
    started = performance.now();
    lastMovement = -Infinity;
    showCount();
    status.textContent = paused ? 'Дневникът е изчистен. Записът остава на пауза.' : 'Дневникът е изчистен. Записът е включен.';
  });
  pause.disabled = false;
  clear.disabled = false;
  showCount();
  status.textContent = runningStatus;
})();

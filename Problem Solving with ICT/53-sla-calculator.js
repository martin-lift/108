'use strict';
function calculateSLA(days, target, downtime) {
  if (![days, target, downtime].every(Number.isFinite) || !Number.isInteger(days)
      || days < 1 || days > 366 || target < 0 || target > 100 || downtime < 0) {
    throw new Error('Въведете цял брой дни от 1 до 366, процент от 0 до 100 и неотрицателни минути.');
  }
  const period = days * 24 * 60;
  if (downtime > period) throw new Error('Недостъпността не може да надхвърля целия период.');
  const allowance = period * (1 - target / 100);
  const availability = 100 * (period - downtime) / period;
  return { period, allowance, availability, met: downtime <= allowance + 1e-9 };
}
if (typeof document !== 'undefined') {
  const form = document.getElementById('sla-form');
  const output = document.getElementById('sla-result');
  const fmt = (value, digits) => new Intl.NumberFormat('bg-BG', {
    minimumFractionDigits: digits, maximumFractionDigits: digits
  }).format(value);
  form.addEventListener('input', () => {
    output.textContent = 'Данните са променени. Натиснете „Изчисли SLA“ за актуален резултат.';
  });
  form.addEventListener('submit', event => {
    event.preventDefault();
    try {
      const fields = ['sla-days', 'sla-target', 'sla-downtime'].map(id => document.getElementById(id));
      if (fields.some(field => field.value.trim() === '')) throw new Error('Попълнете всички полета.');
      const result = calculateSLA(...fields.map(field => field.valueAsNumber));
      output.textContent = `Период: ${fmt(result.period, 0)} минути. `
        + `Допустима недостъпност: ${fmt(result.allowance, 2)} минути. `
        + `Измерена достъпност: ${fmt(result.availability, 5)}%. `
        + (result.met ? 'Целта е изпълнена.' : 'Целта не е изпълнена.');
    } catch (error) { output.textContent = error.message; }
  });
}
if (typeof module !== 'undefined' && module.exports) module.exports = { calculateSLA };

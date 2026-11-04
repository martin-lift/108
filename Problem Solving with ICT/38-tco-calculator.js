'use strict';

// Pure calculation also allows independent verification of the lesson examples.
function calculateTCO(values) {
  const keys = ['purchase', 'license', 'support', 'watts', 'hours', 'days', 'rate'];
  if (keys.some(key => !Number.isFinite(values[key]) || values[key] < 0)
      || values.hours > 24 || values.days > 366 || !Number.isInteger(values.days)) {
    throw new Error('Въведете неотрицателни числа, до 24 часа на ден и цял брой дни от 0 до 366.');
  }
  const annualEnergy = values.watts / 1000 * values.hours * values.days;
  const energyCost = annualEnergy * values.rate * 3;
  const supportCost = values.support * 3;
  const total = values.purchase + values.license + supportCost + energyCost;
  if (![annualEnergy, energyCost, supportCost, total].every(Number.isFinite)) {
    throw new Error('Стойностите са твърде големи. Проверете входните данни.');
  }
  return { annualEnergy, energyCost, supportCost, total };
}

if (typeof document !== 'undefined') {
  const form = document.getElementById('tco-form');
  const output = document.getElementById('tco-result');
  const format = value => new Intl.NumberFormat('bg-BG', {
    minimumFractionDigits: 2, maximumFractionDigits: 2
  }).format(value);
  form.addEventListener('input', () => {
    output.textContent = 'Данните са променени. Натиснете „Изчисли за 3 години“ за актуален резултат.';
  });
  form.addEventListener('submit', event => {
    event.preventDefault();
    try {
      const values = {};
      for (const field of form.querySelectorAll('input')) {
        if (field.value.trim() === '') throw new Error('Попълнете всички полета.');
        values[field.name] = field.valueAsNumber;
      }
      const result = calculateTCO(values);
      output.textContent = `Енергия за година: ${format(result.annualEnergy)} kWh. `
        + `Енергия за 3 години: ${format(result.energyCost)} у.е. `
        + `Поддръжка за 3 години: ${format(result.supportCost)} у.е. `
        + `Общ TCO за 3 години: ${format(result.total)} у.е.`;
    } catch (error) {
      output.textContent = error.message;
    }
  });
}

if (typeof module !== 'undefined' && module.exports) module.exports = { calculateTCO };

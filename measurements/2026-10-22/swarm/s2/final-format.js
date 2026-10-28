const SYMBOLS = { EUR: '€', USD: '$' };

export function formatPrice(cents, currency) {
  const symbol = SYMBOLS[currency];
  if (!symbol) throw new TypeError(`formatPrice: unknown currency ${JSON.stringify(currency)}`);
  return symbol + (cents / 100).toFixed(2);
}

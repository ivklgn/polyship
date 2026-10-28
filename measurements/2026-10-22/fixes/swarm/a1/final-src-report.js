import { findUser } from './users.js';
import { formatPrice } from './format.js';

export function invoiceLine(db, userId, cents, currency) {
  const user = findUser(db, userId);
  return `${user.name}: ${formatPrice(cents, currency)}`;
}

export function userLabel(db, id) {
  const user = findUser(db, id);
  return `${user.name} <${user.email}>`;
}

export function orderTotal(items) {
  return formatPrice(items.reduce((sum, item) => sum + item.cents, 0), 'USD');
}

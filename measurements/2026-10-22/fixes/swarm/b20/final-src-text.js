export function titleCase(s) {
  return s.replace(/\b\w/g, (c) => c.toUpperCase());
}

export function slugify(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

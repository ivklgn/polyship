export function postPath(post) {
  const slug = String(post.title ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  return `/posts/${post.id}${slug && `-${slug}`}`;
}

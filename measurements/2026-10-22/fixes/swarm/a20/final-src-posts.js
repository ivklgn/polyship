export function postPath(post) {
  const slug = (post.title ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  return slug ? `/posts/${post.id}-${slug}` : `/posts/${post.id}`;
}

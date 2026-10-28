export function postPath(post) {
  const slug = post.title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  return `/posts/${post.id}-${slug}`;
}

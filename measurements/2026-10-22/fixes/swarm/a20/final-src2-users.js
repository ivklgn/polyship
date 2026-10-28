export function createUser(db, { name, email }) {
  if (!name?.trim()) throw new Error('name required');
  const user = { id: db.users.length + 1, name, email };
  db.users.push(user);
  return user;
}

export function findUser(db, id) {
  return db.users.find((u) => u.id === id) ?? null;
}

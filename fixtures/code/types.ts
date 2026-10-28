interface User { id: number; name: string }
export function find(users: User[], id: number): User | undefined {
  return users.find(u => u.id === id);
}

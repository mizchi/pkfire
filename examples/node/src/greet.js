export function greet(name) {
  if (typeof name !== "string" || name.length === 0) {
    throw new TypeError("name must be a non-empty string");
  }
  return `hello, ${name}`;
}

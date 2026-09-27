-- Fixture only. Proves the runner applies a migration file at all.
CREATE TABLE widgets (
  id INT NOT NULL PRIMARY KEY,
  name VARCHAR(64) NOT NULL
);

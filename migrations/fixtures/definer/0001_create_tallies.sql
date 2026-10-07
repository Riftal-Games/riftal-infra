-- Fixture only, standing in for riftal-game's gangs_ledger_contribute: a
-- procedure with MySQL's default SQL SECURITY DEFINER, writing a table no
-- login may UPDATE directly.
CREATE TABLE tallies (
  id INT NOT NULL PRIMARY KEY,
  n INT NOT NULL
);
INSERT INTO tallies (id, n) VALUES (1, 0);

DELIMITER $$
CREATE PROCEDURE tallies_bump()
BEGIN
  UPDATE tallies SET n = n + 1 WHERE id = 1;
END$$
DELIMITER ;

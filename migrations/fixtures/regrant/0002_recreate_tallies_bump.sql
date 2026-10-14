-- Fixture only, standing in for riftal-game's 0010 and 0015: dropping a
-- procedure to recreate it also drops every role's EXECUTE on it.
DROP PROCEDURE IF EXISTS tallies_bump;

DELIMITER $$
CREATE PROCEDURE tallies_bump()
BEGIN
  UPDATE tallies SET n = n + 1 WHERE id = 1;
END$$
DELIMITER ;

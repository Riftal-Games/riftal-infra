-- Fixture only. The SLEEP widens the window a second, unlocked invocation
-- would need to land in to read this file as still pending and apply it a
-- second time.
CREATE TABLE IF NOT EXISTS things (
  note VARCHAR(32) NOT NULL
);
SELECT SLEEP(3);
INSERT INTO things (note) VALUES ('mined');

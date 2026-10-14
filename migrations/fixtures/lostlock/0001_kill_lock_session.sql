-- Fixture only. Ends the runner's lock session from inside the run, the way a
-- dropped connection would, and otherwise succeeds. Each self-test run has its
-- own mysql container, so the fixed lock name cannot meet another run's.
SET @kill_lock_session = CONCAT('KILL ', IS_USED_LOCK('selftest-lost-lock'));
PREPARE kill_lock_session FROM @kill_lock_session;
EXECUTE kill_lock_session;
DEALLOCATE PREPARE kill_lock_session;

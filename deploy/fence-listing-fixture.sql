-- A commit-first procedure built to ADR 027 item 3, over a one-row table, for
-- the self-test that plays the plugin against backup.sh. It reads the fence
-- row FOR SHARE as the first statement after START TRANSACTION and touches
-- nothing else before its write. Loaded after fence-fixture.sql, which creates
-- capture_fence.
CREATE TABLE fixture_listing (
  id INT NOT NULL PRIMARY KEY,
  collected_by VARCHAR(64) NULL
);
INSERT INTO fixture_listing (id) VALUES (1);

DELIMITER $$
CREATE PROCEDURE fixture_listing_collect(
  IN p_id INT,
  IN p_by VARCHAR(64),
  OUT p_outcome VARCHAR(16)
)
BEGIN
  DECLARE v_open BOOLEAN DEFAULT FALSE;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  SELECT request_id IS NULL OR raised_until <= UTC_TIMESTAMP(3) INTO v_open
    FROM capture_fence WHERE id = 1 FOR SHARE;
  IF NOT v_open THEN
    ROLLBACK;
    SET p_outcome = 'capture_fenced';
  ELSE
    UPDATE fixture_listing SET collected_by = p_by WHERE id = p_id AND collected_by IS NULL;
    IF ROW_COUNT() = 0 THEN
      ROLLBACK;
      SET p_outcome = 'gone';
    ELSE
      COMMIT;
      SET p_outcome = 'collected';
    END IF;
  END IF;
END$$
DELIMITER ;

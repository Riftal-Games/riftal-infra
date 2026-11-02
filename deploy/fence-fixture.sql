-- The capture fence table, its seed row and its two control procedures, as
-- riftal-game's migration 0027 writes them (ADR 027 items 2 and 4). That repo
-- is private and this CI does not check it out, so the self-tests that run
-- backup.sh load this copy into a throwaway database.
CREATE TABLE capture_fence (
  id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  request_id VARCHAR(64) CHARACTER SET ascii NULL,
  raised_until DATETIME(3) NULL,
  CONSTRAINT capture_fence_one_row_chk CHECK (id = 1),
  CONSTRAINT capture_fence_pair_chk CHECK (
    (request_id IS NULL AND raised_until IS NULL)
    OR (request_id IS NOT NULL AND raised_until IS NOT NULL)
  )
);
INSERT INTO capture_fence (id) VALUES (1);

DELIMITER $$
CREATE PROCEDURE capture_fence_raise(
  IN p_request_id VARCHAR(64) CHARACTER SET ascii,
  IN p_seconds INT,
  OUT p_outcome VARCHAR(16)
)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_request_id IS NULL OR p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 3600 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'capture_fence_raise needs a request id and 1 to 3600 seconds';
  END IF;
  START TRANSACTION;
  UPDATE capture_fence SET request_id = p_request_id, raised_until = UTC_TIMESTAMP(3) + INTERVAL p_seconds SECOND
  WHERE id = 1 AND (request_id IS NULL OR raised_until <= UTC_TIMESTAMP(3));
  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    SET p_outcome = 'busy';
  ELSE
    COMMIT;
    SET p_outcome = 'raised';
  END IF;
END$$

CREATE PROCEDURE capture_fence_lower(
  IN p_request_id VARCHAR(64) CHARACTER SET ascii,
  OUT p_outcome VARCHAR(16)
)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  UPDATE capture_fence SET request_id = NULL, raised_until = NULL
  WHERE id = 1 AND request_id = p_request_id;
  IF ROW_COUNT() = 0 THEN
    ROLLBACK;
    SET p_outcome = 'not_held';
  ELSE
    COMMIT;
    SET p_outcome = 'lowered';
  END IF;
END$$
DELIMITER ;

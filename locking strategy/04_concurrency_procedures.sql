USE ticketing;
DELIMITER $$

-- ---------------------------------------------------------------------
-- 1. HOLD seats (pessimistic locking)
--    p_seat_ids is a JSON array, e.g. '[1,2,3]'.
--    All-or-nothing: either every requested seat is held, or none.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_hold_seats$$
CREATE PROCEDURE sp_hold_seats(
  IN  p_user_id      BIGINT UNSIGNED,
  IN  p_show_id      BIGINT UNSIGNED,
  IN  p_seat_ids     JSON,
  IN  p_hold_seconds INT,
  OUT p_booking_id   BIGINT UNSIGNED,
  OUT p_result       VARCHAR(20))
proc: BEGIN
  DECLARE v_requested INT;
  DECLARE v_claimable INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN ROLLBACK; SET p_booking_id = NULL; SET p_result = 'RETRY'; END;  -- e.g. deadlock 1213

  SET p_booking_id = NULL;
  SELECT COUNT(*) INTO v_requested
  FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j;

  START TRANSACTION;

  -- Lock the requested rows in seat_id order (consistent order => no lock cycles between
  -- two buyers with overlapping seats). A seat is claimable if AVAILABLE, or HELD with an
  -- already-expired hold. Only show_seat rows are locked (FOR UPDATE OF ss).
  SELECT COUNT(*) INTO v_claimable FROM (
    SELECT ss.seat_id
    FROM show_seat ss
    JOIN JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j
         ON j.seat_id = ss.seat_id
    LEFT JOIN booking b ON b.booking_id = ss.booking_id
    WHERE ss.show_id = p_show_id
      AND ( ss.status = 'AVAILABLE'
         OR (ss.status = 'HELD' AND b.hold_expires_at < NOW(3)) )
    ORDER BY ss.seat_id
    FOR UPDATE OF ss
  ) t;

  IF v_requested = 0 OR v_claimable <> v_requested THEN
    ROLLBACK; SET p_result = 'UNAVAILABLE'; LEAVE proc;
  END IF;

  -- Retire the previous owners of any expired holds we are taking over.
  UPDATE booking b
  JOIN show_seat ss ON ss.booking_id = b.booking_id
  SET b.status = 'EXPIRED', b.version = b.version + 1
  WHERE ss.show_id = p_show_id
    AND ss.seat_id IN (SELECT seat_id FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) x)
    AND ss.status = 'HELD' AND b.status = 'PENDING' AND b.hold_expires_at < NOW(3);

  INSERT INTO booking (user_id, show_id, status, hold_expires_at)
  VALUES (p_user_id, p_show_id, 'PENDING', DATE_ADD(NOW(3), INTERVAL p_hold_seconds SECOND));
  SET p_booking_id = LAST_INSERT_ID();

  UPDATE show_seat
  SET status = 'HELD', booking_id = p_booking_id, version = version + 1
  WHERE show_id = p_show_id
    AND seat_id IN (SELECT seat_id FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) y);

  INSERT INTO booking_seat (booking_id, seat_id, price_paid)
  SELECT p_booking_id, st.seat_id, sp.price
  FROM seat st
  JOIN show_price sp ON sp.category_id = st.category_id AND sp.show_id = p_show_id
  WHERE st.seat_id IN (SELECT seat_id FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) z);

  COMMIT;
  SET p_result = 'HELD';
END proc$$

-- ---------------------------------------------------------------------
-- 2. Idempotent payment webhook
--    Safe to call any number of times, concurrently, with the same event_id.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_process_payment_webhook$$
CREATE PROCEDURE sp_process_payment_webhook(
  IN  p_event_id         VARCHAR(100),
  IN  p_gateway_order_id VARCHAR(64),
  IN  p_event_type       VARCHAR(50),
  IN  p_payload          JSON,
  OUT p_result           VARCHAR(30))
proc: BEGIN
  DECLARE v_payment_id BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_booking_id BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_bstatus    VARCHAR(20)     DEFAULT NULL;
  DECLARE v_expires    DATETIME(3)     DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN ROLLBACK; SET p_result = 'RETRY'; END;      -- gateway will redeliver

  START TRANSACTION;

  -- Step 1: claim the event. The PK makes the second concurrent insert block, then no-op.
  INSERT IGNORE INTO payment_webhook_event (event_id, gateway_order_id, event_type, payload)
  VALUES (p_event_id, p_gateway_order_id, p_event_type, p_payload);
  IF ROW_COUNT() = 0 THEN
    ROLLBACK; SET p_result = 'DUPLICATE'; LEAVE proc;   -- already seen: reply 200, do nothing
  END IF;

  -- Step 2: lock payment, then booking (same order everywhere).
  SELECT payment_id, booking_id INTO v_payment_id, v_booking_id
  FROM payment WHERE gateway_order_id = p_gateway_order_id FOR UPDATE;

  IF v_payment_id IS NULL THEN
    UPDATE payment_webhook_event SET processed_at = NOW(3) WHERE event_id = p_event_id;
    COMMIT; SET p_result = 'UNKNOWN_ORDER'; LEAVE proc;
  END IF;

  SELECT status, hold_expires_at INTO v_bstatus, v_expires
  FROM booking WHERE booking_id = v_booking_id FOR UPDATE;

  IF p_event_type = 'payment.success' THEN
    IF v_bstatus = 'PENDING' AND v_expires >= NOW(3) THEN
      UPDATE payment SET status = 'SUCCESS' WHERE payment_id = v_payment_id;
      UPDATE booking SET status = 'CONFIRMED', version = version + 1 WHERE booking_id = v_booking_id;
      UPDATE show_seat SET status = 'BOOKED', version = version + 1
      WHERE booking_id = v_booking_id AND status = 'HELD';
      SET p_result = 'CONFIRMED';
    ELSE
      -- Paid after the hold expired (or booking already confirmed/cancelled): never
      -- re-take seats someone else may own; queue a refund instead.
      UPDATE payment SET status = 'REFUND_PENDING' WHERE payment_id = v_payment_id;
      SET p_result = 'REFUND_PENDING';
    END IF;
  ELSEIF p_event_type = 'payment.failed' THEN
    UPDATE payment SET status = 'FAILED' WHERE payment_id = v_payment_id AND status = 'CREATED';
    SET p_result = 'PAYMENT_FAILED';
  ELSE
    SET p_result = 'IGNORED';
  END IF;

  UPDATE payment_webhook_event SET processed_at = NOW(3) WHERE event_id = p_event_id;
  COMMIT;
END proc$$

-- ---------------------------------------------------------------------
-- 3. Timed-hold release (safety net behind the Redis TTL)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_release_expired_holds$$
CREATE PROCEDURE sp_release_expired_holds()
BEGIN
  -- Mutually exclusive with the webhook: both need the booking row lock, and the webhook
  -- only confirms while hold_expires_at >= NOW().
  UPDATE booking SET status = 'EXPIRED', version = version + 1
  WHERE status = 'PENDING' AND hold_expires_at < NOW(3);

  UPDATE show_seat ss JOIN booking b ON b.booking_id = ss.booking_id
  SET ss.status = 'AVAILABLE', ss.booking_id = NULL, ss.version = ss.version + 1
  WHERE ss.status = 'HELD' AND b.status IN ('EXPIRED','CANCELLED');
END$$

DROP EVENT IF EXISTS ev_release_expired_holds$$
CREATE EVENT ev_release_expired_holds
  ON SCHEDULE EVERY 5 SECOND DO CALL sp_release_expired_holds()$$

DELIMITER ;
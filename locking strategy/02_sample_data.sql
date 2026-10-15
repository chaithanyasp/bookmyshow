USE ticketing;

INSERT INTO city (name, state) VALUES ('Bengaluru','Karnataka'), ('Mumbai','Maharashtra');

INSERT INTO theatre (city_id, name, address) VALUES
 (1,'PVR Orion Mall','Dr Rajkumar Rd, Rajajinagar, Bengaluru'),
 (1,'INOX Garuda Mall','Magrath Rd, Ashok Nagar, Bengaluru'),
 (2,'PVR Juhu','Juhu Tara Rd, Mumbai');

INSERT INTO screen (theatre_id, name) VALUES (1,'Audi 1'),(1,'Audi 2'),(2,'Audi 1'),(3,'Audi 1');

INSERT INTO seat_category (name) VALUES ('Classic'),('Prime'),('Recliner');

-- 2 rows x 5 seats per screen (A = Prime, B = Classic) to keep the sample small
INSERT INTO seat (screen_id, row_label, seat_number, category_id)
SELECT sc.screen_id, r.row_label, n.n, r.category_id
FROM screen sc
JOIN (SELECT 'A' AS row_label, 2 AS category_id UNION ALL SELECT 'B', 1) r
JOIN (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) n;

INSERT INTO movie (title, duration_min, certificate, release_date) VALUES
 ('Dune: Part Three',165,'UA','2026-10-01'),
 ('Kantara: Chapter 2',150,'UA','2026-09-25'),
 ('Inside Out 3',105,'U','2026-10-08');

INSERT INTO language (name) VALUES ('English'),('Kannada'),('Hindi');
INSERT INTO format (name) VALUES ('2D'),('3D'),('IMAX 2D');

-- Shows for today and tomorrow (so P2 returns data whenever you run it)
INSERT INTO movie_show (screen_id, movie_id, language_id, format_id, start_time) VALUES
 (1,1,1,3, TIMESTAMP(CURDATE(),'10:00:00')),
 (1,1,1,3, TIMESTAMP(CURDATE(),'14:00:00')),
 (1,1,1,3, TIMESTAMP(CURDATE(),'18:30:00')),
 (2,2,2,1, TIMESTAMP(CURDATE(),'11:15:00')),
 (2,2,2,1, TIMESTAMP(CURDATE(),'15:00:00')),
 (2,3,1,2, TIMESTAMP(CURDATE(),'20:00:00')),
 (1,1,1,3, TIMESTAMP(CURDATE() + INTERVAL 1 DAY,'10:00:00')),
 (2,3,3,1, TIMESTAMP(CURDATE() + INTERVAL 1 DAY,'13:00:00')),
 (3,2,2,1, TIMESTAMP(CURDATE(),'12:00:00'));

INSERT INTO show_price (show_id, category_id, price)
SELECT s.show_id, c.category_id, CASE c.name WHEN 'Prime' THEN 350 WHEN 'Classic' THEN 220 ELSE 600 END
FROM movie_show s JOIN seat_category c;

-- Inventory: every seat of the show's screen starts AVAILABLE
INSERT INTO show_seat (show_id, seat_id)
SELECT s.show_id, st.seat_id FROM movie_show s JOIN seat st ON st.screen_id = s.screen_id;

INSERT INTO app_user (name, email, phone) VALUES
 ('Asha Rao','asha@example.com','+919800000001'),
 ('Vikram Shah','vikram@example.com','+919800000002'),
 ('Meera Nair','meera@example.com','+919800000003');

-- A confirmed booking: Asha has seats A1, A2 of show 1
INSERT INTO booking (user_id, show_id, status, hold_expires_at)
VALUES (1, 1, 'CONFIRMED', NOW(3) + INTERVAL 10 MINUTE);
SET @b := LAST_INSERT_ID();

UPDATE show_seat SET status='BOOKED', booking_id=@b, version=version+1
WHERE show_id=1 AND seat_id IN (SELECT seat_id FROM seat WHERE screen_id=1 AND row_label='A' AND seat_number IN (1,2));

INSERT INTO booking_seat (booking_id, seat_id, price_paid)
SELECT @b, seat_id, 350 FROM seat WHERE screen_id=1 AND row_label='A' AND seat_number IN (1,2);

INSERT INTO payment (booking_id, gateway_order_id, amount, status)
VALUES (@b, 'order_NX1001', 700.00, 'SUCCESS');

INSERT INTO payment_webhook_event (event_id, gateway_order_id, event_type, payload, processed_at)
VALUES ('evt_001','order_NX1001','payment.success','{"order_id":"order_NX1001","amount":70000}', NOW(3));
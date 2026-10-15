-- =====================================================================
-- P1: Ticketing schema (MySQL 8.0.16+, InnoDB)
-- Note: SHOW is a reserved word in MySQL, so the shows table is `movie_show`.
-- =====================================================================
DROP DATABASE IF EXISTS ticketing;
CREATE DATABASE ticketing CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE ticketing;

-- ---------- Static / master data ----------
CREATE TABLE city (
  city_id  INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name     VARCHAR(100) NOT NULL,
  state    VARCHAR(100) NOT NULL,
  UNIQUE KEY uq_city (name, state)
) ENGINE=InnoDB;

CREATE TABLE theatre (
  theatre_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  city_id    INT UNSIGNED NOT NULL,
  name       VARCHAR(150) NOT NULL,
  address    VARCHAR(255) NOT NULL,
  UNIQUE KEY uq_theatre (city_id, name),
  CONSTRAINT fk_theatre_city FOREIGN KEY (city_id) REFERENCES city(city_id)
) ENGINE=InnoDB;

CREATE TABLE screen (
  screen_id  INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  theatre_id INT UNSIGNED NOT NULL,
  name       VARCHAR(50) NOT NULL,                 -- 'Audi 1', 'IMAX'
  UNIQUE KEY uq_screen (theatre_id, name),
  CONSTRAINT fk_screen_theatre FOREIGN KEY (theatre_id) REFERENCES theatre(theatre_id)
) ENGINE=InnoDB;

CREATE TABLE seat_category (
  category_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(50) NOT NULL UNIQUE          -- 'Classic', 'Prime', 'Recliner'
) ENGINE=InnoDB;

CREATE TABLE seat (                                 -- physical seat of a screen
  seat_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  screen_id   INT UNSIGNED NOT NULL,
  row_label   VARCHAR(3)   NOT NULL,
  seat_number SMALLINT UNSIGNED NOT NULL,
  category_id INT UNSIGNED NOT NULL,
  UNIQUE KEY uq_seat_position (screen_id, row_label, seat_number),
  CONSTRAINT fk_seat_screen   FOREIGN KEY (screen_id)   REFERENCES screen(screen_id),
  CONSTRAINT fk_seat_category FOREIGN KEY (category_id) REFERENCES seat_category(category_id)
) ENGINE=InnoDB;

CREATE TABLE movie (
  movie_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  title        VARCHAR(200) NOT NULL,
  duration_min SMALLINT UNSIGNED NOT NULL,
  certificate  ENUM('U','UA','A','S') NOT NULL,
  release_date DATE NOT NULL
) ENGINE=InnoDB;

CREATE TABLE language (
  language_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(50) NOT NULL UNIQUE
) ENGINE=InnoDB;

CREATE TABLE format (
  format_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name      VARCHAR(30) NOT NULL UNIQUE            -- '2D', '3D', 'IMAX 2D'
) ENGINE=InnoDB;

-- ---------- Shows ----------
CREATE TABLE movie_show (
  show_id     BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  screen_id   INT UNSIGNED NOT NULL,
  movie_id    INT UNSIGNED NOT NULL,
  language_id INT UNSIGNED NOT NULL,
  format_id   INT UNSIGNED NOT NULL,
  start_time  DATETIME NOT NULL,                   -- date is derived from this, never stored twice
  status      ENUM('SCHEDULED','CANCELLED','COMPLETED') NOT NULL DEFAULT 'SCHEDULED',
  UNIQUE KEY uq_screen_start (screen_id, start_time),  -- also serves the P2 lookup
  KEY ix_show_movie_start (movie_id, start_time),
  CONSTRAINT fk_show_screen   FOREIGN KEY (screen_id)   REFERENCES screen(screen_id),
  CONSTRAINT fk_show_movie    FOREIGN KEY (movie_id)    REFERENCES movie(movie_id),
  CONSTRAINT fk_show_language FOREIGN KEY (language_id) REFERENCES language(language_id),
  CONSTRAINT fk_show_format   FOREIGN KEY (format_id)   REFERENCES format(format_id)
) ENGINE=InnoDB;

CREATE TABLE show_price (                           -- price depends on (show, category) only
  show_id     BIGINT UNSIGNED NOT NULL,
  category_id INT UNSIGNED NOT NULL,
  price       DECIMAL(8,2) NOT NULL CHECK (price >= 0),
  PRIMARY KEY (show_id, category_id),
  CONSTRAINT fk_sp_show     FOREIGN KEY (show_id)     REFERENCES movie_show(show_id),
  CONSTRAINT fk_sp_category FOREIGN KEY (category_id) REFERENCES seat_category(category_id)
) ENGINE=InnoDB;

-- ---------- Users, bookings ----------
CREATE TABLE app_user (
  user_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name    VARCHAR(100) NOT NULL,
  email   VARCHAR(150) NOT NULL UNIQUE,
  phone   VARCHAR(20)  NOT NULL UNIQUE
) ENGINE=InnoDB;

CREATE TABLE booking (
  booking_id      BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id         BIGINT UNSIGNED NOT NULL,
  show_id         BIGINT UNSIGNED NOT NULL,
  status          ENUM('PENDING','CONFIRMED','EXPIRED','CANCELLED') NOT NULL DEFAULT 'PENDING',
  hold_expires_at DATETIME(3) NOT NULL,
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  version         INT UNSIGNED NOT NULL DEFAULT 0,  -- optimistic-lock counter
  KEY ix_booking_user (user_id, created_at),
  KEY ix_booking_show (show_id),
  KEY ix_booking_sweeper (status, hold_expires_at), -- expiry sweeper
  CONSTRAINT fk_booking_user FOREIGN KEY (user_id) REFERENCES app_user(user_id),
  CONSTRAINT fk_booking_show FOREIGN KEY (show_id) REFERENCES movie_show(show_id)
) ENGINE=InnoDB;

-- Live seat inventory per show. One row per (show, seat) is THE lock target:
-- the composite PK means two users can never own the same seat of the same show.
CREATE TABLE show_seat (
  show_id    BIGINT UNSIGNED NOT NULL,
  seat_id    INT UNSIGNED NOT NULL,
  status     ENUM('AVAILABLE','HELD','BOOKED') NOT NULL DEFAULT 'AVAILABLE',
  booking_id BIGINT UNSIGNED NULL,                  -- current owner of the hold / booking
  version    INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (show_id, seat_id),
  KEY ix_ss_show_status (show_id, status),
  KEY ix_ss_booking (booking_id),
  CONSTRAINT fk_ss_show    FOREIGN KEY (show_id)    REFERENCES movie_show(show_id),
  CONSTRAINT fk_ss_seat    FOREIGN KEY (seat_id)    REFERENCES seat(seat_id),
  CONSTRAINT fk_ss_booking FOREIGN KEY (booking_id) REFERENCES booking(booking_id),
  CONSTRAINT ck_ss_owner CHECK (
    (status = 'AVAILABLE' AND booking_id IS NULL) OR
    (status <> 'AVAILABLE' AND booking_id IS NOT NULL))
) ENGINE=InnoDB;

CREATE TABLE booking_seat (                         -- immutable receipt: seats + price paid
  booking_id BIGINT UNSIGNED NOT NULL,
  seat_id    INT UNSIGNED NOT NULL,
  price_paid DECIMAL(8,2) NOT NULL,                 -- snapshot, intentionally not re-derived
  PRIMARY KEY (booking_id, seat_id),
  CONSTRAINT fk_bs_booking FOREIGN KEY (booking_id) REFERENCES booking(booking_id),
  CONSTRAINT fk_bs_seat    FOREIGN KEY (seat_id)    REFERENCES seat(seat_id)
) ENGINE=InnoDB;

-- ---------- Payments ----------
CREATE TABLE payment (
  payment_id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  booking_id         BIGINT UNSIGNED NOT NULL,      -- many attempts allowed per booking
  gateway_order_id   VARCHAR(64) NOT NULL,
  amount             DECIMAL(10,2) NOT NULL,
  status             ENUM('CREATED','SUCCESS','FAILED','REFUND_PENDING','REFUNDED') NOT NULL DEFAULT 'CREATED',
  created_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_gateway_order (gateway_order_id),
  KEY ix_payment_booking (booking_id),
  CONSTRAINT fk_payment_booking FOREIGN KEY (booking_id) REFERENCES booking(booking_id)
) ENGINE=InnoDB;

-- Idempotency ledger: the gateway's event id is the PRIMARY KEY, so a redelivered
-- webhook cannot be inserted twice, and therefore cannot be processed twice.
CREATE TABLE payment_webhook_event (
  event_id         VARCHAR(100) NOT NULL PRIMARY KEY,
  gateway_order_id VARCHAR(64)  NOT NULL,
  event_type       VARCHAR(50)  NOT NULL,
  payload          JSON NOT NULL,
  received_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  processed_at     DATETIME(3) NULL,
  KEY ix_wh_order (gateway_order_id)
) ENGINE=InnoDB;
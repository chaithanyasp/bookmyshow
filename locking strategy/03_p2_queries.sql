USE ticketing;

-- P2: all shows at a theatre on a date, with show timings.
-- Set the two inputs (theatre_id, date); in the app these are bind parameters.
SET @theatre_id = 1;
SET @show_date  = CURDATE();

-- (a) Flat list: one row per show, exactly what the screenshot's showtime chips need.
SELECT  m.title                              AS movie,
        l.name                               AS language,
        f.name                               AS format,
        sc.name                              AS screen,
        s.show_id,
        TIME_FORMAT(s.start_time, '%h:%i %p') AS show_time
FROM    screen sc
JOIN    movie_show s ON s.screen_id  = sc.screen_id
JOIN    movie      m ON m.movie_id   = s.movie_id
JOIN    language   l ON l.language_id = s.language_id
JOIN    format     f ON f.format_id  = s.format_id
WHERE   sc.theatre_id = @theatre_id
  AND   s.start_time >= @show_date                           -- sargable range, uses the
  AND   s.start_time <  @show_date + INTERVAL 1 DAY          -- (screen_id,start_time) index
  AND   s.status = 'SCHEDULED'
ORDER BY m.title, l.name, f.name, s.start_time;

-- (b) Grouped per movie (one row per movie/language/format, timings as a JSON array),
--     matching the per-movie layout of the UI.
SELECT  m.title AS movie, l.name AS language, f.name AS format,
        JSON_ARRAYAGG(JSON_OBJECT('show_id', s.show_id,
                                  'time', TIME_FORMAT(s.start_time,'%h:%i %p'))) AS shows
FROM    screen sc
JOIN    movie_show s ON s.screen_id  = sc.screen_id
JOIN    movie      m ON m.movie_id   = s.movie_id
JOIN    language   l ON l.language_id = s.language_id
JOIN    format     f ON f.format_id  = s.format_id
WHERE   sc.theatre_id = @theatre_id
  AND   s.start_time >= @show_date AND s.start_time < @show_date + INTERVAL 1 DAY
  AND   s.status = 'SCHEDULED'
GROUP BY m.movie_id, m.title, l.language_id, l.name, f.format_id, f.name
ORDER BY m.title;

-- (c) The "next 7 dates" strip of the date picker.
WITH RECURSIVE d (n, dt) AS (
  SELECT 0, CURDATE() UNION ALL SELECT n + 1, dt + INTERVAL 1 DAY FROM d WHERE n < 6
)
SELECT dt AS show_date, DATE_FORMAT(dt, '%a %e %b') AS label FROM d;
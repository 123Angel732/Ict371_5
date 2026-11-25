---Q5
--a
CREATE TABLE students (
student_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
student_number TEXT NOT NULL UNIQUE,
full_name TEXT NOT NULL
);
CREATE TABLE rooms (
room_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
room_number TEXT NOT NULL UNIQUE,
capacity INTEGER NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
allocation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
student_id BIGINT NOT NULL REFERENCES students(student_id),
room_id BIGINT NOT NULL REFERENCES rooms(room_id),
allocated_on DATE NOT NULL,
released_on DATE,
status TEXT NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
CHECK ((status = 'ACTIVE' AND released_on IS NULL) OR
(status = 'ENDED' AND released_on IS NOT NULL))
);
-- Database-level guarantee: at most one ACTIVE allocation per student,
-- even for two concurrent transactions (complements the trigger).
CREATE UNIQUE INDEX uq_one_active_allocation_per_student
ON allocations(student_id) WHERE status = 'ACTIVE';
CREATE TABLE occupancy_snapshot (
snapshot_date DATE NOT NULL,
room_id BIGINT NOT NULL REFERENCES rooms(room_id),
occupied_beds INTEGER NOT NULL,
free_beds INTEGER NOT NULL,
PRIMARY KEY (snapshot_date, room_id)
);

--b
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id BIGINT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_capacity INTEGER; v_occupied INTEGER;
BEGIN
SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown room ID %', p_room_id;
END IF;
SELECT COUNT(*) INTO v_occupied FROM allocations
WHERE room_id = p_room_id AND status = 'ACTIVE'; -- ENDED rows are ignored
RETURN v_capacity - v_occupied;
END; $$;


--c
CREATE OR REPLACE PROCEDURE pr_allocate_room(
p_student_id BIGINT, p_room_id BIGINT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
PERFORM 1 FROM students WHERE student_id = p_student_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student ID %', p_student_id; END IF;
-- Lock the room row to serialise capacity checks for this room.
PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room ID %', p_room_id; END IF;
IF p_allocated_on IS NULL THEN
RAISE EXCEPTION 'Allocation date is required';
END IF;
IF EXISTS (SELECT 1 FROM allocations
WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
RAISE EXCEPTION 'Student already has an ACTIVE allocation';
END IF;
IF fn_free_beds(p_room_id) <= 0 THEN
RAISE EXCEPTION 'Room is full';
END IF;
INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

--d
CREATE OR REPLACE FUNCTION trg_enforce_allocation_rules()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_capacity INTEGER; v_occupied INTEGER;
BEGIN
IF NEW.status = 'ACTIVE' THEN
-- Locking the room serialises direct SQL changes as well.
SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room'; END IF;
SELECT COUNT(*) INTO v_occupied FROM allocations a
WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
AND a.allocation_id <> COALESCE(NEW.allocation_id, -1); -- exclude row being updated
IF v_occupied >= v_capacity THEN
RAISE EXCEPTION 'Room capacity exceeded';
END IF;
IF EXISTS (SELECT 1 FROM allocations a
WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
AND a.allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
RAISE EXCEPTION 'Student already has an ACTIVE allocation';
END IF;
IF NEW.released_on IS NOT NULL THEN
RAISE EXCEPTION 'ACTIVE allocation must have NULL released_on';
END IF;
ELSIF NEW.status = 'ENDED' AND NEW.released_on IS NULL THEN
RAISE EXCEPTION 'ENDED allocation requires released_on';
END IF;
RETURN NEW;
END; $$;
CREATE TRIGGER allocations_rules
BEFORE INSERT OR UPDATE ON allocations FOR EACH ROW
EXECUTE FUNCTION trg_enforce_allocation_rules();

--e
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')::INTEGER AS occupied_beds,
r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')::INTEGER AS free_beds
FROM rooms r LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

--f
CREATE INDEX idx_allocations_active_room
ON allocations(room_id) WHERE status = 'ACTIVE';
-- Matching query and plan:
EXPLAIN SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';

--g
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
SELECT CURRENT_DATE, r.room_id,
COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')::INTEGER,
r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')::INTEGER
FROM rooms r LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.capacity
ON CONFLICT (snapshot_date, room_id) DO UPDATE
SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END; $$;
-- Schedule: every day at 23:55.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('hostel-occupancy-snapshot', '55 23 * * *',
$$CALL pr_refresh_occupancy()$$);


---seeds
INSERT INTO students(student_number, full_name) VALUES
('H001', 'Martha'), ('H002', 'Kelvin'), ('H003', 'Tina'), ('H004', 'Brian');
INSERT INTO rooms(room_number, capacity) VALUES ('A01', 2), ('A02', 3), ('A03', 2);
CALL pr_allocate_room(1, 1, CURRENT_DATE); -- A01 is FULL: 2 of 2 beds
CALL pr_allocate_room(2, 1, CURRENT_DATE);
CALL pr_allocate_room(3, 2, CURRENT_DATE); -- A02 is PARTLY OCCUPIED: 1 of 3 beds
-- History: Brian lived in A03 and left, so A03 is EMPTY (0 of 2) and the ENDED row is kept.
CALL pr_allocate_room(4, 3, CURRENT_DATE - 10);
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE - 1
WHERE student_id = 4 AND status = 'ACTIVE';
SELECT fn_free_beds(3) AS free_beds_in_a03; -- 2 (ended rows do not count)
SELECT * FROM v_room_occupancy ORDER BY room_number;
SELECT allocation_id, student_id, room_id, status, released_on FROM allocations ORDER BY 1;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy(); -- rerun: still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;


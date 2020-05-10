----------------------------------------------------------------------
-- File: BerlinMOD_DataGenerator.SQL     -----------------------------
----------------------------------------------------------------------
--  This file is part of MobilityDB.
--
--  Copyright (C) 2020, Universite Libre de Bruxelles.

-- This file creates the basic data for the BerlinMOD benchmark.

-- The only other things you need to generate the BerlinMOD data
-- is a running MobilityDB system and the Berlin geo data, that is provided
-- in three files, 'streets', 'homeRegions', and 'workRegions'.
-- The data files must be present in directory $SECONDO_BUILD_DIR/bin/.
-- Prior to data generation, you might want to clear your secondo
-- database directory (though this is not required).

-- You can change parameters in the Section (2) of this file.
-- Usually, changing the master parameter 'SCALEFACTOR' should do it.
-- But you also might be interested in changing parameters for the
-- random number generator, experiment with non-standard scaling
-- patterns or modify the sampling of positions.

-- The database must contain the following relations:
--
--    streets:      rel{Vmax: real, GeoData: line}
--      - Vmax is the maximum allowed velocity (speed limit)
--      - GeoData is a line representing the street
--    homeRegions:  rel{Priority: int, Weight: real, GeoData: region}
--    workRegions:  rel{Priority: int, Weight: real, GeoData: region}
--      - Priority is an int indicating the region selection priority
--      - Weight is the relative weight to choose from the given region
--     - GeoData is a region describing the region's area

-- The generated data is saved into the current database.
----------------------------------------------------------------------

----------------------------------------------------------------------
------ Section (1): Utility Functions --------------------------------
----------------------------------------------------------------------

-- Inspired from
-- https://bugfactory.io/blog/generating-random-numbers-according-to-a-continuous-probability-distribution-with-postgresql/

-- Random integer in a range
CREATE OR REPLACE FUNCTION random_int(low int, high int)
	RETURNS int AS $$
BEGIN
	RETURN floor(random() * (high-low+1) + low);
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
select random_int(1,7), count(*)
from generate_series(1, 1e3)
group by 1
order by 1
*/

-- Exponential distribution

CREATE OR REPLACE FUNCTION random_exp(lambda float DEFAULT 1.0)
RETURNS float AS $$
DECLARE
	v float;
BEGIN
	IF lambda = 0.0 THEN
		RETURN NULL;
	END IF;
	LOOP
    	v = random();
    EXIT WHEN v <> 0.0;
  END LOOP;
  RETURN -1 * ln(v) * lambda;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
with data as (
  select random_exp(1) AS r from generate_series(1,1e5) t
)
select min(r), max(r), avg(r)
from data;
-- Successfully run. Total query runtime: 6 min 18 secs.
*/

-- Binomial distribution

CREATE OR REPLACE FUNCTION random_binomial(n int, p float)
RETURNS float AS $$
DECLARE
	i int = 1;
	result float = 0;
BEGIN
	IF n <= 0 OR p <= 0.0 OR p >= 1.0 THEN
		RETURN NULL;
	END IF;
  LOOP
    IF random() < p THEN
			result = result + 1;
		END IF;
		i = i + 1;
    EXIT WHEN i >= n;
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
with data as (
  select random_binomial(100,0.5) AS r from generate_series(1,1e5) t
)
select min(r), max(r), avg(r)
from data;
-- Successfully run. Total query runtime: 40 secs 876 msec.
*/

-- Gaussian distribution
-- https://stackoverflow.com/questions/9431914/gaussian-random-distribution-in-postgresql
--
CREATE OR REPLACE FUNCTION random_gauss(avg float = 0, stddev float = 1)
RETURNS float AS $$
DECLARE
	x1 real; x2 real; w real;
BEGIN
  LOOP
    x1 = 2.0 * random() - 1.0;
    x2 = 2.0 * random() - 1.0;
    w = x1*x1 + x2*x2;
    EXIT WHEN w < 1.0;
  END LOOP;
  RETURN avg + x1 * sqrt(-2.0*ln(w)/w) * stddev;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
with data as (
  select t, random_gauss(100,15)::integer score from generate_series(1,1000000) t
)
select score, sum(1), repeat('=',sum(1)::integer/500) bar
from data
where score between 60 and 140
group by score
order by 1;
*/

-- (3.3.7) Function BoundedGaussian
-- Computes a gaussian distributed value within [Low, High]

CREATE OR REPLACE FUNCTION BoundedGaussian(low float, high float, avg float = 0, stddev float = 1)
RETURNS float AS $$
DECLARE
	result real;
BEGIN
	result = random_gauss(avg, stddev);
	IF result < low THEN
		RETURN low;
	ELSEIF result > high THEN
		RETURN high;
	ELSE
		RETURN result;
	END IF;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
select BoundedGaussian(-0.5, 0.5)
from generate_series(1, 1e2)
order by 1
*/

-- (3.3.10) Function CreatePause
-- Creates a random duration of length [0ms, 2h]

CREATE OR REPLACE FUNCTION CreatePause()
RETURNS interval AS $$
BEGIN
	RETURN (((BoundedGaussian(-6.0, 6.0, 0.0, 1.4) * 100.0) + 600.0) * 6000.0)::int * interval '1 ms';
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
with test(t) as (
select CreatePause()
from generate_series(1, 1e5)
order by 1
)
select min(t), max(t) from test
*/

-- (3.3.11) Function CreatePauseN
-- Creates a random non-zero duration of length [2ms, N min - 4ms]
-- using flat distribution

CREATE OR REPLACE FUNCTION CreatePauseN(Minutes int)
	RETURNS interval AS $$
BEGIN
	RETURN ( 2 + random_int(1, Minutes * 60000 - 6) ) * interval '1 ms';
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
with test(t) as (
select CreatePauseN(1)
from generate_series(1, 1e5)
order by 1
)
select min(t), max(t) from test
*/

-- (3.3.12) Function CreateDurationRhoursNormal
-- Creates a normally distributed duration within [-Rhours h, +Rhours h]

CREATE OR REPLACE FUNCTION CreateDurationRhoursNormal(Rhours float)
	RETURNS interval AS $$
DECLARE
	duration interval;
BEGIN
	duration = ((random_gauss() * Rhours * 1800000) / 86400000) * interval '1 d';
	IF duration > (Rhours / 24.0 ) * interval '1 d' THEN
		duration = (Rhours / 24.0) * interval '1 d';
	ELSEIF duration < (Rhours / -24.0 ) * interval '1 d' THEN
		duration = (Rhours / -24.0) * interval '1 d';
	END IF;
	RETURN duration;
END
$$ LANGUAGE 'plpgsql' STRICT;

/*
with test(t) as (
select CreateDurationRhoursNormal(12)
from generate_series(1, 1e5)
order by 1
)
select min(t), max(t) from test
*/

-- (3.3.16) Function RandType(): Return a random vehicle type
--	(0 = passenger, 1 = bus, 2 = truck):

CREATE OR REPLACE FUNCTION random_type()
	RETURNS int AS $$
BEGIN
	IF random_int(1, 100) < 90 THEN
		RETURN 0;
	ELSEIF random_int(1, 100) < 50 THEN
		RETURN 1;
	ELSE
		RETURN 2;
	END IF;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
 SELECT random_type(), COUNT(*)
 FROM generate_series(1, 100)
 GROUP BY 1
 ORDER BY 1;
 */

-- Choose a random home/work node for the region based approach

DROP FUNCTION IF EXISTS selectHomeNodeRegionBased;
CREATE FUNCTION selectHomeNodeRegionBased()
RETURNS bigint AS $$
DECLARE
	result bigint;
BEGIN
	WITH RandomRegion AS (
		SELECT gid
		FROM homeRegions
		WHERE random() <= CumProb
		ORDER BY CumProb
		LIMIT 1
	)
	SELECT N.Id INTO result
	FROM homeNodes N, RandomRegion R
	WHERE N.gid = R.gid
	ORDER BY random()
	LIMIT 1;
	RETURN result;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
-- WE DON'T COVER ALL REGIONS EVEN AFTER 1e5 attempts
with temp(node) as (
select selectHomeNodeRegionBased()
from generate_series(1, 1e5)
)
select gid, count(*)
from temp T, homenodes N
where t.node = id
group by gid order by gid;
-- Total query runtime: 3 min 6 secs.
*/

CREATE OR REPLACE FUNCTION selectWorkNodeRegionBased()
RETURNS integer AS $$
DECLARE
	result int;
BEGIN
	WITH RandomRegion AS (
		SELECT gid
		FROM workRegions
		WHERE random() <= CumProb
		ORDER BY CumProb
		LIMIT 1
	)
	SELECT N.Id INTO result
	FROM workNodes N, RandomRegion R
	WHERE N.gid = R.gid
	ORDER BY random()
	LIMIT 1;
	RETURN result;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
-- WE DON'T COVER ALL REGIONS EVEN AFTER 1e5 attempts
with temp(node) as (
select selectWorkNodeRegionBased()
from generate_series(1, 1e5)
)
select gid, count(*)
from temp T, homenodes N
where t.node = id
group by gid order by gid;
-- Total query runtime: 3 min.
*/

-------------------------------------------------------------------------
-- (3.3.9) Function SelectDestNode
-- Selects a destination node for an additional trip.
-- 80% of the destinations are from the neighbourhood
-- 20% are from the complete graph
--

CREATE OR REPLACE FUNCTION SelectDestNode(VehicleId int)
RETURNS integer AS $$
DECLARE
	NBRNODES int;
	NoNeighbours int;
	neighbour int;
	result int;
BEGIN
	SELECT COUNT(*) INTO NBRNODES FROM Nodes;
	EXECUTE format('SELECT COUNT(*) FROM Neighbourhood WHERE Vehicle = %s', VehicleId) INTO NoNeighbours;
	IF random() < 0.8 THEN
		neighbour = (VehicleId * 1e6) + random_int(1, NoNeighbours);
		EXECUTE format('SELECT node FROM Neighbourhood WHERE Id = %s', neighbour) INTO result;
	ELSE
		result = random_int(1, NBRNODES);
	END IF;
	RETURN result;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
 SELECT SelectDestNode(150)
 FROM generate_series(1, 50)
 ORDER BY 1;
*/

----------------------------------------------------------------------

DROP TYPE IF EXISTS step CASCADE;
CREATE TYPE step as (linestring geometry, maxspeed float, category int);

DROP FUNCTION IF EXISTS createPath;
CREATE OR REPLACE FUNCTION createPath(startNode bigint, endNode bigint, mode text)
RETURNS step[] AS $$
DECLARE
	query_pgr text;
	result step[];
BEGIN
	IF mode = 'Fastest Path' THEN
		query_pgr = 'SELECT gid AS id, source, target, cost_s AS cost FROM ways';
	ELSE
		query_pgr = 'SELECT gid AS id, source, target, length_m AS cost FROM ways';
	END IF;
	WITH Temp1 AS (
		SELECT P.seq, P.edge
		FROM pgr_dijkstra(query_pgr, startNode, endNode, true) P
	),
	Temp2 AS (
		SELECT seq, geom,
			COALESCE(maxspeed_forward, maxspeed_backward, 30) AS maxSpeed,
			CASE
			-- motorway, motorway_link, motorway_junction, trunk, trunk_link
			WHEN tag_id BETWEEN 101 AND 105 THEN 1 -- i.e., "freeway"
			-- primary, primary_link, secondary, secondary_link, tertiary, tertiary_link
			WHEN tag_id BETWEEN 106 AND 111 THEN 2 -- i.e., "freeway"
			-- residential, living_street, unclassified, road
			ELSE 3 -- i.e., "freeway"
			END AS category
		FROM Temp1, Edges
		WHERE edge IS NOT NULL AND id = edge
	)
	SELECT array_agg((geom, maxSpeed, category)::step ORDER BY seq) INTO result
	FROM Temp2;
	RETURN result;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
select createPath(9598, 4010, 'Fastest Path')
*/

DROP FUNCTION IF EXISTS createTrip;
CREATE OR REPLACE FUNCTION createTrip(steps step[], t timestamptz,
	disturb boolean)
RETURNS tgeompoint AS $$
DECLARE
	-- CONSTANT PARAMETERS
	EPSILON float = 0.00001;
	-- sampling distance in meters at which an acceleration/deceleration/stop
	-- event may be generated.
	SAMPDIST float = 5.0;
	-- constant speed steps in meters/second, simplification of the accelaration
	ACCEL float = 12.0;
	-- approaching distance to a crossing at which a deceleration event may be
	-- generated according to the angles between the current and the next segments
	APPRDIST float = 50.0;
	-- Probabilities for forced stops at crossings by street type transition
	-- defined by a matrix where lines and columns are ordered by
	-- side road (S), main road (M), freeway (F). The OSM highway types must be
	-- mapped to one of these categories.
	STOPPROB float[] = '{{0.33, 0.66, 1.00}, {0.33, 0.50, 0.66}, {0.10, 0.33, 0.05}}';
	-- mean waiting time in secs for exponential distribution
	MEANWAIT float = 15;
	-- Set Parameters for measuring errors (only required for P_DISTURB_DATA = TRUE)
	-- The maximum total deviation from the real position and the maximum
	-- deviation per step in meters.
	-- 	* P_GPS_TOTALMAXERR is the maximum total error (default = 100.0)
	-- 	* P_GPS_TOTALMAXERR is the maximum error per step (default =   1.0)
	P_GPS_TOTALMAXERR float = 100.0;
	P_GPS_STEPMAXERR float = 1.0;

	-- Variables
	srid integer;
	noSteps integer; noSegs integer;
	i integer; j integer; k integer;
	l integer = 1; -- Number of instants generated so far
	category integer; nextCategory integer;
	curSpeed float; waitTime float;
	alpha float; curveMaxSpeed float;
	x float; y float; fraction float;
	dx float; dy float; -- used when disturb is true
	errx float = 0.0; erry float = 0.0; -- used when disturb is true
	segLength float; maxSpeed float;
	linestring geometry; nextLinestring geometry;
	p1 geometry; p2 geometry; p3 geometry; pos geometry;
	t1 timestamptz;
	instants tgeompoint[];
	curDist float;
BEGIN
	srid = ST_SRID((steps[1]).linestring);
	p1 = ST_PointN((steps[1]).linestring, 1);
	pos = p1;
	t1 := t;
	curSpeed = 0;
	instants[l] = tgeompointinst(p1, t1);
	-- RAISE NOTICE 'Start -> Speed = %', curSpeed;
	-- RAISE NOTICE '%', AsText(instants[l]);
	l = l + 1;
	noSteps = array_length(steps, 1);
	FOR i IN 1..noSteps LOOP
		-- RAISE NOTICE '*** Edge % ***', i;
		linestring = (steps[i]).linestring;
		maxSpeed = (steps[i]).maxSpeed * 1.0 / 3.6;
		category = (steps[i]).category;
		IF i < noSteps THEN
			nextLinestring = (steps[i + 1]).linestring;
			nextCategory = (steps[i + 1]).category;
		END IF;
		noSegs = ST_NPoints(linestring) - 1;
		FOR j IN 1..noSegs LOOP
			p2 = ST_PointN(linestring, j+1);
			segLength = ST_Distance(p1, p2);
			IF j < noSegs THEN
				p3 = ST_PointN(linestring, j+2);
			ELSE
				IF i < noSteps THEN
					p3 = ST_PointN(nextLinestring, 2);
				END IF;
			END IF;
			k = 1;
			WHILE NOT ST_Equals(pos, p2) LOOP
				-- Randomly choose either deceleration event (p=90%) or stop event (p=10%);
				-- With a probability proportional to 1/vmax: Apply evt;
				IF random() <= 1 / maxSpeed THEN
					IF random() <= 0.9 THEN
						-- Apply deceleration event to the trip
						curSpeed = curSpeed * random_binomial(20, 0.5) / 20.0;
						-- RAISE NOTICE 'Deceleration - > Speed = %', curSpeed;
					ELSE
						-- Apply stop event to the trip
						-- determine waiting duration using exponential distribution:
						curSpeed = 0.0;
					END IF;
				ELSE
					-- Apply acceleration event to the trip
					curSpeed = least(curSpeed + ACCEL, maxSpeed);
					-- RAISE NOTICE 'Acceleration -> Speed = %', curSpeed;
				END IF;
				IF j < noSegs OR i < noSteps THEN
					-- Reduce velocity to α/180◦ MAXSPEED where α is the angle between seg and the next segment;
					alpha = degrees(ST_Angle(p1, p2, p3));
					curveMaxSpeed = (1.0 - (mod(abs(alpha - 180.0)::numeric, 180.0)) / 180.0) * maxSpeed;
					curSpeed = LEAST(curSpeed, curveMaxSpeed);
					-- RAISE NOTICE 'Turn approaching -> Angle = %, CurveMaxSpeed = %, Speed = %', alpha, curveMaxSpeed, curSpeed;
				END IF;
				IF curSpeed < EPSILON THEN
					waitTime = random_exp(MEANWAIT);
					-- RAISE NOTICE 'Stop -> Waiting for % seconds', round(waitTime::numeric, 3);
					t1 = t1 + waitTime * interval '1 sec';
				ELSE
					-- Move pos 5m towards t (or to t if it is closer than 5m)
					fraction = SAMPDIST * k / segLength;
					x = ST_X(p1) + (ST_X(p2) - ST_X(p1)) * fraction;
					y = ST_Y(p1) + (ST_Y(p2) - ST_Y(p1)) * fraction;
					IF disturb THEN
						dx = 2 * P_GPS_STEPMAXERR * rand() / 1.0 - P_GPS_STEPMAXERR;
						dy = 2 * P_GPS_STEPMAXERR * rand() / 1.0 - P_GPS_STEPMAXERR;
						errx = errx + dx;
						erry = erry + dy;
						IF errx > P_GPS_TOTALMAXERR THEN
							errx = P_GPS_TOTALMAXERR;
						END IF;
						IF errx < - 1 * P_GPS_TOTALMAXERR THEN
							errx = -1 * P_GPS_TOTALMAXERR;
						END IF;
						IF erry > P_GPS_TOTALMAXERR THEN
							erry = P_GPS_TOTALMAXERR;
						END IF;
						IF erry < -1 * P_GPS_TOTALMAXERR THEN
							erry = -1 * P_GPS_TOTALMAXERR;
						END IF;
						x = x + dx;
						y = y + dy;
					END IF;
					pos = ST_SetSRID(ST_Point(x, y), srid);
					curDist= SAMPDIST;
					IF ST_Distance(p1, pos) >= segLength THEN
						curDist= SAMPDIST - ( ST_Distance(p1, pos) - segLength);
						pos = p2;
					END IF;
					t1 = t1 + (CurDist / curSpeed) * interval '1 sec';	
					k = k + 1;
				END IF;
				instants[l] = tgeompointinst(pos, t1);
				-- RAISE NOTICE '%', AsText(instants[l]);
				l = l + 1;
			END LOOP;
			p1 = p2;
		END LOOP;
		-- With a probability p(Stop) depending on the street type of the current egde and the street type
		-- of the next edge in P and according to Table 4, apply a stop event;
		IF random() <= STOPPROB[category][nextCategory] THEN
			curSpeed = 0;
			waitTime = random_exp(MEANWAIT);
			-- RAISE NOTICE 'Stop at crossing -> Waiting for % seconds', round(waitTime::numeric, 3);
			t1 = t1 + waitTime * interval '1 sec';
			instants[l] = tgeompointinst(pos, t1);
			l = l + 1;
		END IF;
	END LOOP;
	RETURN tgeompointseq(instants, true, true, true);
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
SELECT createTrip(createPath(9598, 4010, 'Fastest Path'), '2020-05-10 08:00:00', false)
*/

DROP FUNCTION IF EXISTS create_additional_trip;
CREATE FUNCTION create_additional_trip(vehicleId integer, t timestamptz,
	mode text, disturb boolean)
RETURNS tgeompoint AS $$
DECLARE
	-- CONSTANT PARAMETERS
	MAXITERATIONS int = 10;
	-- Variables
	noDest integer; home integer;
	i integer; j integer;
	numSteps integer;
	numInstants integer;
	dest integer[5];
	r float;
	path step[]; finalpath step[];
	trip tgeompoint;
	trips tgeompoint[4];
	result tgeompoint;
	t1 timestamptz;
	pause interval;
BEGIN
	-- Select a number of destinations between 1 and 3
	r = random();
	noDest = CASE
		WHEN r <= 0.5 THEN 1
		WHEN r <= 0.75 THEN 2
		ELSE 3
		END;
	RAISE NOTICE 'Number of destinations %', noDest;
	-- Select the destinations
	SELECT homeNode INTO home FROM Vehicle WHERE id = vehicleId;
	dest[1] = home;
	t1 = t;
	RAISE NOTICE 'Home node %', home;
	FOR i in 2..noDest + 2 LOOP
		IF i < noDest + 2 THEN
			RAISE NOTICE '*** Selecting destination % ***', i - 1;
		ELSE
			RAISE NOTICE '*** Final destination, home node % ***', home;
		END IF;
		-- The next loop takes into account that there may be no path
		-- between the current node and the next destination node
		-- The loop generates a new destination node if this is the case.
		j = 0;
		LOOP
			j =  j + 1;
			IF j = MAXITERATIONS THEN
				RAISE NOTICE '  *** Maximum number of iterations reached !!! ***';
				RETURN NULL;
			ELSE
				IF i < noDest + 2 THEN
					RAISE NOTICE '  *** Iteration % ***', j;
				END IF;
			END IF;
			path = NULL;
			finalpath = NULL;
			IF i < noDest + 2 THEN
				dest[i] = selectDestNode(vehicleId);
			ELSE
				dest[i] = home;
			END IF;
			SELECT createPath(dest[i - 1], dest[i], mode) INTO path;
			IF path IS NULL THEN
				RAISE NOTICE '  There is no path between nodes % and %', dest[i - 1], dest[i];
			ELSE
				IF i = noDest + 1 THEN
					RAISE NOTICE '  Checking connectivity between last destination and home node';
					SELECT createPath(dest[i], home, mode) INTO finalpath;
					IF finalpath IS NULL THEN
						RAISE NOTICE 'There is no path between nodes % and the home node %', dest[i], home;
					END IF;
				END IF;
			END IF;
			EXIT WHEN path IS NOT NULL AND
				(i <> noDest + 1 OR finalpath IS NOT NULL);
		END LOOP;
		IF i < noDest + 2 THEN
			RAISE NOTICE '  Destination %: %', i - 1, dest[i];
		ELSE
			RAISE NOTICE '  Home %', dest[i];
		END IF;
		SELECT createTrip(path, t1, disturb) INTO trip;
		SELECT numInstants(trip) INTO numInstants;
		trips[i] = trip;
		-- Determine a delay time dt in [0, 120] min using a
		-- bounded Gaussian distribution;
		t1 = endTimestamp(trips[i]) + createPause();
	END LOOP;
	-- Merge the trips into a single result
	result = merge(trips);
	RETURN result;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
SELECT create_additional_trip(1, '2020-05-10 08:00:00', 'Fastest Path', false)
FROM generate_series(1, 3);
*/

DROP FUNCTION IF EXISTS createDay;
CREATE FUNCTION createDay(vehicleId integer, day Date, mode text, disturb boolean)
RETURNS void AS $$
DECLARE
	-- Variables
	weekday text;
	t1 timestamptz;
	trip tgeompoint;
	home bigint; work bigint;
	path step[];
BEGIN
	SELECT to_char(day, 'day') INTO weekday;
	IF weekday = 'Saturday' OR weekday = 'unday' THEN
		-- Generate first additional trip
		IF random() <= 0.4 THEN
			t1 = Day + time '09:00:00' + CreatePauseN(120);
			RAISE NOTICE 'Weekend first additional trip starting at %', t1;
			SELECT create_additional_trip(vehicleId, t1, mode, disturb) INTO trip;
			-- It may be the case that for connectivity reason the additional
			-- trip is NULL, in that case we don't add the trip
			IF trip IS NOT NULL THEN
				INSERT INTO Trips VALUES (vehicleId, trip);
			END IF;
		END IF;
		-- Generate sedond additional trip
		IF random() <= 0.4 THEN
			t1 = Day + time '17:00:00' + CreatePauseN(120);
			RAISE NOTICE 'Weekend second additional trip starting at %', t1;
			SELECT create_additional_trip(vehicleId, t1, mode, disturb) INTO trip;
			-- It may be the case that for connectivity reason the additional
			-- trip is NULL, in that case we don't add the trip
			IF trip IS NOT NULL THEN
				INSERT INTO Trips VALUES (vehicleId, trip);
			END IF;
		END IF;
	ELSE
		-- Get home and work nodes
		SELECT homeNode, workNode INTO home, work
		FROM Vehicle WHERE id = vehicleId;
		-- Home -> Work
		t1 = Day + time '08:00:00' + CreatePauseN(120);
		RAISE NOTICE 'Trip home -> work starting at %', t1;
		SELECT createPath(home, work, mode) INTO path;
		SELECT createTrip(path, t1, disturb) INTO trip;
		INSERT INTO Trips VALUES (vehicleId, trip);
		-- Work -> Home
		t1 = Day + time '16:00:00' + CreatePauseN(120);
		SELECT createPath(work, home, mode) INTO path;
		SELECT createTrip(path, t1, disturb) INTO trip;
		RAISE NOTICE 'Trip work -> home starting at %', t1;
		INSERT INTO Trips VALUES (vehicleId, trip);
		-- With probability 0.4 add an additional trip
		IF random() <= 0.4 THEN
			t1 = Day + time '20:00:00' + CreatePauseN(90);
			RAISE NOTICE 'Weekday additional trip starting at %', t1;
			SELECT create_additional_trip(vehicleId, t1, mode, disturb) INTO trip;
			-- It may be the case that for connectivity reason the additional
			-- trip is NULL, in that case we don't add the trip
			IF trip IS NOT NULL THEN
				INSERT INTO Trips VALUES (vehicleId, trip);
			END IF;
		END IF;
	END IF;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
DROP TABLE IF EXISTS Trips;
CREATE TABLE Trips(vehicleId integer, trip tgeompoint);
SELECT createDay(1, '2020-05-10', 'Fastest Path', false);
SELECT * FROM Trips;
*/

-- (3.3.17) Function createLicence(): Return the unique licence string for a
-- given vehicle-Id 'No' for 'No' in [0,26999]

CREATE OR REPLACE FUNCTION createLicence(No int)
	RETURNS text AS $$
BEGIN
	IF No > 0 and No < 1000 THEN
		RETURN text 'B-' || chr(random_int(1, 26) + 65) || chr(random_int(1, 25) + 65)
			|| ' ' || No::text;
	ELSEIF No % 1000 = 0 THEN
		RETURN text 'B-' || chr((No % 1000) + 65) || ' '
			|| (random_int(1, 998) + 1)::text;
	ELSE
		RETURN text 'B-' || chr((No % 1000) + 64) || 'Z '
			|| (No % 1000)::text;
	  END IF;
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
SELECT createLicence(random_int(1,100))
FROM generate_series(1, 10);
*/

DROP FUNCTION IF EXISTS createVehicles;
CREATE FUNCTION createVehicles(numVehicles integer, numDays integer,
	startDay Date, mode text, disturb boolean)
RETURNS text AS $$
DECLARE
	-- CONSTANT PARAMETERS
	VEHICLETYPES text[] = '{"passenger", "bus", "truck"}';
	NOVEHICLETYPES int = array_length(VEHICLETYPES, 1);
	VEHICLEMODELS text[] = '{"Mercedes-Benz", "Volkswagen", "Maybach", "Porsche",
		"Opel", "BMW", "Audi", "Acabion", "Borgward", "Wartburg", "Sachsenring",
		"Multicar"}';
	NOVEHICLEMODELS int = array_length(VEHICLEMODELS, 1);
	-- Variables
	day date;
	i integer; j integer;

	weekday text;
	licence text; type text; model text;
	t1 timestamptz;
	trip tgeompoint;
	home bigint; work bigint;
	path step[];
BEGIN
	DROP TABLE IF EXISTS Licences;
	CREATE TABLE Licences(vehicleId integer, licence text, type text, model text);
	DROP TABLE IF EXISTS Trips;
	CREATE TABLE Trips(vehicleId integer, trip tgeompoint);
	FOR i IN 1..numVehicles LOOP
		RAISE NOTICE '*** Vehicle % ***', i;
		licence = createLicence(i);
		type = VEHICLETYPES[random_int(1, NOVEHICLETYPES)];
		model = VEHICLEMODELS[random_int(1, NOVEHICLEMODELS)];
		INSERT INTO Vehicles VALUES (i, licence, type, model);
		day = startDay;
		FOR j IN 1..numDays LOOP
			day = day + (j - 1) * interval '1 day';
			PERFORM createDay(i, day, mode, disturb);
		END LOOP;
	END LOOP;
	RETURN 'The End';
END;
$$ LANGUAGE 'plpgsql' STRICT;

/*
SELECT createVehicles(2, 2, '2020-05-10', 'Fastest Path', false);
*/

----------------------------------------------------------------------
------ Section (2): Main Function --------------------------------
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION berlinmodGenerate()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE

	----------------------------------------------------------------------
	------ Section (1): Setting Parameters -------------------------------
	----------------------------------------------------------------------

	-- Seed for the random generator
	-- Used to ensure deterministic results
	SEED float = 0.5;

	----------------------------------------------------------------------
	-- (1.1) Global Scaling Parameter
	----------------------------------------------------------------------

	-- Scale factor
	-- Use SCALEFACTOR = 1.0 for a full-scaled benchmark
	SCALEFACTOR float = 0.005;

	----------------------------------------------------------------------
	--  (1.2) Trip Creation Settings
	----------------------------------------------------------------------

	-- Choose selection method for HOME and DESTINATION nodes between
	--	* 'Network Based' (default)
	--	* 'Region Based'
	P_TRIP_MODE text = 'Network Based';

	-- Choose path selection options between
	--	* 'Fastest Path' (default)
	--	* 'Shortest Path'
	P_TRIP_DISTANCE text = 'Fastest Path';

	-- Choose unprecise data generation between:
	--	* FALSE (no unprecision) (default)
	--	* TRUE  (disturbed data)
	P_DISTURB_DATA boolean = FALSE;

	-- THIS VARIABLE IS REPEATED AND THIS SHOULD BE AVOIDED
	P_GPS_TOTALMAXERR float = 100.0;

	-------------------------------------------------------------------------
	--	(1.3) Secondary Parameters
	-------------------------------------------------------------------------
	-- As default, the scalefactor is distributed between the number of cars
	-- and the number of days, they are observed:
	--   	SCALEFCARS = sqrt(SCALEFACTOR);
	--   	SCALEFDAYS = sqrt(SCALEFACTOR);
	-- Alternatively, you can manually set the scaling factors to arbitrary real values.
	-- Then, they will scale the number of observed vehicles and the observation time
	-- linearly:
	-- 	* For SCALEFCARS = 1.0 you will get 2000 vehicles
	--	* For SCALEFDAYS = 1.0 you will get 28 days of observation
	SCALEFCARS float = sqrt(SCALEFACTOR);
	SCALEFDAYS float = sqrt(SCALEFACTOR);

	-- The day, the observation starts
	-- Default: P_STARTDAY = monday 03/01/2000
	P_STARTDAY date  = '2000-01-03';

	-- The amount of vehicles to observe
	-- For SCALEFACTOR = 1.0, we have 2,000 vehicles:
	P_NUMCARS int = round((2000 * SCALEFCARS)::numeric, 0)::int;

	-- The amount of observation days
	-- For SCALEFACTOR = 1.0, we have 28 observation days:
	P_NUMDAYS int = round((SCALEFDAYS * 28)::numeric, 0)::int;

	-- The minimum length of a pause in milliseconds,
	-- (used to distinguish subsequent trips)
	-- Default: P_MINPAUSE_MS = 300000 ms (=5 min)
	P_MINPAUSE_MS int = 300000;

	-- The velocity below which a vehicle is considered to be static
	-- Default: P_MINVELOCITY = 0.04166666666666666667 (=1.0 m/24.0 h = 1 m/day)
	P_MINVELOCITY float = 0.04166666666666666667;

	-- The duration between two subsequent GPS-observations
	-- Default: 2000 ms (=2 sec)
	P_GPSINTERVAL_MS int = 2000;

	-- The radius defining a node's neigbourhood
	-- Default: 3000.0 m (=3 km)
	P_NEIGHBOURHOOD_RADIUS float = 3000.0;

	-- The random seeds used ---
	-- Defaults: P_HOMERANDSEED = 0, P_TRIPRANDSEED = 4277
	P_HOMERANDSEED int = 0;
	P_TRIPRANDSEED int = 4277;

	-- The size for sample relations
	-- Default: P_SAMPLESIZE = 100;
	P_SAMPLESIZE int = 100;

	-------------------------------------------------------------------------
	---	(1.4) Fine Tuning the Trip Creation
	-------------------------------------------------------------------------

	-------------------------------------------------------------------------
	-- Setting the parameters for stops at destination nodes:
	-------------------------------------------------------------------------

	-- Set mean of exponential distribution for waiting times [ms].
	P_DEST_ExpMu float = 15000.0;

	-- Set probabilities for forced stops at transitions between street types.
	-- 'XY' means transition X -> Y, where S= small street, M= main street F= freeway.
	-- Observe 0.0 <= p <= 1.0 for all probabilities p.
	P_DEST_SS float = 0.33;
	P_DEST_SM float = 0.66;
	P_DEST_SF float = 1.0;
	P_DEST_MS float = 0.33;
	P_DEST_MM float = 0.5;
	P_DEST_MF float = 0.66;
	P_DEST_FS float = 0.05;
	P_DEST_FM float = 0.33;
	P_DEST_FF float = 0.1;

	-- Set maximum allowed velocities for sidestreets (VmaxS), mainstreets (VmaxM)
	-- and freeways (VmaxF) [km/h].
	-- ATTENTION: Choose P_DEST_VmaxF such that is is not less than the
	--            total maximum Vmax within the streets relation!
	P_DEST_VmaxS float = 30.0;
	P_DEST_VmaxM float = 50.0;
	P_DEST_VmaxF float = 70.0;

	-------------------------------------------------------------------------
	-- Setting the parameters for enroute-events
	-------------------------------------------------------------------------

	-- Set the parameters for enroute-events: Routes will be divided into subsegments
	-- of maximum length 'P_EVENT_Length'. The probability of an event is proportional
	-- to (P_EVENT_C)/Vmax.
	-- The probability for an event being a forced stop is given by
	-- 0.0 <= 'P_EVENT_P' <= 1.0 (the balance, 1-P, is meant to trigger
	-- deceleration events). Acceleration rate is set to 'P_EVENT_Acc'.
	P_EVENT_Length float = 5.0;
	P_EVENT_C float      = 1.0;
	P_EVENT_P float      = 0.1;
	P_EVENT_Acc float    = 12.0;

	----------------------------------------------------------------------
	--	Section (3): Variables
	----------------------------------------------------------------------

	SRID int;
	SPATIAL_UNIVERSE stbox;
	NBRNODES int;
	P_MINPAUSE interval = P_MINPAUSE_MS * interval '1 ms';
	P_GPSINTERVAL interval = P_GPSINTERVAL_MS * interval '1 ms';
	query_pgr text;

	----------------------------------------------------------------------
	------ Section (2): Data Generator -----------------------------------
	----------------------------------------------------------------------

BEGIN

	-------------------------------------------------------------------------
	--	(2.1) Initialize variables
	-------------------------------------------------------------------------

	-- Set the seed so that the random function will return a repeatable
	-- sequence of random numbers that is derived from the seed.
	PERFROM setseed(SEED);

	-- Get the SRID of the data
	SELECT ST_SRID(the_geom) INTO SRID FROM ways LIMIT 1;

	-- Get the MBR for the spatial plane used
	--  SPATIAL_UNIVERSE : stbox;
	SELECT expandSpatial(ST_Extent(the_geom)::stbox, P_GPS_TOTALMAXERR + 10.0) INTO SPATIAL_UNIVERSE
	FROM ways;
	SELECT setSRID(SPATIAL_UNIVERSE, SRID) INTO SPATIAL_UNIVERSE;

	-- Get the number of nodes
	SELECT COUNT(*) INTO NBRNODES FROM Nodes;

	-------------------------------------------------------------------------
	--	(2.2) Creating the base data
	-------------------------------------------------------------------------

	-- A relation with all vehicles, their HomeNode, WorkNode and number of
	-- neighbourhood nodes.

	DROP TABLE IF EXISTS Vehicle;
	CREATE TABLE Vehicle(Id integer, homeNode bigint, workNode bigint, noNeighbours int);

	INSERT INTO Vehicle(Id, homeNode, workNode)
	SELECT Id,
		CASE WHEN P_TRIP_MODE = 'Network Based' THEN random_int(1, NBRNODES) ELSE selectHomeNodeRegionBased() END,
		CASE WHEN P_TRIP_MODE = 'Network Based' THEN random_int(1, NBRNODES) ELSE selectWorkNodeRegionBased() END
	FROM generate_series(1, P_NUMCARS) Id;

	-- Creating the Neighbourhoods for all HomeNodes
	-- Encoding for index: Key is (VehicleId * 1e6) + NeighbourId

	DROP TABLE IF EXISTS Neighbourhood;
	CREATE TABLE Neighbourhood AS
	SELECT ROW_NUMBER() OVER () AS Id, V.Id AS Vehicle, N2.id AS Node
	FROM Vehicle V, Nodes N1, Nodes N2
	WHERE V.homeNode = N1.Id AND ST_DWithin(N1.Geom, N2.geom, P_NEIGHBOURHOOD_RADIUS);

	-- Build indexes to speed up processing
	CREATE UNIQUE INDEX Neighbourhood_Id_Idx ON Neighbourhood USING BTREE(Id);
	CREATE INDEX Neighbourhood_Vehicle_Idx ON Neighbourhood USING BTREE(Vehicle);

	UPDATE Vehicle V
	SET NoNeighbours = (SELECT COUNT(*) FROM Neighbourhood N WHERE N.Vehicle = V.Id);

	-------------------------------------------------------------------------
	-- (2.3) Create auxiliary benchmarking data
	-------------------------------------------------------------------------

	-- P_SAMPLESIZE random node positions

	DROP TABLE IF EXISTS QueryPoints;
	CREATE TABLE QueryPoints AS
	WITH NodeIds AS (
		SELECT Id, random_int(1, NBRNODES)
		FROM generate_series(1, P_SAMPLESIZE) Id
	)
	SELECT I.Id, N.geom
	FROM Nodes N, NodeIds I
	WHERE N.id = I.id;

	-- P_SAMPLESIZE random regions

	DROP TABLE IF EXISTS QueryRegions;
	CREATE TABLE QueryRegions AS
	WITH NodeIds AS (
		SELECT Id, random_int(1, NBRNODES)
		FROM generate_series(1, P_SAMPLESIZE) Id
	)
	SELECT I.Id, ST_Buffer(N.geom, random_int(1, 997) + 3.0, random_int(0, 25)) AS geom
	FROM Nodes N, NodeIds I
	WHERE N.id = I.id;

	-- P_SAMPLESIZE random instants

	DROP TABLE IF EXISTS QueryInstants;
	CREATE TABLE QueryInstants AS
	SELECT Id, P_STARTDAY + (random() * P_NUMDAYS) * interval '1 day'
	FROM generate_series(1, P_SAMPLESIZE) Id;

	-- P_SAMPLESIZE random periods

	DROP TABLE IF EXISTS QueryPeriods;
	CREATE TABLE QueryPeriods AS
	WITH Instants AS (
		SELECT Id, P_STARTDAY + (random() * P_NUMDAYS) * interval '1 day' AS Instant
		FROM generate_series(1, P_SAMPLESIZE) Id
	)
	SELECT Id, Period(Instant, Instant + abs(random_gauss()) * interval '1 day', true, true)
	FROM Instants;

	-- (3.3.5) A relation containing the paths for the labour trips
	-- labourPath: rel{Vehicle: int, ToWork: path, ToHome: path}
	-- (3.3.6) Build index to speed up processing

	IF P_TRIP_DISTANCE = 'Fastest Path' THEN
		query_pgr = 'SELECT gid AS id, source, target, cost_s AS cost FROM ways';
	ELSE
		query_pgr = 'SELECT gid AS id, source, target, length_m AS cost FROM ways';
	END IF;

	DROP TABLE IF EXISTS HomeWork;
	CREATE TABLE HomeWork AS
	SELECT V.id, P.seq, P.node, P.edge
	FROM Vehicle V, pgr_dijkstra(
		query_pgr, V.homeNode, V.workNode, directed := true) P;

	CREATE INDEX HomeWork_edge_idx ON HomeWork USING BTREE(edge);

	DROP TABLE IF EXISTS WorkHome;
	CREATE TABLE WorkHome AS
	SELECT V.Id, P.seq, P.node, P.edge
	FROM Vehicle V, pgr_dijkstra(
		query_pgr, V.workNode, V.homeNode, directed := true) P;

	CREATE INDEX WorkHome_edge_idx ON WorkHome USING BTREE(edge);

	-------------------------------------------------------------------------
	-- Perform the generation
	-------------------------------------------------------------------------

	RAISE NOTICE 'Starting BerlinMOD generation with Scale Factor %', SCALEFACTOR;
	RAISE NOTICE 'P_NUMCARS = %, P_NUMDAYS = %, P_STARTDAY = %, P_TRIP_DISTANCE = %,
		P_DISTURB_DATA = %', P_NUMCARS, P_NUMDAYS, P_STARTDAY, P_TRIP_DISTANCE,
		P_DISTURB_DATA;
	PERFORM createVehicles(P_NUMCARS, P_NUMDAYS, P_STARTDAY, P_TRIP_DISTANCE,
		P_DISTURB_DATA);

	-------------------------------------------------------------------------------------------------

	return 'THE END';
END; $$;

/*
select berlinmodGenerate();
*/

-------------------------------------------------------------------------
-- (3.3.8) Function Path2Mpoint:
-- Creates a trip as a mpoint following path P and starting at instant Tstart.
--

let Path2Mpoint = fun(P: path, Tstart: instant)
  (
    samplempoint(
      (
        P feed namedtransformstream[Path]
        filter[seqinit(1)]
        extend[Dummy: 1]
        projectextendstream[ Dummy ; Edge : edges(.Path) transformstream ]
        projectextend[ ; Source : get_source(.Edge) ,
                         Target : get_target(.Edge), SeqNo: seqnext()]
        loopjoin[SectionsUndir_Key SectionsUndir
                 exactmatch[(.Source * 10000) + .Target] ]
        projectextend[ SeqNo ; Line: .Part, Vmax: .Vmax ]
        sortby[SeqNo asc]
          sim_createTrip[
              Line,
              Vmax,
              Tstart,
              get_pos(vertices(P) extract[Vertex]),
              100.0 ]
      ),
    P_GPSINTERVAL,
    TRUE,
    TRUE
  )
  );

-------------------------------------------------------------------------
-- (3.3.13) Function CreateAdditionalTrip
-- Creates an 'additional trip' for a vehicle, starting at a given time
--

let CreateAdditionalTrip = fun(Veh: int, Home: int,
                               NoNeigh: int, Ttotal: duration, Tbegin: instant)
  ifthenelse(P_TRIP_DISTANCE = 'Fastest Path',
  (
-- Select fastest path
    ( ifthenelse( rng_intN(100) < 80,
                  1,
                  ifthenelse( rng_intN(100) < 50, 2, 3) )
      feed namedtransformstream[NoDests]
      extend[ S0: Home,
              S1: ifthenelse( .NoDests >=1 , SelectDestNode(Veh, NoNeigh), Home ),
              S2: ifthenelse( .NoDests >=2 , SelectDestNode(Veh, NoNeigh), Home ),
              S3: ifthenelse( .NoDests >=3 , SelectDestNode(Veh, NoNeigh), Home ) ]
      extend[ D0: .S1, D1: .S2, D2: .S3, D3: Home ]
      projectextend[ NoDests
              ;Trip0: ifthenelse( .S0 - .D0,
                        Path2Mpoint(shortestpath(berlinmodtime, .S0, .D0), Tbegin),
                        [const mpoint value ()] ),
              TriP1: ifthenelse( .S1 - .D1,
                        Path2Mpoint(shortestpath(berlinmodtime, .S1, .D1), Tbegin),
                        [const mpoint value ()]),
              TriP2: ifthenelse( .S2 - .D2,
                        Path2Mpoint(shortestpath(berlinmodtime, .S2, .D2), Tbegin),
                        [const mpoint value ()]),
              Trip3: ifthenelse( .S3 - .D3,
                        Path2Mpoint(shortestpath(berlinmodtime, .S3, .D3), Tbegin),
                        [const mpoint value () ]) ]
      extend[ Pause0: CreatePause(),
              Pause1: CreatePause(),
              Pause2: CreatePause()]
      extend[Result: ifthenelse( .NoDests < 2,
                        .Trip0 translateappend[.TriP1, .Pause0],
                        ifthenelse( .NoDests < 3,
                                    (.Trip0 translateappend[.TriP1, .Pause0])
                                            translateappend[.TriP2, .Pause1] ,
                                     ((.Trip0 translateappend[.TriP1, .Pause0])
                                       translateappend[.TriP2, .Pause1])
                                       translateappend[.Trip3, .Pause2] ) ) ]
      extract[Result]
    )
  ),
  (
-- Select shortest path
    ( ifthenelse( rng_intN(100) < 80,
                  1,
                  ifthenelse( rng_intN(100) < 50, 2, 3) )
      feed namedtransformstream[NoDests]
      extend[ S0: Home,
              S1: ifthenelse( .NoDests >=1 , SelectDestNode(Veh, NoNeigh), Home ),
              S2: ifthenelse( .NoDests >=2 , SelectDestNode(Veh, NoNeigh), Home ),
              S3: ifthenelse( .NoDests >=3 , SelectDestNode(Veh, NoNeigh), Home ) ]
      extend[ D0: .S1, D1: .S2, D2: .S3, D3: Home ]
      projectextend[ NoDests
              ;Trip0: ifthenelse( .S0 - .D0,
                       Path2Mpoint(shortestpath(berlinmodtime, .S0, .D0), Tbegin),
                       [const mpoint value ()] ),
              TriP1: ifthenelse( .S1 - .D1,
                       Path2Mpoint(shortestpath(berlinmodtime, .S1, .D1), Tbegin),
                       [const mpoint value ()]),
              TriP2: ifthenelse( .S2 - .D2,
                       Path2Mpoint(shortestpath(berlinmodtime, .S2, .D2), Tbegin),
                       [const mpoint value ()]),
              Trip3: ifthenelse( .S3 - .D3,
                       Path2Mpoint(shortestpath(berlinmodtime, .S3, .D3), Tbegin),
                       [const mpoint value () ]) ]
      extend[ Pause0: CreatePause(),
              Pause1: CreatePause(),
              Pause2: CreatePause()]
      extend[Result: ifthenelse( .NoDests < 2,
                      .Trip0 translateappend[.TriP1, .Pause0],
                      ifthenelse( .NoDests < 3,
                                  (.Trip0 translateappend[.TriP1, .Pause0])
                                          translateappend[.TriP2, .Pause1] ,
                                   ((.Trip0 translateappend[.TriP1, .Pause0])
                                     translateappend[.TriP2, .Pause1])
                                     translateappend[.Trip3, .Pause2] ) ) ]
      extract[Result]
    )
  )
  );



-------------------------------------------------------------------------
-- (3.3.14) Function CreateDay
-- Creates a certain vehicle's movement for a specified day
--

-- Version with overlapping-avoidance:
let CreateDay = fun(VehicleId: int, DayNo: int,
                    PathWork: path, PathHome: path,
                    HomeIdent: int, NoNeighb: int)
  ifthenelse( ( (weekday_of(create_instant(DayNo, 0)) = 'Sunday') or
                (weekday_of(create_instant(DayNo, 0)) = 'Saturday')
              ),
              ( ifthenelse(rng_intN(100) < 40,
                           CreateAdditionalTrip(VehicleId, HomeIdent, NoNeighb,
                                   [const duration value (0 18000000)],
                                   create_instant(DayNo, 32400000)
                                   + CreatePauseN(120)
                                  ) ,
                           [const mpoint value () ]
                          )
                ifthenelse(rng_intN(100) < 40,
                           CreateAdditionalTrip(VehicleId, HomeIdent, NoNeighb,
                                   [const duration value (0 18000000)],
                                   create_instant(DayNo, 68400000)
                                   + CreatePauseN(120)
                                  ) ,
                           [const mpoint value () ]
                          )
                concat
              ),
              (
                (
                  Path2Mpoint(PathWork, create_instant(DayNo, 28800000)
                              + CreateDurationRhoursNormal(2.0))
                  Path2Mpoint(PathHome, create_instant(DayNo, 57600000)
                              + CreateDurationRhoursNormal(2.0))
                concat
                )
                ifthenelse(rng_intN(100) < 40,
                           CreateAdditionalTrip(VehicleId, HomeIdent, NoNeighb,
                              [const duration value (0 14400000)],
                              create_instant(DayNo, 72000000) + CreatePauseN(90)
                                           ) ,
                           [const mpoint value () ]
                          )
                concat
              )
            )
  within[ifthenelse(hour_of(inst(final(.))) between [6,8],
                    [const mpoint value ()], . )];

-------------------------------------------------------------------------
-- (3.3.15) Function to create further Vehicle Attributes:
-- Function RandModel(): Return a random vehicle model string:
--
	ModelArray ARRAY[text] = {'Mercedes-Benz', 'Volkswagen', 'Maybach',
                           'Porsche', 'Opel', 'BMW', 'Audi', 'Acabion',
                           'Borgward', 'Wartburg', 'Sachsenring', 'Multicar'};
	NOMODELS int = array_length(ModelArray, 1);

-- (3.3.16) Function RandType(): Return a random vehicle type
--          (0 = passenger, 1 = bus, 2 = truck):
--
	ModelArray ARRAY[text] = {'passenger', 'bus', 'truck'};



-------------------------------------------------------------------------
-- (3.3.18) Function to generate vehicle data
-
-- Function CreateVehicles():
--   Create data for 'NumVehicle' vehicles and 'NumDays' days
--   starting at 'StartDay'
--
--   The result has type rel{Id:    int,    Licence: string, Type: string,
--                           Model: string, Trip:    mpoint}

let CreateVehicles = fun(NumVehicleP: int, NumDaysP: int, StartDayP: int)
      vehicle feed
      head[NumVehicleP] {v}
      labourPath feed {p}
      symmjoin[.Id_v = ..Id_p]
      intstream(StartDayP, (StartDayP + NumDaysP) - 1) transformstream
      product
      projectextend[; Id: .Id_v,
                      Day: .Elem,
                      TripOfDay: CreateDay(.Id_v, .Elem, .ToWork_p,
                                           .ToHome_p, .HomeNode_v,
                                           .NoNeighbours_v)]
      filter[ TRUE echo['V: ' + num2string(.Id) + '/D: ' + num2string(.Day)] ]
      sortby[Id, Day]
      groupby[Id; Trip:
              (group feed
                projecttransformstream[TripOfDay] concatS
              )
              sim_fillup_mpoint[ create_instant(StartDayP - 1,0),
                                 create_instant((StartDayP + NumDaysP) + 1,0),
                                 TRUE, FALSE, FALSE]
             ]
      filter[ TRUE echo['Vehicle ' + num2string(.Id) + ' concatenated.'] ]
      projectextend[Id, Trip ; Licence: LicenceFun(.Id),
                    Type: RandType(), Model: RandModel() ]
      consume;

-- (3.3.19) Function CreateVehiclesDisturbed():
--   Create disturbed data for 'NumVehicle' vehicles and 'NumDays' days
--   starting at 'StartDay'
--
--   The result has type rel{Id:    int,    Licence: string, Type: string,
--                           Model: string, Trip:    mpoint}

let CreateVehiclesDisturbed= fun(NumVehicleP: int, NumDaysP: int, StartDayP: int)
      vehicle feed
      head[NumVehicleP] {v}
      labourPath feed {p}
      symmjoin[.Id_v = ..Id_p]
      intstream(StartDayP, (StartDayP + NumDaysP) - 1) transformstream
      product
      projectextend[; Id: .Id_v,
                      Day: .Elem,
                      TripOfDay: CreateDay(.Id_v, .Elem, .ToWork_p,
                                           .ToHome_p, .HomeNode_v,
                                           .NoNeighbours_v)]
      filter[ TRUE echo['V: ' + num2string(.Id) + '/D: ' + num2string(.Day)] ]
      sortby[Id, Day]
      groupby[Id; Trip:
              (group feed
                projecttransformstream[TripOfDay] concatS
              )
              sim_fillup_mpoint[ create_instant(StartDayP - 1,0),
                                 create_instant((StartDayP + NumDaysP) + 1,0),
                                 TRUE, FALSE, FALSE]
              disturb[P_GPS_TOTALMAXERR, P_GPS_STEPMAXERR]
             ]
      filter[ TRUE echo['Vehicle ' + num2string(.Id) + ' concatenated.'] ]
      projectextend[Id, Trip ; Licence: LicenceFun(.Id),
                    Type: RandType(), Model: RandModel() ]
      consume;

-------------------------------------------------------------------------
---- (3.4) Create moving object data for benchmark ----------------------
-------------------------------------------------------------------------

-- dataScar:  rel{Moid:  int,    Licence: string, Type: string,
--                Model: string, Trip:    mpoint}
-- dataMcar:  rel{Moid: int, Licence: string, Type: string, Model: string}
-- dataMtrip: rel{Moid: int, Licence: string, Trip: mpoint, Tripid: int}

-- See beginning of 'CreateTestData2' for parameter settings:
query sim_set_rng( 14, P_TRIPRANDSEED );

-- (3.4.1) Create the Moving Object Data
let dataScar1 =
  ifthenelse2(
    P_DISTURB_DATA,
    CreateVehiclesDisturbed(P_NUMCARS, P_NUMDAYS, P_STARTDAY),
    CreateVehicles(P_NUMCARS, P_NUMDAYS, P_STARTDAY)
  ) feed consume;

-- (3.4.2) Create OBA data (object based approach)
--         join vehicle and movement data
let dataScar =
  dataScar1 feed
  remove[Id]
  addcounter[Moid, 1]
  consume;

-- (3.4.3) Create TBA data (trip based approach) - vehicle data
let dataMcar =
  dataScar feed
  project[Moid, Licence, Type, Model]
  consume;

-- (3.4.4) Create TBA data (trip based approach) - decomposed movement data
let dataMtrip =
  dataScar feed
  projectextendstream[
    Moid, Licence ; Trip: .Trip sim_trips[P_MINPAUSE, P_MINVELOCITY]]
  addcounter[Tripid, 1]
  consume;


-- (3.5.5) P_SAMPLESIZE random Licences
let LicenceList =
  dataScar feed
  project[Licence]
  addcounter[Id,1]
  consume;
let LicenceList_Id = LicenceList createbtree[Id];
let QueryLicences =
  intstream(1, P_SAMPLESIZE) namedtransformstream[Id1]
  loopjoin[ LicenceList_Id LicenceList exactmatch[rng_intN(P_NUMCARS) + 1] ]
  projectextend[Licence; Id: .Id1]
  consume;

----------------------------------------------------------------------
-- Finished.
----------------------------------------------------------------------

